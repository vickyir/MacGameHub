import AppKit
import Foundation
import HubCore

/// Game Mode: free memory for a game by quitting other apps, and keep Wine leftovers from piling up.
///
/// Apps are quit with `terminate()`, the same as Cmd-Q: an app with unsaved work asks first, and nothing
/// is force-killed. Which apps to quit is the user's choice, remembered for next time.
extension AppModel {
    enum GameModeBehavior: String, CaseIterable, Identifiable {
        /// Offer the list before starting a game from MacGameHub.
        case ask
        /// Quit the remembered apps without asking, also when a game is started from inside Steam.
        case automatic
        case off

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: return "Tanyakan dulu"
            case .automatic: return "Tutup otomatis"
            case .off: return "Nonaktif"
            }
        }
    }

    struct CleanupCandidate: Identifiable {
        let app: NSRunningApplication
        let memory: UInt64
        var selected: Bool

        var id: pid_t { app.processIdentifier }
        var name: String { app.localizedName ?? app.bundleIdentifier ?? "?" }
    }

    struct CleanupOffer: Identifiable {
        let id = UUID()
        var candidates: [CleanupCandidate]
        /// The library entry to start afterwards, or nil when opened by hand.
        let game: Game?
    }

    static let gameModeBehaviorKey = "gameModeBehavior"
    private static let closeListKey = "gameModeCloseApps"
    /// Never offered: closing these breaks the session or the tools used to manage it.
    private static let protectedApps: Set<String> = [
        "com.apple.finder", "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ActivityMonitor",
        "com.apple.systempreferences", "com.apple.dock", "com.apple.controlcenter",
    ]
    /// First-time preselection: apps holding at least this much memory.
    private static let preselectBytes: UInt64 = 250 * 1_048_576

    /// Regular apps that could be quit, biggest first. Selection is what the user picked last time,
    /// or the big ones the first time.
    func cleanupCandidates() async -> [CleanupCandidate] {
        let processes = await ProcessMonitor.snapshot()
        let remembered = UserDefaults.standard.stringArray(forKey: Self.closeListKey).map(Set.init)
        return NSWorkspace.shared.runningApplications.compactMap { app -> CleanupCandidate? in
            // Wine programs have no bundle identifier, so games and launchers are never offered.
            guard app.activationPolicy == .regular, app != .current, !app.isTerminated,
                  let id = app.bundleIdentifier, !Self.protectedApps.contains(id) else { return nil }
            let memory = ProcessMonitor.treeMemory(of: app.processIdentifier, in: processes)
            let selected = remembered.map { $0.contains(id) } ?? (memory >= Self.preselectBytes)
            return CleanupCandidate(app: app, memory: memory, selected: selected)
        }
        .sorted { $0.memory > $1.memory }
    }

    func offerCleanup() {
        Task { cleanupOffer = CleanupOffer(candidates: await cleanupCandidates(), game: nil) }
    }

    /// The sheet's answer: quit what's ticked (and remember the choice), then start the game if there is one.
    func finishCleanup(_ offer: CleanupOffer, closeSelected: Bool) {
        if closeSelected {
            let chosen = offer.candidates.filter(\.selected)
            UserDefaults.standard.set(chosen.compactMap(\.app.bundleIdentifier), forKey: Self.closeListKey)
            chosen.forEach { $0.app.terminate() }
        }
        if let game = offer.game { start(game) }
    }

    func closeRememberedApps() async {
        guard UserDefaults.standard.stringArray(forKey: Self.closeListKey) != nil else { return }
        for candidate in await cleanupCandidates() where candidate.selected {
            candidate.app.terminate()
        }
    }

    /// Runs every few seconds: notices a game starting (from MacGameHub or inside Steam) and removes
    /// processes the previous engine left behind.
    func pollProcesses() async {
        guard engine != nil else { return }
        let processes = await ProcessMonitor.snapshot()

        // GPTK's Wine 7.7 processes outlive their wineserver and just hold memory.
        let legacy = paths.engines.appendingPathComponent(EngineManager.gptkBundleName, isDirectory: true)
        for process in ProcessMonitor.processes(in: processes, runningFrom: legacy) {
            kill(process.pid, SIGKILL)
        }

        let executables = Set(library.games.compactMap { game -> String? in
            guard case let .executable(path) = game.launch else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent.lowercased()
        })
        let game = ProcessMonitor.runningGames(in: processes, libraryExecutables: executables).first
        guard game?.executable != runningGame?.executable else { return }
        runningGame = game
        if game != nil, gameModeBehavior == .automatic {
            await closeRememberedApps()
        }
    }
}

import AppKit
import Foundation
import HubCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library = LibraryData()
    @Published private(set) var engine: WineEngine?
    @Published private(set) var rosettaInstalled = EngineManager.isRosettaInstalled
    @Published var engineProgress: (fraction: Double, message: String)?
    /// Bottles currently doing a long operation (creating, installing, scanning), with a status line.
    @Published private(set) var bottleActivity: [UUID: String] = [:]
    /// Games (or launcher installers) that are currently running, keyed by game id.
    @Published private(set) var running: [UUID: Date] = [:]
    @Published var alert: AlertItem?
    /// The Windows game currently running in any bottle, as seen in the process list.
    @Published var runningGame: RunningGame?
    /// Shown as a sheet: apps that could be closed to give a game more memory.
    @Published var cleanupOffer: CleanupOffer?
    @Published var gameModeBehavior: GameModeBehavior {
        didSet { UserDefaults.standard.set(gameModeBehavior.rawValue, forKey: Self.gameModeBehaviorKey) }
    }

    let paths = HubPaths.default
    private let store: LibraryStore
    private let engineManager: EngineManager
    private var processes: [UUID: Process] = [:]
    /// Games whose launch is waiting on bottle preparation, so a second click doesn't start them twice.
    private var starting: Set<UUID> = []
    private var controllerBridge: ControllerBridgeService?

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        gameModeBehavior = UserDefaults.standard.string(forKey: Self.gameModeBehaviorKey)
            .flatMap(GameModeBehavior.init(rawValue:)) ?? .ask
        store = LibraryStore(fileURL: paths.libraryFile)
        engineManager = EngineManager(paths: paths)
        try? paths.ensureDirectories()
        do {
            library = try store.load()
        } catch {
            alert = AlertItem(title: "Library tidak bisa dibaca", message: error.localizedDescription)
        }
        refreshEnvironment()
        controllerBridge = ControllerBridgeService(fileURL: paths.controllerState)
        controllerBridge?.start()
        Task { [weak self] in
            while let model = self {
                await model.pollProcesses()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var isReady: Bool { engine != nil && rosettaInstalled }

    /// The pre-Wine 11 engine (GPTK, Wine 7.7) is still installed, so this is an upgrade.
    var hasLegacyEngine: Bool { engineManager.legacyWineserver != nil }

    var runner: WineRunner? {
        engine.map { WineRunner(engine: $0, paths: paths) }
    }

    func refreshEnvironment() {
        engine = engineManager.installedEngine()
        rosettaInstalled = EngineManager.isRosettaInstalled
    }

    // MARK: Persistence

    private func save() {
        do { try store.save(library) } catch {
            show("Gagal menyimpan library", error)
        }
    }

    func show(_ title: String, _ error: Error) {
        alert = AlertItem(title: title, message: error.localizedDescription)
    }

    // MARK: Setup

    func installRosetta() async {
        do {
            try await EngineManager.installRosetta()
        } catch {
            show("Instalasi Rosetta gagal", error)
        }
        refreshEnvironment()
    }

    func installEngine() async {
        guard engineProgress == nil else { return }
        engineProgress = (0, "Menyiapkan…")
        // Bottles may still run processes on the previous engine (GPTK, Wine 7.7). Only its own
        // wineserver can stop them, and Wine 11 can't share a bottle with them.
        if let legacy = engineManager.legacyWineserver {
            for bottle in library.bottles {
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = paths.prefix(for: bottle.id).path
                _ = try? await Shell.run(legacy, ["-k"], environment: env)
            }
        }
        do {
            _ = try await engineManager.install { fraction, message in
                Task { @MainActor [weak self] in self?.engineProgress = (fraction, message) }
            }
        } catch {
            show("Instalasi engine gagal", error)
        }
        engineProgress = nil
        refreshEnvironment()
    }

    // MARK: Bottles

    func bottle(_ id: UUID) -> Bottle? {
        library.bottles.first { $0.id == id }
    }

    func games(in bottleID: UUID?) -> [Game] {
        let list = bottleID.map { library.games(in: $0) } ?? library.games
        return list.sorted { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
    }

    @discardableResult
    func createBottle(named name: String, settings: BottleSettings = BottleSettings()) async -> Bottle? {
        guard let runner else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bottle = Bottle(name: trimmed.isEmpty ? "Bottle \(library.bottles.count + 1)" : trimmed, settings: settings)
        library.bottles.append(bottle)
        save()
        bottleActivity[bottle.id] = "Membuat bottle Windows… (bisa 1–2 menit)"
        defer { bottleActivity[bottle.id] = nil }
        do {
            try await runner.createPrefix(for: bottle)
            return bottle
        } catch {
            show("Gagal membuat bottle", error)
            return bottle
        }
    }

    func updateSettings(_ settings: BottleSettings, for bottleID: UUID) async {
        guard let index = library.bottles.firstIndex(where: { $0.id == bottleID }) else { return }
        let old = library.bottles[index].settings
        library.bottles[index].settings = settings
        save()
        // Only registry-backed settings need Wine to run.
        guard old.windowsVersion != settings.windowsVersion || old.retinaMode != settings.retinaMode,
              let runner else { return }
        bottleActivity[bottleID] = "Menerapkan pengaturan…"
        defer { bottleActivity[bottleID] = nil }
        do {
            try await runner.applySettings(library.bottles[index])
        } catch {
            show("Gagal menerapkan pengaturan", error)
        }
    }

    func renameBottle(_ bottleID: UUID, to name: String) {
        guard let index = library.bottles.firstIndex(where: { $0.id == bottleID }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        library.bottles[index].name = name
        save()
    }

    func deleteBottle(_ bottleID: UUID) async {
        guard let bottle = bottle(bottleID) else { return }
        await runner?.killAll(bottle)
        library.games.removeAll { $0.bottleID == bottleID }
        library.bottles.removeAll { $0.id == bottleID }
        save()
        let prefix = paths.prefix(for: bottleID)
        // Move to Trash rather than deleting outright, so a mistake is recoverable.
        do {
            try FileManager.default.trashItem(at: prefix, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: prefix)
        }
    }

    func openDriveC(_ bottleID: UUID) {
        NSWorkspace.shared.open(paths.driveC(for: bottleID))
    }

    func killAll(_ bottleID: UUID) async {
        guard let bottle = bottle(bottleID) else { return }
        await runner?.killAll(bottle)
        for game in library.games(in: bottleID) {
            processes[game.id] = nil
            running[game.id] = nil
        }
    }

    func runTool(_ tool: String, in bottleID: UUID) {
        Task {
            guard let bottle = bottle(bottleID), let runner, await prepared(bottle, runner) else { return }
            do {
                try runner.launch(WineInvocation(arguments: [tool], workingDirectory: nil), in: bottle,
                                  logURL: paths.log(named: "bottle-\(bottleID.uuidString)")) { _ in }
            } catch {
                show("Gagal menjalankan \(tool)", error)
            }
        }
    }

    /// Runs ``WineRunner/prepare(_:)`` the first time a bottle is used with this engine, with a status line.
    private func prepared(_ bottle: Bottle, _ runner: WineRunner) async -> Bool {
        if runner.isPrepared(bottle) { return true }
        bottleActivity[bottle.id] = "Menyiapkan bottle untuk Wine \(EngineManager.wineVersion)… (sekali saja)"
        defer { bottleActivity[bottle.id] = nil }
        do {
            try await runner.prepare(bottle)
            return true
        } catch {
            show("Gagal menyiapkan bottle", error)
            return false
        }
    }

    // MARK: Installing software

    /// Runs a Windows installer (.exe / .msi) in the bottle, then scans for new games when it finishes.
    func runInstaller(_ file: URL, in bottleID: UUID, arguments: [String] = []) {
        Task { [self] in
            guard let bottle = bottle(bottleID), let runner, await prepared(bottle, runner) else { return }
            bottleActivity[bottleID] = "Menjalankan installer \(file.lastPathComponent)… selesaikan di jendela installer."
            do {
                try runner.launch(WineCommand.installer(file, arguments: arguments), in: bottle,
                                  logURL: paths.log(named: "bottle-\(bottleID.uuidString)")) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.bottleActivity[bottleID] = nil
                        _ = self.scanGames(in: bottleID)
                    }
                }
            } catch {
                bottleActivity[bottleID] = nil
                show("Installer gagal dijalankan", error)
            }
        }
    }

    func installStore(_ store: StoreInstaller, in bottleID: UUID) async {
        guard let target = bottle(bottleID), let runner, await prepared(target, runner) else { return }
        bottleActivity[bottleID] = "Mengunduh \(store.displayName)…"
        let file = paths.downloads.appendingPathComponent(store.fileName)
        do {
            try await Downloader.download(store.downloadURL, to: file) { _ in }
        } catch {
            bottleActivity[bottleID] = nil
            show("Gagal mengunduh \(store.displayName)", error)
            return
        }
        // The bottle may have been deleted while downloading.
        guard let bottle = bottle(bottleID) else {
            bottleActivity[bottleID] = nil
            return
        }
        bottleActivity[bottleID] = "Menginstal \(store.displayName)… ikuti jendela installer."
        do {
            try runner.launch(WineCommand.installer(file), in: bottle,
                              logURL: paths.log(named: "bottle-\(bottleID.uuidString)")) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.bottleActivity[bottleID] = nil
                    self.addStoreLauncherIfInstalled(store, in: bottleID)
                }
            }
        } catch {
            bottleActivity[bottleID] = nil
            show("Installer \(store.displayName) gagal", error)
        }
    }

    private func addStoreLauncherIfInstalled(_ store: StoreInstaller, in bottleID: UUID) {
        let exe = store.installedExecutable(driveC: paths.driveC(for: bottleID))
        guard FileManager.default.fileExists(atPath: exe.path) else { return }
        let launch = LaunchKind.executable(path: exe.path)
        guard !library.games.contains(where: { $0.bottleID == bottleID && $0.launch == launch }) else { return }
        library.games.append(Game(bottleID: bottleID, name: store.displayName, launch: launch,
                                  arguments: store.defaultLaunchArguments))
        save()
    }

    // MARK: Games

    /// Adds any newly found games. Returns how many were added.
    @discardableResult
    func scanGames(in bottleID: UUID) -> Int {
        let driveC = paths.driveC(for: bottleID)
        for store in StoreInstaller.allCases { addStoreLauncherIfInstalled(store, in: bottleID) }
        let existing = library.games(in: bottleID)
        let found = GameScanner.scan(driveC: driveC).filter { candidate in
            !existing.contains { $0.launch == candidate.launch || $0.name.lowercased() == candidate.name.lowercased() }
        }
        for item in found {
            library.games.append(Game(bottleID: bottleID, name: item.name, launch: item.launch))
        }
        if !found.isEmpty { save() }
        return found.count
    }

    func addExecutable(_ exe: URL, name: String, to bottleID: UUID) {
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? exe.deletingPathExtension().lastPathComponent : name
        library.games.append(Game(bottleID: bottleID, name: finalName, launch: .executable(path: exe.path)))
        save()
    }

    func updateGame(_ game: Game) {
        guard let index = library.games.firstIndex(where: { $0.id == game.id }) else { return }
        library.games[index] = game
        save()
    }

    func removeGame(_ gameID: UUID) {
        library.games.removeAll { $0.id == gameID }
        save()
    }

    /// Starts a library entry, after Game Mode has had its say (see `AppModel+GameMode.swift`).
    func launch(_ game: Game) {
        guard running[game.id] == nil, !starting.contains(game.id), cleanupOffer == nil else { return }
        switch gameModeBehavior {
        case .off:
            start(game)
        case .automatic:
            Task {
                await closeRememberedApps()
                start(game)
            }
        case .ask:
            Task {
                let candidates = await cleanupCandidates()
                if candidates.contains(where: \.selected) {
                    cleanupOffer = CleanupOffer(candidates: candidates, game: game)
                } else {
                    start(game)
                }
            }
        }
    }

    func start(_ game: Game) {
        guard running[game.id] == nil, !starting.contains(game.id) else { return }
        starting.insert(game.id)
        Task { [self] in
            defer { starting.remove(game.id) }
            guard let bottle = bottle(game.bottleID), let runner, await prepared(bottle, runner) else { return }
            let invocation = WineCommand.invocation(for: game, driveC: paths.driveC(for: bottle.id))
            if case let .executable(path) = game.launch, !FileManager.default.fileExists(atPath: path) {
                show("File game tidak ditemukan", HubError.notFound(path))
                return
            }
            do {
                let started = Date()
                let process = try runner.launch(invocation, in: bottle, logURL: logURL(for: game)) { [weak self] _ in
                    Task { @MainActor in self?.gameDidExit(game.id, startedAt: started) }
                }
                processes[game.id] = process
                running[game.id] = started
                if let index = library.games.firstIndex(where: { $0.id == game.id }) {
                    library.games[index].lastPlayed = started
                    save()
                }
            } catch {
                show("Game gagal dijalankan", error)
            }
        }
    }

    private func gameDidExit(_ gameID: UUID, startedAt: Date) {
        processes[gameID] = nil
        running[gameID] = nil
        if let index = library.games.firstIndex(where: { $0.id == gameID }) {
            library.games[index].totalPlaySeconds += Date().timeIntervalSince(startedAt)
            save()
        }
    }

    func stop(_ game: Game) {
        processes[game.id]?.terminate()
    }

    func logURL(for game: Game) -> URL {
        paths.log(named: "game-\(game.id.uuidString)")
    }

    func openLog(for game: Game) {
        let url = logURL(for: game)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(paths.logs)
        }
    }
}

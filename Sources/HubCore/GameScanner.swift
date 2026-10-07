import Foundation

public struct DiscoveredGame: Hashable, Sendable {
    public var name: String
    public var launch: LaunchKind

    public init(name: String, launch: LaunchKind) {
        self.name = name
        self.launch = launch
    }
}

/// Finds installed games inside a bottle's C: drive.
public enum GameScanner {
    /// Steam app IDs that are tools/redistributables, not games.
    static let steamIgnoredAppIDs: Set<String> = ["228980", "1070560", "1391110", "1628350", "1493710", "2180100"]

    /// Executable names that are almost never the game itself.
    static let ignoredExePatterns = [
        "unins", "uninst", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "dxwebsetup",
        "crash", "report", "helper", "updater", "update", "launcherpatcher", "dotnet", "directx",
        "ue4prereq", "ueprereq", "prereq", "easyanticheat", "eac_", "battleye", "be_service",
        "unitycrashhandler", "cefsharp", "quicksfv", "touchup", "7z", "notification_helper",
    ]

    /// Top-level folders under Program Files that are system/launcher software.
    static let ignoredFolders: Set<String> = [
        "common files", "internet explorer", "windows nt", "windows media player", "windows defender",
        "windows mail", "windows photo viewer", "windows sidebar", "windowspowershell", "microsoft.net",
        "microsoft", "msbuild", "reference assemblies", "steam", "epic games", "gog galaxy", "wine",
        "modifiablewindowsapps", "windowsapps",
    ]

    public static func scan(driveC: URL) -> [DiscoveredGame] {
        var games: [DiscoveredGame] = []
        games += steamGames(driveC: driveC)
        games += epicGames(driveC: driveC)
        games += executableGames(driveC: driveC)
        // De-duplicate by name, preferring launcher entries (listed first).
        var seen = Set<String>()
        return games.filter { seen.insert($0.name.lowercased()).inserted }
    }

    // MARK: Steam

    public static func steamGames(driveC: URL) -> [DiscoveredGame] {
        let steamDir = WinePaths.steamDirectory(driveC: driveC)
        var libraryDirs = [steamDir.appendingPathComponent("steamapps", isDirectory: true)]

        // Extra Steam library folders on C:.
        let libraryFile = steamDir.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: libraryFile, encoding: .utf8) {
            let root = VDFParser.parse(text)
            for (_, folder) in root["libraryfolders"]?.children ?? [] {
                if let path = folder["path"]?.string,
                   let unix = WinePaths.unixPath(fromWindows: path, driveC: driveC) {
                    let dir = unix.appendingPathComponent("steamapps", isDirectory: true)
                    if !libraryDirs.contains(where: { $0.standardizedFileURL == dir.standardizedFileURL }) {
                        libraryDirs.append(dir)
                    }
                }
            }
        }

        var result: [DiscoveredGame] = []
        for dir in libraryDirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for file in files.sorted() where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
                      let game = parseSteamManifest(text) else { continue }
                result.append(game)
            }
        }
        return result
    }

    public static func parseSteamManifest(_ text: String) -> DiscoveredGame? {
        let root = VDFParser.parse(text)
        guard let state = root["AppState"],
              let appID = state["appid"]?.string, !appID.isEmpty,
              !steamIgnoredAppIDs.contains(appID) else { return nil }
        let name = state["name"]?.string ?? state["installdir"]?.string ?? "Steam App \(appID)"
        if name.lowercased().contains("redistributable") || name.lowercased().hasPrefix("proton") { return nil }
        return DiscoveredGame(name: name, launch: .steam(appID: appID))
    }

    // MARK: Epic

    public static func epicGames(driveC: URL) -> [DiscoveredGame] {
        let dir = WinePaths.epicManifests(driveC: driveC)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.sorted().compactMap { file in
            guard file.lowercased().hasSuffix(".item"),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
            return parseEpicManifest(data)
        }
    }

    public static func parseEpicManifest(_ data: Data) -> DiscoveredGame? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appName = json["AppName"] as? String, !appName.isEmpty else { return nil }
        // Skip DLC / add-ons: they point at a main game.
        if let main = json["MainGameAppName"] as? String, !main.isEmpty, main != appName { return nil }
        if let categories = json["AppCategories"] as? [String], !categories.isEmpty,
           !categories.contains("games") { return nil }
        let name = (json["DisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? appName
        return DiscoveredGame(name: name, launch: .epic(appName: appName))
    }

    // MARK: Plain executables (GOG offline installers, standalone games)

    public static func executableGames(driveC: URL) -> [DiscoveredGame] {
        let roots = ["Program Files", "Program Files (x86)", "GOG Games", "Games"]
            .map { driveC.appendingPathComponent($0, isDirectory: true) }
        var result: [DiscoveredGame] = []
        let fm = FileManager.default
        for root in roots {
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !ignoredFolders.contains(folder.lastPathComponent.lowercased()) else { continue }
                if let exe = bestExecutable(in: folder) {
                    result.append(DiscoveredGame(name: folder.lastPathComponent, launch: .executable(path: exe.path)))
                }
            }
        }
        return result
    }

    public static func isIgnoredExecutable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ignoredExePatterns.contains { lower.contains($0) }
    }

    /// Picks the most likely game executable within `folder` (max depth 3).
    static func bestExecutable(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let folderTokens = tokens(folder.lastPathComponent)
        let baseDepth = folder.standardizedFileURL.pathComponents.count
        var best: (url: URL, score: Double)?

        for case let url as URL in enumerator {
            let depth = url.standardizedFileURL.pathComponents.count - baseDepth
            if depth > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  !isIgnoredExecutable(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = Double(values?.fileSize ?? 0)

            var score = log2(max(size, 1))                  // bigger binaries are usually the game
            let exeTokens = tokens(url.deletingPathExtension().lastPathComponent)
            score += Double(folderTokens.intersection(exeTokens).count) * 6
            score -= Double(depth) * 1.5                    // prefer shallow
            if url.path.lowercased().contains("win64") || url.path.lowercased().contains("x64") { score += 2 }
            if url.lastPathComponent.lowercased().contains("launcher") { score -= 3 }

            if best == nil || score > best!.score { best = (url, score) }
        }
        return best?.url
    }

    static func tokens(_ s: String) -> Set<String> {
        let parts = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(parts.map(String.init).filter { $0.count >= 2 })
    }
}

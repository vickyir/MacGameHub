import Foundation

/// All on-disk locations used by MacGameHub.
///
///     ~/Library/Application Support/MacGameHub/
///       library.json          bottles + games
///       Engines/Wine/         Wine 11 engine with D3DMetal deployed (see WineEngine)
///       Engines/D3DMetal/     Apple's D3DMetal, taken from the Game Porting Toolkit
///       Bottles/<uuid>/       one WINEPREFIX per bottle (contains drive_c)
///       Logs/                 one log file per game / action
///       Downloads/            temporary installers (Steam, Epic)
public struct HubPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: HubPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return HubPaths(root: base.appendingPathComponent("MacGameHub", isDirectory: true))
    }

    public var libraryFile: URL { root.appendingPathComponent("library.json") }
    public var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    /// Controller state shared with games (see ControllerBridge).
    public var controllerState: URL { root.appendingPathComponent("controller-state.bin") }

    public func prefix(for bottleID: UUID) -> URL {
        bottles.appendingPathComponent(bottleID.uuidString, isDirectory: true)
    }

    public func driveC(for bottleID: UUID) -> URL {
        prefix(for: bottleID).appendingPathComponent("drive_c", isDirectory: true)
    }

    public func log(named name: String) -> URL {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return logs.appendingPathComponent(String(safe) + ".log")
    }

    public func ensureDirectories() throws {
        for dir in [root, engines, bottles, logs, downloads] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Keep Spotlight out of bottles and engines: indexing tens of GB of game files mid-game costs
        // disk and CPU, and nothing in there is worth searching from Finder.
        for dir in [engines, bottles] {
            let marker = dir.appendingPathComponent(".metadata_never_index")
            if !FileManager.default.fileExists(atPath: marker.path) {
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            }
        }
    }
}

/// Paths inside a Wine prefix that the scanner and launcher care about.
public enum WinePaths {
    public static func steamDirectory(driveC: URL) -> URL {
        driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
    }

    public static func steamExecutable(driveC: URL) -> URL {
        steamDirectory(driveC: driveC).appendingPathComponent("steam.exe")
    }

    public static func epicManifests(driveC: URL) -> URL {
        driveC.appendingPathComponent("ProgramData/Epic/EpicGamesLauncher/Data/Manifests", isDirectory: true)
    }

    /// Converts a Windows path such as `C:\Games\Foo\foo.exe` into the unix path inside the prefix.
    public static func unixPath(fromWindows path: String, driveC: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.dropFirst().first == ":" else { return nil }
        let letter = trimmed.first!.lowercased()
        guard letter == "c" else { return nil }
        let rest = trimmed.dropFirst(2)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        return rest.isEmpty ? driveC : driveC.appendingPathComponent(rest)
    }
}

import Foundation

/// A process as `ps` reports it.
public struct RunningProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    /// Resident memory in bytes.
    public let residentBytes: UInt64
    public let command: String
}

/// A Windows game seen running in Wine.
public struct RunningGame: Equatable, Sendable {
    public let pid: Int32
    /// Windows path of the executable, e.g. `C:\Games\X\x.exe`.
    public let executable: String

    /// The executable's file name without `.exe`, e.g. "ACMirage".
    public var name: String {
        let file = executable.split(separator: "\\").last.map(String.init) ?? executable
        return (file as NSString).deletingPathExtension
    }
}

public enum ProcessMonitor {
    /// Every process on the Mac, with memory use. Empty if `ps` can't run.
    public static func snapshot() async -> [RunningProcess] {
        guard let result = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"),
                                                ["-axww", "-o", "pid=,ppid=,rss=,command="]) else { return [] }
        return parse(result.output)
    }

    static func parse(_ output: String) -> [RunningProcess] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3)
            guard fields.count == 4, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let rss = UInt64(fields[2]) else { return nil }
            return RunningProcess(pid: pid, parentPID: parent, residentBytes: rss * 1024, command: String(fields[3]))
        }
    }

    /// Resident memory of `pid` plus every process below it (Chrome's helpers, for instance).
    public static func treeMemory(of pid: Int32, in processes: [RunningProcess]) -> UInt64 {
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var total: UInt64 = 0
        var queue = [pid]
        var seen: Set<Int32> = []
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            total += byPID[next]?.residentBytes ?? 0
            queue += children[next, default: []].map(\.pid)
        }
        return total
    }

    /// The Windows executable a Wine process runs, taken from its command line (Wine shows it there).
    public static func windowsExecutable(in command: String) -> String? {
        guard let range = command.range(of: #"[A-Za-z]:\\.*?\.exe"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(command[range])
    }

    /// Games among `processes`: anything run from a Steam library or Epic games folder, or a library
    /// entry's executable, minus launcher clients and helpers (installers, crash reporters, …).
    public static func runningGames(in processes: [RunningProcess], libraryExecutables: Set<String>) -> [RunningGame] {
        let launchers = Set(LauncherCompatibility.clientExecutables.map { $0.lowercased() })
        var seen: Set<String> = []
        return processes.compactMap { process in
            guard let exe = windowsExecutable(in: process.command) else { return nil }
            let path = exe.lowercased()
            let file = path.split(separator: "\\").last.map(String.init) ?? path
            guard !launchers.contains(file), !GameScanner.isIgnoredExecutable(file) else { return nil }
            let isGame = (path.contains(#"\steamapps\common\"#) && !path.contains(#"\steamworks shared\"#))
                || (path.contains(#"\epic games\"#) && !path.contains(#"\epic games\launcher\"#))
                || libraryExecutables.contains(file)
            guard isGame, seen.insert(path).inserted else { return nil }
            return RunningGame(pid: process.pid, executable: exe)
        }
    }

    /// Processes still running from a folder, e.g. the old engine: once its wineserver is gone they
    /// hang around holding memory, and only a kill removes them.
    public static func processes(in processes: [RunningProcess], runningFrom folder: URL) -> [RunningProcess] {
        let prefix = folder.path + "/"
        return processes.filter { $0.command.hasPrefix(prefix) }
    }
}

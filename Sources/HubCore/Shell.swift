import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum HubError: LocalizedError {
    case engineMissing
    case rosettaMissing
    case commandFailed(String, Int32, String)
    case downloadFailed(String)
    case notFound(String)
    case unsupportedSystem

    public var errorDescription: String? {
        switch self {
        case .engineMissing:
            return "Engine Wine belum terpasang."
        case .rosettaMissing:
            return "Rosetta 2 belum terpasang."
        case let .commandFailed(cmd, status, output):
            let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
            return "Perintah gagal (\(status)): \(cmd)\n\(tail)"
        case let .downloadFailed(reason):
            return "Download gagal: \(reason)"
        case let .notFound(what):
            return "Tidak ditemukan: \(what)"
        case .unsupportedSystem:
            return "Engine Wine 11 membutuhkan macOS 15 Sequoia atau lebih baru."
        }
    }
}

public enum Shell {
    /// Runs a process to completion and returns its combined stdout/stderr.
    ///
    /// Output goes to a temporary file rather than a pipe: Wine spawns `wineserver` and other
    /// background processes that inherit stdout, so a pipe would never reach EOF and we'd hang.
    @discardableResult
    public static func run(_ executable: URL,
                           _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           logTo logURL: URL? = nil) async throws -> ProcessResult {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appendingPathComponent("macgamehub-\(UUID().uuidString).out")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = outHandle
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        try? outHandle.close()
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        try? fm.removeItem(at: outURL)

        if let logURL, let log = openLog(logURL) {
            let line = "$ " + ([executable.lastPathComponent] + arguments).joined(separator: " ") + "\n"
            log.write(Data(line.utf8))
            log.write(data)
            try? log.close()
        }
        return ProcessResult(status: status, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs and throws `HubError.commandFailed` on a non-zero exit status.
    @discardableResult
    public static func runChecked(_ executable: URL,
                                  _ arguments: [String],
                                  environment: [String: String]? = nil,
                                  currentDirectory: URL? = nil,
                                  logTo logURL: URL? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, environment: environment,
                                   currentDirectory: currentDirectory, logTo: logURL)
        guard result.status == 0 else {
            let cmd = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            throw HubError.commandFailed(cmd, result.status, result.output)
        }
        return result
    }

    /// Opens (creating if needed) a log file for appending.
    public static func openLog(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        let header = "\n===== \(ISO8601DateFormatter().string(from: Date())) =====\n"
        handle.write(Data(header.utf8))
        return handle
    }
}

/// Splits a shell-like argument string: `-dx11 "-name with space" 'x y'` → ["-dx11", "-name with space", "x y"].
/// Backslashes are kept literally so Windows paths (`C:\Games\x`) survive.
public enum ArgumentSplitter {
    public static func split(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inToken = false
        var quote: Character? = nil

        for ch in input {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                inToken = true
                continue
            }
            if ch.isWhitespace {
                if inToken {
                    result.append(current)
                    current = ""
                    inToken = false
                }
                continue
            }
            current.append(ch)
            inToken = true
        }
        if inToken { result.append(current) }
        return result
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An installed Wine engine: Wine 11 from the Whisky project's CrossOver-based tree
/// (https://github.com/frankea/winecx-gptk), built to run Apple's D3DMetal (DirectX 11/12 → Metal),
/// with D3DMetal deployed into it and DXVK alongside for launcher clients.
///
///     Engines/Wine/
///       Wine/bin/                 wine64, wineserver
///       Wine/lib/external/        D3DMetal.framework + libd3dshared.dylib
///       DXVK/x64, DXVK/x32        native d3d11 / d3d10core (see LauncherCompatibility)
///       originals/                Wine's own D3D DLLs that Apple's forwarders replaced
///       MacGameHubEngine.plist    written last, so it marks a complete install
public struct WineEngine: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var binDirectory: URL { root.appendingPathComponent("Wine/bin", isDirectory: true) }
    public var wine64: URL { binDirectory.appendingPathComponent("wine64") }
    public var wineserver: URL { binDirectory.appendingPathComponent("wineserver") }
    public var libDirectory: URL { root.appendingPathComponent("Wine/lib", isDirectory: true) }
    public var d3dMetal: URL {
        libDirectory.appendingPathComponent("external/D3DMetal.framework", isDirectory: true)
    }
    public var dxvkDirectory: URL { root.appendingPathComponent("DXVK", isDirectory: true) }
    public var originalsDirectory: URL { root.appendingPathComponent("originals", isDirectory: true) }
    var stampFile: URL { root.appendingPathComponent("MacGameHubEngine.plist") }

    /// The Wine version recorded at install time, e.g. "11.16".
    public var version: String {
        (NSDictionary(contentsOf: stampFile)?["wineVersion"] as? String) ?? "?"
    }

    /// The deployed D3DMetal version, e.g. "3.0", or nil when D3DMetal isn't there.
    public var d3dMetalVersion: String? {
        Bundle(url: d3dMetal)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public var isUsable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: wine64.path)
            && fm.isExecutableFile(atPath: wineserver.path)
            && fm.fileExists(atPath: stampFile.path)
    }
}

public final class EngineManager: @unchecked Sendable {
    /// Pinned Wine runtime: Whisky's Libraries v4.6.4-beta.1, wine-11.16 built from frankea/winecx-gptk with
    /// the exception-unwind support D3DMetal needs. Wine 11 is the point: on GPTK's own Wine 7.7, Steam's
    /// steamwebhelper crashes on start and Steam never opens a window.
    public static let runtimeVersion = "4.6.4-beta.1"
    public static let wineVersion = "11.16"
    public static let runtimeURL = URL(string:
        "https://github.com/frankea/Whisky/releases/download/v\(runtimeVersion)/Libraries.tar.gz")!
    public static let runtimeSHA256 = "c8e6a10dfeb54fc16d3dd3382ee2e9d2cec3eb1f5641613cad8b07903818cb12"

    /// Where D3DMetal comes from: Gcenx's build of Apple's Game Porting Toolkit (the one the Homebrew cask
    /// installs). Only its D3DMetal payload is kept.
    public static let gptkVersion = "3.0-3"
    public static let gptkURL = URL(string:
        "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-\(gptkVersion)/game-porting-toolkit-\(gptkVersion).tar.xz")!
    public static let gptkBundleName = "Game Porting Toolkit.app"

    public let paths: HubPaths

    public init(paths: HubPaths) {
        self.paths = paths
    }

    public var engineRoot: URL { paths.engines.appendingPathComponent("Wine", isDirectory: true) }

    /// Apple's D3DMetal payload, kept apart from the engine so reinstalling Wine doesn't need GPTK again.
    public var d3dMetalStore: URL { paths.engines.appendingPathComponent("D3DMetal/lib", isDirectory: true) }

    /// GPTK installs D3DMetal can be copied from: MacGameHub's previous engine, or the Homebrew cask
    /// (`brew install --cask gcenx/wine/game-porting-toolkit`).
    public var gptkBundles: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            paths.engines.appendingPathComponent(Self.gptkBundleName, isDirectory: true),
            URL(fileURLWithPath: "/Applications").appendingPathComponent(Self.gptkBundleName, isDirectory: true),
            home.appendingPathComponent("Applications").appendingPathComponent(Self.gptkBundleName, isDirectory: true),
        ]
    }

    public func installedEngine() -> WineEngine? {
        let engine = WineEngine(root: engineRoot)
        return engine.isUsable ? engine : nil
    }

    /// The wineserver of the engine MacGameHub used before (GPTK, Wine 7.7), if it's still there.
    /// Processes left running on it have to be stopped with it: Wine 11's server can't talk to them.
    public var legacyWineserver: URL? {
        let url = paths.engines.appendingPathComponent(Self.gptkBundleName, isDirectory: true)
            .appendingPathComponent("Contents/Resources/wine/bin/wineserver")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: Rosetta

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static var isRosettaInstalled: Bool {
        guard isAppleSilicon else { return true }
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Installs Rosetta 2. macOS shows its own administrator password prompt.
    public static func installRosetta() async throws {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        try await Shell.runChecked(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
    }

    // MARK: Install

    /// Installs the engine: D3DMetal from GPTK (copied when a GPTK is already on disk, ~230 MB download
    /// otherwise), then the Wine runtime (~460 MB), checksummed, with D3DMetal deployed into it.
    public func install(progress: @escaping @Sendable (Double, String) -> Void) async throws -> WineEngine {
        // The runtime's binaries are built for macOS 15 and later.
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            throw HubError.unsupportedSystem
        }
        try paths.ensureDirectories()
        let fm = FileManager.default

        let needsD3DMetal = !D3DMetalPayload.isComplete(at: d3dMetalStore)
        let localGPTK = needsD3DMetal ? gptkBundles.map(Self.gptkLib).first(where: D3DMetalPayload.isComplete(at:)) : nil
        // Progress share of the GPTK download, when there is one.
        let runtimeStart = needsD3DMetal && localGPTK == nil ? 0.3 : 0.0
        if let localGPTK {
            progress(0, "Menyalin D3DMetal dari Game Porting Toolkit…")
            try D3DMetalPayload.copy(from: localGPTK, to: d3dMetalStore)
        } else if needsD3DMetal {
            try await fetchD3DMetal { fraction, message in progress(fraction * runtimeStart, message) }
        }

        let archive = paths.downloads.appendingPathComponent("wine-runtime-\(Self.runtimeVersion).tar.gz")
        try? fm.removeItem(at: archive)
        defer { try? fm.removeItem(at: archive) }
        let span = 0.85 - runtimeStart
        progress(runtimeStart, "Mengunduh Wine \(Self.wineVersion)…")
        try await Downloader.download(Self.runtimeURL, to: archive) { fraction in
            progress(runtimeStart + fraction * span, "Mengunduh Wine \(Self.wineVersion)… \(Int(fraction * 100))%")
        }
        progress(0.86, "Memeriksa unduhan…")
        try await Self.verifySHA256(of: archive, expected: Self.runtimeSHA256)

        progress(0.88, "Mengekstrak…")
        let staging = paths.engines.appendingPathComponent(".staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Shell.runChecked(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path])
        try? fm.removeItem(at: engineRoot)
        try fm.moveItem(at: staging.appendingPathComponent("Libraries", isDirectory: true), to: engineRoot)

        progress(0.95, "Memasang D3DMetal…")
        let engine = WineEngine(root: engineRoot)
        try D3DMetalPayload.deploy(from: d3dMetalStore, into: engine)
        // Not fatal if this fails: the attribute may simply not be there.
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", engineRoot.path])
        let stamp: NSDictionary = ["runtimeVersion": Self.runtimeVersion, "wineVersion": Self.wineVersion]
        try stamp.write(to: engine.stampFile)

        guard engine.isUsable else { throw HubError.notFound("wine64 di dalam \(engineRoot.path)") }
        progress(1, "Selesai")
        return engine
    }

    public func uninstallOwnEngine() throws {
        if FileManager.default.fileExists(atPath: engineRoot.path) {
            try FileManager.default.removeItem(at: engineRoot)
        }
    }

    static func gptkLib(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/wine/lib", isDirectory: true)
    }

    /// Downloads GPTK, keeps its D3DMetal payload and deletes the rest.
    private func fetchD3DMetal(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let fm = FileManager.default
        let archive = paths.downloads.appendingPathComponent("game-porting-toolkit-\(Self.gptkVersion).tar.xz")
        let unpacked = paths.downloads.appendingPathComponent("gptk-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: archive)
            try? fm.removeItem(at: unpacked)
        }
        progress(0, "Mengunduh D3DMetal (Game Porting Toolkit)…")
        try await Downloader.download(Self.gptkURL, to: archive) { fraction in
            progress(fraction * 0.9, "Mengunduh D3DMetal (Game Porting Toolkit)… \(Int(fraction * 100))%")
        }
        progress(0.9, "Mengekstrak D3DMetal…")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await Shell.runChecked(URL(fileURLWithPath: "/usr/bin/tar"), ["-xJf", archive.path, "-C", unpacked.path])
        let lib = Self.gptkLib(unpacked.appendingPathComponent(Self.gptkBundleName, isDirectory: true))
        guard D3DMetalPayload.isComplete(at: lib) else {
            throw HubError.notFound("D3DMetal di dalam Game Porting Toolkit \(Self.gptkVersion)")
        }
        try D3DMetalPayload.copy(from: lib, to: d3dMetalStore)
    }

    static func verifySHA256(of file: URL, expected: String) async throws {
        let result = try await Shell.runChecked(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", file.path])
        let actual = result.output.split(separator: " ").first.map(String.init) ?? ""
        guard actual.lowercased() == expected.lowercased() else {
            throw HubError.downloadFailed("checksum tidak cocok (\(actual.prefix(12))…)")
        }
    }
}

/// URLSession download with progress reporting.
public enum Downloader {
    public static func download(_ url: URL, to destination: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReported: Double = -1

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.01 || fraction >= 1 {
            lastReported = fraction
            progress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = HubError.downloadFailed("HTTP \(http.statusCode)")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = continuation
        continuation = nil
        if let error {
            cont?.resume(throwing: HubError.downloadFailed(error.localizedDescription))
        } else if let moveError {
            cont?.resume(throwing: moveError)
        } else {
            cont?.resume()
        }
    }
}

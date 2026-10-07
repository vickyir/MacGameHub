import Foundation

/// Builds the environment for a Wine process in a given bottle.
public enum WineEnvironment {
    public static func make(engine: WineEngine,
                            prefix: URL,
                            settings: BottleSettings,
                            controllerFile: URL? = nil,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = settings.debugLogging ? "fixme-all,warn+seh,err+all" : "-all"
        // MoltenVK prints ~150 lines every time a process creates a Vulkan instance (Steam's helpers do
        // so constantly) and DXVK warns per texture query; all of it is written to the log mid-game.
        env["MVK_CONFIG_LOG_LEVEL"] = settings.debugLogging ? "2" : "0"
        env["DXVK_LOG_LEVEL"] = settings.debugLogging ? "warn" : "none"

        env.removeValue(forKey: "WINEESYNC")
        env.removeValue(forKey: "WINEMSYNC")
        switch settings.sync {
        case .none: break
        case .esync: env["WINEESYNC"] = "1"
        case .msync: env["WINEMSYNC"] = "1"
        }

        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" } else { env.removeValue(forKey: "MTL_HUD_ENABLED") }
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" } else { env.removeValue(forKey: "ROSETTA_ADVERTISE_AVX") }
        if settings.dxrSupport { env["D3DM_SUPPORT_DXR"] = "1" } else { env.removeValue(forKey: "D3DM_SUPPORT_DXR") }

        // Bridge mode: the XInput DLL reads controllers from this file instead of Wine's HID devices.
        if settings.controllerMode == .bridge, let controllerFile {
            env["MACGAMEHUB_CONTROLLER_FILE"] = controllerFile.path
        } else {
            env.removeValue(forKey: "MACGAMEHUB_CONTROLLER_FILE")
        }

        let systemPath = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = engine.binDirectory.path + ":" + systemPath

        for (key, value) in settings.extraEnvironment where !key.isEmpty {
            env[key] = value
        }
        return env
    }
}

/// What to execute with wine64 and from which directory.
public struct WineInvocation: Equatable, Sendable {
    public var arguments: [String]
    public var workingDirectory: URL?

    public init(arguments: [String], workingDirectory: URL? = nil) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public enum WineCommand {
    /// Arguments for launching a library entry.
    public static func invocation(for game: Game, driveC: URL) -> WineInvocation {
        let extra = ArgumentSplitter.split(game.arguments)
        switch game.launch {
        case let .executable(path):
            let exe = URL(fileURLWithPath: path)
            return WineInvocation(arguments: [exe.path] + extra,
                                  workingDirectory: exe.deletingLastPathComponent())
        case let .steam(appID):
            let steam = WinePaths.steamExecutable(driveC: driveC)
            return WineInvocation(arguments: [steam.path, "-applaunch", appID] + extra,
                                  workingDirectory: steam.deletingLastPathComponent())
        case let .epic(appName):
            let encoded = appName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appName
            return WineInvocation(arguments: ["start", "com.epicgames.launcher://apps/\(encoded)?action=launch&silent=true"],
                                  workingDirectory: nil)
        }
    }

    /// Arguments for running an installer: `.msi` goes through msiexec, everything else runs directly.
    public static func installer(_ file: URL, arguments: [String] = []) -> WineInvocation {
        if file.pathExtension.lowercased() == "msi" {
            return WineInvocation(arguments: ["msiexec", "/i", file.path] + arguments,
                                  workingDirectory: file.deletingLastPathComponent())
        }
        return WineInvocation(arguments: [file.path] + arguments,
                              workingDirectory: file.deletingLastPathComponent())
    }
}

/// Runs wine64 / wineserver for a bottle.
public final class WineRunner: @unchecked Sendable {
    public let engine: WineEngine
    public let paths: HubPaths

    public init(engine: WineEngine, paths: HubPaths) {
        self.engine = engine
        self.paths = paths
    }

    public func environment(for bottle: Bottle, extra: [String: String] = [:]) -> [String: String] {
        var env = WineEnvironment.make(engine: engine, prefix: paths.prefix(for: bottle.id), settings: bottle.settings,
                                       controllerFile: paths.controllerState)
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Starts a long-running process (a game, an installer, Steam). Output goes to `logURL`.
    /// `onExit` is called on a background thread with the exit status.
    @discardableResult
    public func launch(_ invocation: WineInvocation,
                       in bottle: Bottle,
                       logURL: URL,
                       onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        guard engine.isUsable else { throw HubError.engineMissing }
        guard EngineManager.isRosettaInstalled else { throw HubError.rosettaMissing }

        let process = Process()
        process.executableURL = engine.wine64
        process.arguments = invocation.arguments
        process.environment = environment(for: bottle)
        if let cwd = invocation.workingDirectory, FileManager.default.fileExists(atPath: cwd.path) {
            process.currentDirectoryURL = cwd
        }
        process.standardInput = FileHandle.nullDevice
        let log = Shell.openLog(logURL)
        if let log {
            let line = "$ wine64 " + invocation.arguments.joined(separator: " ") + "\n"
            log.write(Data(line.utf8))
            process.standardOutput = log
            process.standardError = log
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { proc in
            try? log?.close()
            onExit(proc.terminationStatus)
        }
        try process.run()
        return process
    }

    /// Runs a short wine command and waits for it (wineboot, reg, winecfg -v …).
    @discardableResult
    public func run(_ arguments: [String], in bottle: Bottle,
                    extraEnvironment: [String: String] = [:]) async throws -> ProcessResult {
        guard engine.isUsable else { throw HubError.engineMissing }
        guard EngineManager.isRosettaInstalled else { throw HubError.rosettaMissing }
        return try await Shell.run(engine.wine64, arguments,
                                   environment: environment(for: bottle, extra: extraEnvironment),
                                   logTo: paths.log(named: "bottle-\(bottle.id.uuidString)"))
    }

    /// Waits until every process in the bottle has exited.
    public func waitForServer(_ bottle: Bottle) async {
        _ = try? await Shell.run(engine.wineserver, ["-w"], environment: environment(for: bottle))
    }

    /// Kills every Wine process in the bottle.
    public func killAll(_ bottle: Bottle) async {
        _ = try? await Shell.run(engine.wineserver, ["-k"], environment: environment(for: bottle))
    }

    /// Creates the Wine prefix (C: drive, registry) and applies the bottle's settings.
    public func createPrefix(for bottle: Bottle) async throws {
        try FileManager.default.createDirectory(at: paths.prefix(for: bottle.id), withIntermediateDirectories: true)
        // mshtml= avoids the Wine Gecko download prompt blocking the first boot.
        let result = try await run(["wineboot", "--init"], in: bottle, extraEnvironment: ["WINEDLLOVERRIDES": "mshtml="])
        await waitForServer(bottle)
        guard FileManager.default.fileExists(atPath: paths.driveC(for: bottle.id).path) else {
            throw HubError.commandFailed("wineboot --init", result.status, result.output)
        }
        try await applySettings(bottle)
        try await prepare(bottle)
        await waitForServer(bottle)
    }

    /// Whether the bottle already has what this engine expects (see ``prepare(_:)``).
    public func isPrepared(_ bottle: Bottle) -> Bool {
        (try? String(contentsOf: preparedStamp(for: bottle), encoding: .utf8)) == preparedStampValue(for: bottle)
    }

    /// Bump when ``prepare(_:)`` changes what it writes, so existing bottles are prepared again.
    static let bottleRevision = 4

    /// Brings a bottle up to this engine: the first Wine command updates the prefix (a bottle made with
    /// an older Wine), then launcher clients get their DXVK overrides (``LauncherCompatibility``) and
    /// controllers are enabled (``ControllerSupport``). Recorded in the prefix, so it runs once per
    /// bottle, revision and engine.
    public func prepare(_ bottle: Bottle) async throws {
        // Drivers such as winebus read their settings only when they start, so a bottle still running
        // from before would keep ignoring controllers until every Wine process in it was gone.
        await killAll(bottle)
        let driveC = paths.driveC(for: bottle.id)
        try LauncherCompatibility.installNativeDLLs(engine: engine, driveC: driveC)
        try ControllerSupport.installXInputFix(driveC: driveC)
        let regFile = driveC.appendingPathComponent("windows/temp/macgamehub-launchers.reg")
        try FileManager.default.createDirectory(at: regFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let registry = LauncherCompatibility.registryFile() + "\r\n"
            + ControllerSupport.registrySection(mode: bottle.settings.controllerMode)
        try registry.write(to: regFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: regFile) }
        let result = try await run(["reg", "import", "C:\\windows\\temp\\macgamehub-launchers.reg"], in: bottle)
        guard result.status == 0 else {
            throw HubError.commandFailed("reg import", result.status, result.output)
        }
        try preparedStampValue(for: bottle).write(to: preparedStamp(for: bottle), atomically: true, encoding: .utf8)
    }

    /// Includes the controller mode: switching it rewrites winebus settings.
    private func preparedStampValue(for bottle: Bottle) -> String {
        "\(Self.bottleRevision) \(EngineManager.runtimeVersion) \(bottle.settings.controllerMode.rawValue)"
    }

    private func preparedStamp(for bottle: Bottle) -> URL {
        paths.prefix(for: bottle.id).appendingPathComponent(".macgamehub-prepared")
    }

    /// Writes settings that live in the Wine registry.
    public func applySettings(_ bottle: Bottle) async throws {
        _ = try await run(["winecfg", "-v", bottle.settings.windowsVersion.rawValue], in: bottle)
        _ = try await run(["reg", "add", "HKCU\\Software\\Wine\\Mac Driver",
                           "/v", "RetinaMode", "/t", "REG_SZ",
                           "/d", bottle.settings.retinaMode ? "y" : "n", "/f"], in: bottle)
    }
}

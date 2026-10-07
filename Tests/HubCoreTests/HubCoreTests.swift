import XCTest
@testable import HubCore

final class HubCoreTests: XCTestCase {
    func testArgumentSplitter() {
        XCTAssertEqual(ArgumentSplitter.split(#"-dx11  "-name with space" 'a b' C:\Games\x"#),
                       ["-dx11", "-name with space", "a b", #"C:\Games\x"#])
        XCTAssertEqual(ArgumentSplitter.split(""), [])
        XCTAssertEqual(ArgumentSplitter.split(#""""#), [""])
    }

    func testSteamManifest() {
        let acf = """
        "AppState"
        {
            "appid"     "1145360"
            "Universe"  "1"
            "name"      "Hades"
            "installdir"    "Hades"
            "UserConfig" { "language" "english" }
        }
        """
        XCTAssertEqual(GameScanner.parseSteamManifest(acf), DiscoveredGame(name: "Hades", launch: .steam(appID: "1145360")))
        let redist = acf.replacingOccurrences(of: "1145360", with: "228980")
        XCTAssertNil(GameScanner.parseSteamManifest(redist))
    }

    func testVDFLibraryFolders() {
        let vdf = #"""
        "libraryfolders"
        {
            "0" { "path" "C:\\Program Files (x86)\\Steam" "apps" { "570" "123" } }
            "1" { "path" "D:\\SteamLibrary" }
        }
        """#
        let root = VDFParser.parse(vdf)
        let paths = root["LibraryFolders"]?.children.compactMap { $0.1["path"]?.string }
        XCTAssertEqual(paths, [#"C:\Program Files (x86)\Steam"#, #"D:\SteamLibrary"#])
    }

    func testEpicManifest() throws {
        let game = #"{"DisplayName":"Alan Wake 2","AppName":"Dill","MainGameAppName":"Dill","AppCategories":["public","games","applications"]}"#
        XCTAssertEqual(GameScanner.parseEpicManifest(Data(game.utf8)), DiscoveredGame(name: "Alan Wake 2", launch: .epic(appName: "Dill")))
        let dlc = #"{"DisplayName":"DLC","AppName":"X","MainGameAppName":"Dill"}"#
        XCTAssertNil(GameScanner.parseEpicManifest(Data(dlc.utf8)))
    }

    func testWindowsPathConversion() {
        let c = URL(fileURLWithPath: "/tmp/p/drive_c")
        XCTAssertEqual(WinePaths.unixPath(fromWindows: #"C:\Games\Foo\foo.exe"#, driveC: c)?.path, "/tmp/p/drive_c/Games/Foo/foo.exe")
        XCTAssertNil(WinePaths.unixPath(fromWindows: #"D:\x"#, driveC: c))
    }

    func testEnvironment() {
        var s = BottleSettings()
        s.sync = .msync
        s.metalHUD = true
        s.advertiseAVX = false
        s.extraEnvironment = ["FOO": "bar"]
        let engine = WineEngine(root: URL(fileURLWithPath: "/E/Wine"))
        let env = WineEnvironment.make(engine: engine, prefix: URL(fileURLWithPath: "/b/1"), settings: s,
                                       base: ["PATH": "/usr/bin", "WINEESYNC": "1", "ROSETTA_ADVERTISE_AVX": "1"])
        XCTAssertEqual(env["WINEPREFIX"], "/b/1")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertNil(env["WINEESYNC"])
        XCTAssertNil(env["ROSETTA_ADVERTISE_AVX"])
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertEqual(env["PATH"], "/E/Wine/Wine/bin:/usr/bin")
        XCTAssertEqual(env["MVK_CONFIG_LOG_LEVEL"], "0")
        XCTAssertEqual(env["DXVK_LOG_LEVEL"], "none")
    }

    func testEngineNeedsCompletedInstall() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let engine = WineEngine(root: dir)
        try fm.createDirectory(at: engine.binDirectory, withIntermediateDirectories: true)
        for tool in [engine.wine64, engine.wineserver] {
            fm.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        XCTAssertFalse(engine.isUsable) // an interrupted install has no stamp yet
        try (["wineVersion": "11.16"] as NSDictionary).write(to: engine.stampFile)
        XCTAssertTrue(engine.isUsable)
        XCTAssertEqual(engine.version, "11.16")
    }

    func testD3DMetalDeploy() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        // A GPTK-shaped payload, and a Wine tree that ships its own D3D DLLs.
        let payload = dir.appendingPathComponent("payload")
        let engine = WineEngine(root: dir.appendingPathComponent("Wine"))
        let windows = engine.libDirectory.appendingPathComponent("wine/x86_64-windows")
        try fm.createDirectory(at: payload.appendingPathComponent("wine/x86_64-windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("external/D3DMetal.framework"), withIntermediateDirectories: true)
        try fm.createDirectory(at: windows, withIntermediateDirectories: true)
        fm.createFile(atPath: payload.appendingPathComponent("external/libd3dshared.dylib").path, contents: Data("dylib".utf8))
        for name in D3DMetalPayload.forwarders {
            fm.createFile(atPath: payload.appendingPathComponent("wine/x86_64-windows/\(name)").path, contents: Data("apple \(name)".utf8))
            fm.createFile(atPath: windows.appendingPathComponent(name).path, contents: Data("wine \(name)".utf8))
        }
        XCTAssertTrue(D3DMetalPayload.isComplete(at: payload))

        try D3DMetalPayload.deploy(from: payload, into: engine)
        try D3DMetalPayload.deploy(from: payload, into: engine) // a redeploy must keep Wine's originals

        for name in D3DMetalPayload.forwarders {
            XCTAssertEqual(try String(contentsOf: windows.appendingPathComponent(name), encoding: .utf8), "apple \(name)")
            XCTAssertEqual(try String(contentsOf: engine.originalsDirectory.appendingPathComponent(name), encoding: .utf8), "wine \(name)")
            let bridge = engine.libDirectory.appendingPathComponent("wine/x86_64-unix/" + name.replacingOccurrences(of: ".dll", with: ".so"))
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: bridge.path), "../../external/libd3dshared.dylib")
        }
        XCTAssertTrue(fm.fileExists(atPath: engine.d3dMetal.path))
    }

    func testLauncherNativeDLLs() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let engine = WineEngine(root: dir.appendingPathComponent("Wine"))
        for arch in ["x64", "x32"] {
            try fm.createDirectory(at: engine.dxvkDirectory.appendingPathComponent(arch), withIntermediateDirectories: true)
            for dll in ["d3d11.dll", "d3d10core.dll"] {
                fm.createFile(atPath: engine.dxvkDirectory.appendingPathComponent("\(arch)/\(dll)").path, contents: Data("dxvk \(arch) \(dll)".utf8))
            }
        }
        try fm.createDirectory(at: engine.originalsDirectory, withIntermediateDirectories: true)
        let dxgi = Data(count: 0x40) + Data("Wine builtin DLL".utf8) + Data(count: 16)
        fm.createFile(atPath: engine.originalsDirectory.appendingPathComponent("dxgi.dll").path, contents: dxgi)

        let driveC = dir.appendingPathComponent("drive_c")
        try LauncherCompatibility.installNativeDLLs(engine: engine, driveC: driveC)

        XCTAssertEqual(try String(contentsOf: driveC.appendingPathComponent("windows/system32/d3d11.dll"), encoding: .utf8), "dxvk x64 d3d11.dll")
        XCTAssertEqual(try String(contentsOf: driveC.appendingPathComponent("windows/syswow64/d3d10core.dll"), encoding: .utf8), "dxvk x32 d3d10core.dll")
        let installed = try Data(contentsOf: driveC.appendingPathComponent("windows/system32/dxgi.dll"))
        XCTAssertEqual(installed.count, dxgi.count)
        XCTAssertNil(installed.range(of: Data("Wine builtin DLL".utf8)))
    }

    func testStripBuiltinMarker() {
        let marked = Data(count: 0x40) + Data("Wine builtin DLL".utf8) + Data([1, 2, 3])
        let stripped = LauncherCompatibility.strippingBuiltinMarker(marked)
        XCTAssertEqual(stripped.count, marked.count)
        XCTAssertNil(stripped.range(of: Data("Wine builtin DLL".utf8)))
        XCTAssertEqual(stripped.suffix(3), Data([1, 2, 3]))
        // Native DLLs and short files are left alone.
        let native = Data(count: 0x40) + Data("This program can".utf8)
        XCTAssertEqual(LauncherCompatibility.strippingBuiltinMarker(native), native)
        XCTAssertEqual(LauncherCompatibility.strippingBuiltinMarker(Data([0x4D, 0x5A])), Data([0x4D, 0x5A]))
    }

    func testLauncherRegistryFile() {
        let reg = LauncherCompatibility.registryFile()
        XCTAssertTrue(reg.hasPrefix("REGEDIT4\r\n"))
        XCTAssertTrue(reg.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\steamwebhelper.exe\DllOverrides]"#))
        XCTAssertTrue(reg.contains(#""d3d11"="native,builtin""#))
        XCTAssertTrue(reg.contains(#""d3d12"="""#))
        XCTAssertEqual(reg.components(separatedBy: "[HKEY_CURRENT_USER").count - 1,
                       LauncherCompatibility.clientExecutables.count)
    }

    func testInvocations() {
        let c = URL(fileURLWithPath: "/p/drive_c")
        let exe = Game(bottleID: UUID(), name: "X", launch: .executable(path: "/p/drive_c/Games/X/x.exe"), arguments: "-dx11")
        XCTAssertEqual(WineCommand.invocation(for: exe, driveC: c),
                       WineInvocation(arguments: ["/p/drive_c/Games/X/x.exe", "-dx11"], workingDirectory: URL(fileURLWithPath: "/p/drive_c/Games/X", isDirectory: true)))
        let steam = Game(bottleID: UUID(), name: "Hades", launch: .steam(appID: "1145360"))
        XCTAssertEqual(WineCommand.invocation(for: steam, driveC: c).arguments,
                       ["/p/drive_c/Program Files (x86)/Steam/steam.exe", "-applaunch", "1145360"])
        XCTAssertEqual(WineCommand.installer(URL(fileURLWithPath: "/d/Epic.msi")).arguments, ["msiexec", "/i", "/d/Epic.msi"])
    }

    func testLibraryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(fileURL: dir.appendingPathComponent("library.json"))
        let bottle = Bottle(name: "Steam")
        let lib = LibraryData(bottles: [bottle], games: [Game(bottleID: bottle.id, name: "Hades", launch: .steam(appID: "1145360"))])
        try store.save(lib)
        let loaded = try store.load()
        XCTAssertEqual(loaded.bottles.map(\.name), ["Steam"])
        XCTAssertEqual(loaded.games.first?.launch, .steam(appID: "1145360"))
    }

    func testExecutableScan() throws {
        let fm = FileManager.default
        let c = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("drive_c")
        let game = c.appendingPathComponent("GOG Games/Hollow Knight")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        fm.createFile(atPath: game.appendingPathComponent("hollow_knight.exe").path, contents: Data(count: 4000))
        fm.createFile(atPath: game.appendingPathComponent("unins000.exe").path, contents: Data(count: 90000))
        fm.createFile(atPath: game.appendingPathComponent("UnityCrashHandler64.exe").path, contents: Data(count: 90000))
        let found = GameScanner.executableGames(driveC: c)
        XCTAssertEqual(found.map(\.name), ["Hollow Knight"])
        if case let .executable(path) = found.first?.launch {
            XCTAssertTrue(path.hasSuffix("hollow_knight.exe"))
        } else {
            XCTFail("expected executable")
        }
    }
    func testProcessParsingAndTreeMemory() {
        let ps = """
          100     1  2048 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          101   100  1024 /Applications/Google Chrome.app/Contents/Frameworks/Helper --type=renderer
          102   101   512 /Applications/Google Chrome.app/Contents/Frameworks/Helper --type=gpu
          200     1    64 /usr/bin/other
        garbage line
        """
        let processes = ProcessMonitor.parse(ps)
        XCTAssertEqual(processes.count, 4)
        XCTAssertEqual(processes[1].command, "/Applications/Google Chrome.app/Contents/Frameworks/Helper --type=renderer")
        XCTAssertEqual(ProcessMonitor.treeMemory(of: 100, in: processes), (2048 + 1024 + 512) * 1024)
        XCTAssertEqual(ProcessMonitor.treeMemory(of: 200, in: processes), 64 * 1024)
    }

    func testRunningGameDetection() {
        func wine(_ pid: Int32, _ command: String) -> RunningProcess {
            RunningProcess(pid: pid, parentPID: 1, residentBytes: 0, command: command)
        }
        let processes = [
            wine(1, #"C:\Program Files (x86)\Steam\steam.exe -silent"#),
            wine(2, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=gpu-process"#),
            wine(3, #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\UplayWebCore.exe"#),
            wine(4, #"C:\Program Files (x86)\Steam\steamapps\common\Assassin's Creed Mirage\ACMirage.exe -uplay"#),
            wine(5, #"C:\Program Files (x86)\Steam\steamapps\common\Assassin's Creed Mirage\UbisoftConnectInstaller.exe"#),
            wine(6, #"C:\Program Files (x86)\Steam\steamapps\common\Steamworks Shared\_CommonRedist\vcredist\x.exe"#),
            wine(7, #"C:\GOG Games\Hollow Knight\hollow_knight.exe"#),
            wine(8, "/usr/bin/ps -ax"),
        ]
        let games = ProcessMonitor.runningGames(in: processes, libraryExecutables: ["hollow_knight.exe"])
        XCTAssertEqual(games.map(\.pid), [4, 7])
        XCTAssertEqual(games.first?.name, "ACMirage")
    }

    func testLegacyProcesses() {
        let legacy = URL(fileURLWithPath: "/E/Game Porting Toolkit.app")
        let processes = [
            RunningProcess(pid: 1, parentPID: 1, residentBytes: 0, command: "/E/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64-preloader C:\\windows\\system32\\services.exe"),
            RunningProcess(pid: 2, parentPID: 1, residentBytes: 0, command: #"C:\windows\system32\services.exe"#),
        ]
        XCTAssertEqual(ProcessMonitor.processes(in: processes, runningFrom: legacy).map(\.pid), [1])
    }

    func testControllerRegistry() {
        let reg = ControllerSupport.registrySection(mode: .bridge)
        XCTAssertTrue(reg.contains(#"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\winebus]"#))
        XCTAssertTrue(reg.contains(#""Enable SDL"=dword:00000000"#))
        XCTAssertTrue(reg.contains(#""DisableInput"=dword:00000001"#))
        XCTAssertTrue(reg.contains(#"[HKEY_CURRENT_USER\Software\Wine\DllOverrides]"#))
        XCTAssertTrue(reg.contains(#""xinput1_4"="native""#))
    }

    func testControllerRegistryModes() {
        XCTAssertTrue(ControllerSupport.registrySection(mode: .bridge).contains(#""DisableHidraw"=dword:00000001"#))
        XCTAssertTrue(ControllerSupport.registrySection(mode: .wineHID).contains(#""DisableHidraw"=dword:00000000"#))
    }

    func testBridgeFileLayout() {
        var pad = BridgePad()
        pad.buttons = BridgePad.a | BridgePad.start
        pad.leftTrigger = 7
        pad.rightTrigger = 255
        pad.leftX = -32767
        pad.leftY = BridgePad.axis(1) // stick pushed up
        pad.rightX = 3
        pad.rightY = -4
        let data = ControllerBridge.encode(pads: [nil, pad, nil, nil], packet: 9, heartbeat: 5)
        func u32(_ o: Int) -> UInt32 { data[o..<o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func i16(_ o: Int) -> Int16 { data[o..<o + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) } }
        XCTAssertEqual(data.count, 80)
        XCTAssertEqual(Data(data[0..<4]), Data("MGHC".utf8))
        XCTAssertEqual(u32(4), 1)
        XCTAssertEqual(u32(8), 9)
        XCTAssertEqual(u32(12), 5)
        XCTAssertEqual(data[16], 0) // slot 0 empty
        let slot = 32 // slot 1
        XCTAssertEqual(data[slot], 1)
        XCTAssertEqual(UInt16(data[slot + 2]) | UInt16(data[slot + 3]) << 8, 0x1010)
        XCTAssertEqual(data[slot + 4], 7)
        XCTAssertEqual(data[slot + 5], 255)
        XCTAssertEqual(i16(slot + 6), -32767)
        XCTAssertEqual(i16(slot + 8), 32767) // up is positive, as XInput expects
        XCTAssertEqual(i16(slot + 10), 3)
        XCTAssertEqual(i16(slot + 12), -4)
    }

    func testBridgeWritesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let bridge = ControllerBridge(fileURL: url)
        var pad = BridgePad()
        pad.leftY = 100
        bridge.update(slot: 0, pad: pad)
        bridge.beat()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 80)
        XCTAssertEqual(data[16], 1)
        bridge.disconnectAll()
        XCTAssertEqual(try Data(contentsOf: url)[16], 0)
    }

    func testOldBottleSettingsStillDecode() throws {
        let json = #"{"windowsVersion":"win11","sync":"msync","metalHUD":false,"retinaMode":false,"advertiseAVX":true,"dxrSupport":false,"debugLogging":false,"extraEnvironment":{}}"#
        let settings = try JSONDecoder().decode(BottleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.windowsVersion, .win11)
        XCTAssertEqual(settings.controllerMode, .bridge)
    }

    func testControllerFileOnlyInBridgeMode() {
        let engine = WineEngine(root: URL(fileURLWithPath: "/E/Wine"))
        let file = URL(fileURLWithPath: "/R/controller-state.bin")
        var s = BottleSettings()
        XCTAssertEqual(WineEnvironment.make(engine: engine, prefix: URL(fileURLWithPath: "/b"), settings: s, controllerFile: file, base: [:])["MACGAMEHUB_CONTROLLER_FILE"], "/R/controller-state.bin")
        s.controllerMode = .wineHID
        XCTAssertNil(WineEnvironment.make(engine: engine, prefix: URL(fileURLWithPath: "/b"), settings: s, controllerFile: file, base: ["MACGAMEHUB_CONTROLLER_FILE": "x"])["MACGAMEHUB_CONTROLLER_FILE"])
    }

    func testXInputFixInstall() throws {
        let fm = FileManager.default
        let driveC = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("drive_c")
        defer { try? fm.removeItem(at: driveC.deletingLastPathComponent()) }
        try ControllerSupport.installXInputFix(driveC: driveC)
        for name in ["xinput1_3", "xinput1_4", "xinput9_1_0"] {
            let x64 = try Data(contentsOf: driveC.appendingPathComponent("windows/system32/\(name).dll"))
            let x86 = try Data(contentsOf: driveC.appendingPathComponent("windows/syswow64/\(name).dll"))
            XCTAssertEqual(x64.prefix(2), Data("MZ".utf8))
            XCTAssertEqual(x86.prefix(2), Data("MZ".utf8))
            // Native DLLs: no Wine builtin marker, or Wine would load its own instead.
            XCTAssertNil(x64.range(of: Data("Wine builtin DLL".utf8)))
        }
    }
}


/// The real engine install and a real bottle, against the actual downloads (~700 MB, needs Rosetta).
/// Opt-in: `MACGAMEHUB_INTEGRATION=1 swift test --filter EngineIntegrationTests`
final class EngineIntegrationTests: XCTestCase {
    func testInstallEngineAndCreateBottle() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACGAMEHUB_INTEGRATION"] == "1",
                          "set MACGAMEHUB_INTEGRATION=1 to run")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macgamehub-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root)

        let engine = try await EngineManager(paths: paths).install { _, _ in }
        XCTAssertTrue(engine.isUsable)
        XCTAssertEqual(engine.version, EngineManager.wineVersion)
        XCTAssertNotNil(engine.d3dMetalVersion)

        let runner = WineRunner(engine: engine, paths: paths)
        let bottle = Bottle(name: "Integration")
        try await runner.createPrefix(for: bottle)
        XCTAssertTrue(runner.isPrepared(bottle))
        let userReg = try String(contentsOf: paths.prefix(for: bottle.id).appendingPathComponent("user.reg"), encoding: .utf8)
        XCTAssertTrue(userReg.contains(#"AppDefaults\\steamwebhelper.exe\\DllOverrides"#))
        await runner.killAll(bottle)
    }
}

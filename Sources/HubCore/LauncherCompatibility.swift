import Foundation

/// Keeps launcher clients (Steam, Epic, Ubisoft Connect) off D3DMetal.
///
/// All of them draw their windows with Chromium. Chromium's GPU process crashes on D3DMetal, and on Wine's own
/// wined3d it only gets OpenGL ES 2, which leaves Steam without a window. So their processes run D3D11
/// on DXVK (→ Vulkan → MoltenVK → Metal) through per-program `AppDefaults` overrides, while every other
/// program, the games Steam starts included, keeps the builtin DLLs: Apple's D3DMetal forwarders.
public enum LauncherCompatibility {
    /// `AppDefaults` apply per executable and aren't inherited, so every process that draws needs its own.
    public static let clientExecutables = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe", "gameoverlayui64.exe", "GameOverlayUI.exe",
        "EpicGamesLauncher.exe", "EpicWebHelper.exe",
        "upc.exe", "UbisoftConnect.exe", "UplayWebCore.exe",
    ]

    /// DXVK's d3d11/d3d10core and Wine's own dxgi first. d3d12 is off: the builtin behind it is
    /// D3DMetal's, and handing it a DXVK adapter crashes.
    static let dllOverrides = [
        ("d3d10core", "native,builtin"), ("d3d11", "native,builtin"), ("d3d12", ""), ("dxgi", "native,builtin"),
    ]

    /// The overrides as a `.reg` file for `reg import`.
    public static func registryFile() -> String {
        var lines = ["REGEDIT4", ""]
        for exe in clientExecutables {
            lines.append("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides]")
            lines += dllOverrides.map { "\"\($0.0)\"=\"\($0.1)\"" }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// Puts the native DLLs the overrides point at into a bottle: DXVK's d3d11 and d3d10core for both
    /// architectures, and Wine's own 64-bit dxgi (DXVK-macOS ships none and is built against Wine's)
    /// with its builtin marker removed, so Wine loads it as native. Wine's 32-bit dxgi was never replaced.
    ///
    /// Programs without overrides still get the builtins: Wine prefers a builtin over a native file in
    /// system32 unless told otherwise.
    public static func installNativeDLLs(engine: WineEngine, driveC: URL) throws {
        let fm = FileManager.default
        let windows = driveC.appendingPathComponent("windows", isDirectory: true)
        for (arch, folder) in [("x64", "system32"), ("x32", "syswow64")] {
            let target = windows.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for dll in ["d3d11.dll", "d3d10core.dll"] {
                let destination = target.appendingPathComponent(dll)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: engine.dxvkDirectory.appendingPathComponent("\(arch)/\(dll)"), to: destination)
            }
        }
        let dxgi = try Data(contentsOf: engine.originalsDirectory.appendingPathComponent("dxgi.dll"))
        try strippingBuiltinMarker(dxgi).write(to: windows.appendingPathComponent("system32/dxgi.dll"), options: .atomic)
    }

    /// Wine marks its builtin DLLs with "Wine builtin DLL" at offset 0x40 and loads them from its own
    /// tree; overwriting the marker with a plain DOS stub turns the file into an ordinary native DLL.
    static func strippingBuiltinMarker(_ dll: Data) -> Data {
        let marker = Data("Wine builtin DLL".utf8)
        let start = dll.startIndex + 0x40
        guard dll.count >= 0x40 + marker.count, dll[start..<start + marker.count] == marker else { return dll }
        let stub: [UInt8] = [0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD, 0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21, 0x90, 0x90]
        var patched = dll
        patched.replaceSubrange(start..<start + stub.count, with: stub)
        return patched
    }
}

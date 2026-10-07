import Foundation

/// Lets games see game controllers, the right way up.
///
/// Wine's HID bus hands gamepads to its SDL backend, and on Linux to evdev; the macOS runtime has
/// neither, so a connected controller is found and then ignored ("ignoring hidraw device 045e:02e0").
/// Turning both off makes winebus take gamepads over raw HID (IOHID on macOS), which also gives them
/// an XInput device for games that use XInput.
///
/// That XInput device reports both sticks' Y axis upside down on this runtime (measured: a stick pushed
/// up reads 0 over raw HID but a negative ThumbLY over XInput). So the XInput DLLs games load are
/// replaced with a small native one (Support/xinput-fix) that forwards to Wine's builtin xinput1_2 and
/// flips ThumbLY/ThumbRY.
public enum ControllerSupport {
    /// The XInput DLL names games link against; each gets the fixing DLL.
    static let xinputNames = ["xinput1_3", "xinput1_4", "xinput9_1_0"]

    /// `.reg` lines to append to a `REGEDIT4` file: winebus options and the native XInput overrides.
    /// In bridge mode Wine's raw HID path is off entirely, so controller reports never reach wineserver.
    public static func registrySection(mode: ControllerMode) -> String {
        var lines = [
            #"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\winebus]"#,
            #""Enable SDL"=dword:00000000"#,
            #""DisableInput"=dword:00000001"#,
            mode == .bridge ? #""DisableHidraw"=dword:00000001"# : #""DisableHidraw"=dword:00000000"#,
            "",
            #"[HKEY_CURRENT_USER\Software\Wine\DllOverrides]"#,
        ]
        lines += xinputNames.map { "\"\($0)\"=\"native\"" }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// Writes the fixing XInput DLL into a bottle under every XInput name, 64-bit and 32-bit.
    public static func installXInputFix(driveC: URL) throws {
        let windows = driveC.appendingPathComponent("windows", isDirectory: true)
        for (folder, dll) in [("system32", XInputFixDLLs.x64), ("syswow64", XInputFixDLLs.x86)] {
            let target = windows.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for name in xinputNames {
                try dll.write(to: target.appendingPathComponent("\(name).dll"), options: .atomic)
            }
        }
    }
}

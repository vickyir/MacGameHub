import Foundation

/// Official Windows installers for the store launchers.
public enum StoreInstaller: String, CaseIterable, Identifiable, Sendable {
    case steam, epic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .epic: return "Epic Games Launcher"
        }
    }

    public var downloadURL: URL {
        switch self {
        case .steam:
            return URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
        case .epic:
            return URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!
        }
    }

    public var fileName: String {
        switch self {
        case .steam: return "SteamSetup.exe"
        case .epic: return "EpicGamesLauncherInstaller.msi"
        }
    }

    /// Where the launcher executable ends up inside the bottle once installed.
    public func installedExecutable(driveC: URL) -> URL {
        switch self {
        case .steam:
            return WinePaths.steamExecutable(driveC: driveC)
        case .epic:
            return driveC.appendingPathComponent(
                "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe")
        }
    }

    /// Arguments recommended when starting the launcher itself under Wine.
    public var defaultLaunchArguments: String {
        switch self {
        case .steam: return ""
        // The Epic launcher's GPU-accelerated UI is the most common source of blank windows under Wine.
        case .epic: return "-opengl -SkipBuildPatchPrereq"
        }
    }
}

import Foundation

public enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, esync, msync
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: return "Off"
        case .esync: return "ESync"
        case .msync: return "MSync (recommended)"
        }
    }
}

public enum WindowsVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case win7, win8, win81, win10, win11
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .win7: return "Windows 7"
        case .win8: return "Windows 8"
        case .win81: return "Windows 8.1"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }
}

public struct BottleSettings: Codable, Equatable, Hashable, Sendable {
    public var windowsVersion: WindowsVersion = .win10
    public var sync: SyncMode = .msync
    /// Shows Apple's Metal Performance HUD (FPS, GPU time) over the game.
    public var metalHUD: Bool = false
    /// Renders at native Retina resolution (sharper, heavier on the GPU).
    public var retinaMode: Bool = false
    /// Lets Rosetta report AVX/AVX2 support (macOS 15+). Needed by many newer games.
    public var advertiseAVX: Bool = true
    /// Enables DirectX Raytracing in D3DMetal (M3 or newer).
    public var dxrSupport: Bool = false
    /// Verbose Wine logging. Slower; only turn on while troubleshooting.
    public var debugLogging: Bool = false
    /// Extra environment variables, e.g. ["WINEDLLOVERRIDES": "dinput8=n,b"].
    public var extraEnvironment: [String: String] = [:]
    /// How games get controllers (see ``ControllerMode``).
    public var controllerMode: ControllerMode = .bridge

    public init() {}

    // Tolerant decoding so older library.json files keep loading when fields are added.
    enum CodingKeys: String, CodingKey {
        case windowsVersion, sync, metalHUD, retinaMode, advertiseAVX, dxrSupport, debugLogging, extraEnvironment, controllerMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BottleSettings()
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? d.windowsVersion
        sync = try c.decodeIfPresent(SyncMode.self, forKey: .sync) ?? d.sync
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? d.retinaMode
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? d.advertiseAVX
        dxrSupport = try c.decodeIfPresent(Bool.self, forKey: .dxrSupport) ?? d.dxrSupport
        debugLogging = try c.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? d.debugLogging
        extraEnvironment = try c.decodeIfPresent([String: String].self, forKey: .extraEnvironment) ?? d.extraEnvironment
        controllerMode = try c.decodeIfPresent(ControllerMode.self, forKey: .controllerMode) ?? d.controllerMode
    }
}

public enum ControllerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// MacGameHub reads controllers with GameController and hands them to the XInput DLL
    /// (``ControllerBridge``); Wine's HID path stays off. Light, but XInput games only.
    case bridge
    /// Wine reads controllers over raw HID: DirectInput and raw-input games see them too, at the cost
    /// of wineserver load for every controller report.
    case wineHID

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bridge: return "MacGameHub (ringan, disarankan)"
        case .wineHID: return "Wine HID (untuk game DirectInput lama)"
        }
    }
}

public struct Bottle: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var settings: BottleSettings

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), settings: BottleSettings = BottleSettings()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.settings = settings
    }
}

public enum LaunchKind: Codable, Hashable, Sendable {
    /// A Windows executable, stored as a macOS (unix) path inside or outside the bottle.
    case executable(path: String)
    /// A Steam game launched through the Windows Steam client in the bottle.
    case steam(appID: String)
    /// An Epic Games Store title launched through the Epic Games Launcher protocol.
    case epic(appName: String)

    public var sourceLabel: String {
        switch self {
        case .executable: return "EXE"
        case .steam: return "Steam"
        case .epic: return "Epic"
        }
    }
}

public struct Game: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var bottleID: UUID
    public var name: String
    public var launch: LaunchKind
    /// Extra command-line arguments, written like in a shell: -dx11 "-some flag"
    public var arguments: String
    public var addedAt: Date
    public var lastPlayed: Date?
    public var totalPlaySeconds: Double

    public init(id: UUID = UUID(), bottleID: UUID, name: String, launch: LaunchKind, arguments: String = "",
                addedAt: Date = Date(), lastPlayed: Date? = nil, totalPlaySeconds: Double = 0) {
        self.id = id
        self.bottleID = bottleID
        self.name = name
        self.launch = launch
        self.arguments = arguments
        self.addedAt = addedAt
        self.lastPlayed = lastPlayed
        self.totalPlaySeconds = totalPlaySeconds
    }

    // Tolerant decoding so older library.json files keep loading when fields are added.
    enum CodingKeys: String, CodingKey { case id, bottleID, name, launch, arguments, addedAt, lastPlayed, totalPlaySeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bottleID = try c.decode(UUID.self, forKey: .bottleID)
        name = try c.decode(String.self, forKey: .name)
        launch = try c.decode(LaunchKind.self, forKey: .launch)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        totalPlaySeconds = try c.decodeIfPresent(Double.self, forKey: .totalPlaySeconds) ?? 0
    }
}

public struct LibraryData: Codable, Equatable, Sendable {
    public var bottles: [Bottle]
    public var games: [Game]

    public init(bottles: [Bottle] = [], games: [Game] = []) {
        self.bottles = bottles
        self.games = games
    }

    public func games(in bottleID: UUID) -> [Game] {
        games.filter { $0.bottleID == bottleID }
    }
}

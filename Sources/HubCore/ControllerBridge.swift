import Foundation

/// One controller's state in XInput terms.
public struct BridgePad: Equatable, Sendable {
    public var buttons: UInt16 = 0
    public var leftTrigger: UInt8 = 0
    public var rightTrigger: UInt8 = 0
    /// Thumbsticks, XInput convention: up and right are positive.
    public var leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0

    public init() {}

    // XInput button bits.
    public static let dpadUp: UInt16 = 0x0001, dpadDown: UInt16 = 0x0002, dpadLeft: UInt16 = 0x0004, dpadRight: UInt16 = 0x0008
    public static let start: UInt16 = 0x0010, back: UInt16 = 0x0020, leftThumb: UInt16 = 0x0040, rightThumb: UInt16 = 0x0080
    public static let leftShoulder: UInt16 = 0x0100, rightShoulder: UInt16 = 0x0200, guide: UInt16 = 0x0400
    public static let a: UInt16 = 0x1000, b: UInt16 = 0x2000, x: UInt16 = 0x4000, y: UInt16 = 0x8000

    /// A stick axis from GameController's -1…1 to XInput's range.
    public static func axis(_ value: Float) -> Int16 {
        Int16(max(-1, min(1, value)) * 32767)
    }

    public static func trigger(_ value: Float) -> UInt8 {
        UInt8(max(0, min(1, value)) * 255)
    }
}

/// Hands controllers to Windows games without going through Wine.
///
/// Wine reads a Bluetooth gamepad over raw HID, and every report (hundreds a second) passes through
/// winedevice and wineserver, the server every game thread also waits on: measured here, 28% + 29% CPU
/// with Steam merely open, ~55% + 55% in game, and stutter whenever the game is busy. Instead MacGameHub
/// reads controllers with macOS's GameController framework and writes their state into a small file;
/// the XInput DLL in each bottle (Support/xinput-fix) reads that file, and Wine's HID path is turned off.
///
/// File layout, little endian: magic `MGHC`, version, packet (bumped on every change), heartbeat (bumped
/// every 100 ms so the DLL notices when MacGameHub isn't running), then 4 slots of 16 bytes:
/// connected, pad, buttons (u16), left/right trigger, lx, ly, rx, ry (s16), pad.
public final class ControllerBridge: @unchecked Sendable {
    public static let slotCount = 4
    static let size = 16 + 16 * slotCount
    static let magic: UInt32 = 0x4348_474D

    public let fileURL: URL
    private let lock = NSLock()
    private var pads: [BridgePad?] = Array(repeating: nil, count: slotCount)
    private var packet: UInt32 = 0
    private var heartbeat: UInt32 = 0
    private var handle: FileHandle?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Sets (or clears, with nil) a slot and writes the file.
    public func update(slot: Int, pad: BridgePad?) {
        guard (0..<Self.slotCount).contains(slot) else { return }
        lock.lock(); defer { lock.unlock() }
        guard pads[slot] != pad else { return }
        pads[slot] = pad
        packet &+= 1
        write()
    }

    /// Called on a timer; lets the DLL tell a live bridge from a stale file.
    public func beat() {
        lock.lock(); defer { lock.unlock() }
        heartbeat &+= 1
        write()
    }

    /// Marks every slot disconnected, e.g. when MacGameHub quits.
    public func disconnectAll() {
        lock.lock(); defer { lock.unlock() }
        pads = Array(repeating: nil, count: Self.slotCount)
        packet &+= 1
        write()
    }

    /// The file contents for the current state. One write of the whole block keeps readers consistent:
    /// regular-file reads and writes on macOS don't interleave.
    static func encode(pads: [BridgePad?], packet: UInt32, heartbeat: UInt32) -> Data {
        var data = Data(count: size)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        }
        put(magic, at: 0)
        put(UInt32(1), at: 4)
        put(packet, at: 8)
        put(heartbeat, at: 12)
        for (index, pad) in pads.enumerated() {
            guard let pad else { continue }
            let base = 16 + 16 * index
            put(UInt8(1), at: base)
            put(pad.buttons, at: base + 2)
            put(pad.leftTrigger, at: base + 4)
            put(pad.rightTrigger, at: base + 5)
            put(pad.leftX, at: base + 6)
            put(pad.leftY, at: base + 8)
            put(pad.rightX, at: base + 10)
            put(pad.rightY, at: base + 12)
        }
        return data
    }

    private func write() {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: Data(count: Self.size))
            }
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let handle else { return }
        let data = Self.encode(pads: pads, packet: packet, heartbeat: heartbeat)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: data)
    }
}

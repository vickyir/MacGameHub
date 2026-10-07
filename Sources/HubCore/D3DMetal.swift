import Foundation

/// Apple's D3DMetal as GPTK ships it (its `lib/` folder): `external/` holds D3DMetal.framework and
/// libd3dshared.dylib, `wine/x86_64-windows/` the PE forwarders that stand in for Wine's own D3D DLLs.
enum D3DMetalPayload {
    /// The forwarders that get deployed. Apple's NVIDIA bridges (nvapi64, nvngx) stay out: Chromium probes
    /// for an NVIDIA GPU and would drag D3DMetal into launcher clients through them.
    static let forwarders = ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]
    static let sharedLibrary = "libd3dshared.dylib"

    static func isComplete(at lib: URL) -> Bool {
        let fm = FileManager.default
        let external = lib.appendingPathComponent("external", isDirectory: true)
        let windows = lib.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        return fm.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path)
            && fm.fileExists(atPath: external.appendingPathComponent(sharedLibrary).path)
            && forwarders.allSatisfy { fm.fileExists(atPath: windows.appendingPathComponent($0).path) }
    }

    /// Copies just the payload out of a GPTK `lib/` folder into `destination`, replacing what was there.
    static func copy(from lib: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        let windows = staging.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        try fm.createDirectory(at: windows, withIntermediateDirectories: true)
        // copyItem keeps symlinks as symlinks, which the framework's Versions/Current layout relies on.
        try fm.copyItem(at: lib.appendingPathComponent("external", isDirectory: true),
                        to: staging.appendingPathComponent("external", isDirectory: true))
        for name in forwarders {
            try fm.copyItem(at: lib.appendingPathComponent("wine/x86_64-windows/\(name)"),
                            to: windows.appendingPathComponent(name))
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
    }

    /// Installs the payload into an engine the way Apple documents for GPTK-ready Wine builds: each
    /// forwarder replaces Wine's DLL (the original goes to `originals/`) and gets a unix bridge, and
    /// `external/` goes beside them.
    ///
    /// The bridges must be symlinks: libd3dshared finds the framework through `@loader_path`, which
    /// a copy inside `x86_64-unix/` would point at the wrong folder.
    static func deploy(from payload: URL, into engine: WineEngine) throws {
        let fm = FileManager.default
        let windows = engine.libDirectory.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        let unix = engine.libDirectory.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: engine.originalsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)

        for name in forwarders {
            let target = windows.appendingPathComponent(name)
            let original = engine.originalsDirectory.appendingPathComponent(name)
            let apple = payload.appendingPathComponent("wine/x86_64-windows/\(name)")
            // Keep Wine's own DLL once; a redeploy must not file Apple's forwarder away as the original.
            if fm.fileExists(atPath: target.path) {
                if !fm.fileExists(atPath: original.path), !fm.contentsEqual(atPath: target.path, andPath: apple.path) {
                    try fm.moveItem(at: target, to: original)
                } else {
                    try fm.removeItem(at: target)
                }
            }
            try fm.copyItem(at: apple, to: target)

            let bridge = unix.appendingPathComponent((name as NSString).deletingPathExtension + ".so")
            try? fm.removeItem(at: bridge)
            try fm.createSymbolicLink(atPath: bridge.path, withDestinationPath: "../../external/\(sharedLibrary)")
        }

        let external = engine.libDirectory.appendingPathComponent("external", isDirectory: true)
        try? fm.removeItem(at: external)
        try fm.copyItem(at: payload.appendingPathComponent("external", isDirectory: true), to: external)
    }
}

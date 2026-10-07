import HubCore
import SwiftUI

struct BottleSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    @State private var name: String
    @State private var settings: BottleSettings
    @State private var envText: String

    init(bottle: Bottle) {
        self.bottle = bottle
        _name = State(initialValue: bottle.name)
        _settings = State(initialValue: bottle.settings)
        _envText = State(initialValue: bottle.settings.extraEnvironment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n"))
    }

    private var hasChanges: Bool {
        var candidate = settings
        candidate.extraEnvironment = Self.parseEnvironment(envText)
        return candidate != bottle.settings || name != bottle.name
    }

    var body: some View {
        Form {
            Section("Umum") {
                TextField("Nama bottle", text: $name)
                Picker("Versi Windows", selection: $settings.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Lokasi") {
                    Text(model.paths.prefix(for: bottle.id).path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section {
                Picker("Sinkronisasi", selection: $settings.sync) {
                    ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Advertise AVX ke game", isOn: $settings.advertiseAVX)
                Toggle("DirectX Raytracing (M3 ke atas)", isOn: $settings.dxrSupport)
                Toggle("Mode Retina (lebih tajam, lebih berat)", isOn: $settings.retinaMode)
            } header: {
                Text("Performa & grafis")
            } footer: {
                Text("MSync membuat game jauh lebih lancar. Matikan AVX bila game crash saat dibuka.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Controller", selection: $settings.controllerMode) {
                    ForEach(ControllerMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Controller")
            } footer: {
                Text("MacGameHub membaca controller lewat macOS dan memberikannya ke game XInput tanpa membebani Wine. Pakai Wine HID hanya untuk game lama yang memakai DirectInput. Berlaku saat bottle dijalankan berikutnya.")
                    .foregroundStyle(.secondary)
            }

            Section("Debug") {
                Toggle("Metal Performance HUD (FPS overlay)", isOn: $settings.metalHUD)
                Toggle("Log Wine detail", isOn: $settings.debugLogging)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Variabel lingkungan tambahan (satu per baris, KEY=VALUE)")
                        .font(.callout)
                    TextEditor(text: $envText)
                        .font(.body.monospaced())
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("Contoh: WINEDLLOVERRIDES=dinput8=n,b")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Batalkan") { reset() }
                        .disabled(!hasChanges)
                    Button("Simpan") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges || model.bottleActivity[bottle.id] != nil)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func reset() {
        name = bottle.name
        settings = bottle.settings
        envText = bottle.settings.extraEnvironment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func apply() {
        var updated = settings
        updated.extraEnvironment = Self.parseEnvironment(envText)
        if name != bottle.name { model.renameBottle(bottle.id, to: name) }
        Task { await model.updateSettings(updated, for: bottle.id) }
    }

    static func parseEnvironment(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = value }
        }
        return env
    }
}

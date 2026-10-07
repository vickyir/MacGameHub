import HubCore
import SwiftUI

struct NewBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Bottle?) -> Void

    @State private var name = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var store: StoreChoice = .none
    @State private var working = false

    enum StoreChoice: String, CaseIterable, Identifiable {
        case none = "Tidak ada"
        case steam = "Steam"
        case epic = "Epic Games"
        var id: String { rawValue }
        var installer: StoreInstaller? {
            switch self {
            case .none: return nil
            case .steam: return .steam
            case .epic: return .epic
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Bottle baru").font(.title2.bold())
            Text("Bottle adalah “PC Windows” terpisah. Biasanya satu bottle untuk Steam, satu untuk Epic, sudah cukup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Nama", text: $name, prompt: Text("mis. Steam"))
                Picker("Versi Windows", selection: $windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.label).tag($0) }
                }
                Picker("Langsung instal", selection: $store) {
                    ForEach(StoreChoice.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .formStyle(.grouped)
            .disabled(working)

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Menyiapkan Windows… ini bisa 1–2 menit.").font(.callout)
                }
                Spacer()
                Button("Batal") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Buat") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: store) { _, newValue in
            if name.isEmpty || StoreChoice.allCases.map(\.rawValue).contains(name) {
                name = newValue == .none ? "" : newValue.rawValue
            }
        }
    }

    private func create() {
        working = true
        var settings = BottleSettings()
        settings.windowsVersion = windowsVersion
        let chosenStore = store.installer
        Task {
            let bottle = await model.createBottle(named: name, settings: settings)
            if let bottle, let chosenStore {
                await model.installStore(chosenStore, in: bottle.id)
            }
            working = false
            onCreated(bottle)
            dismiss()
        }
    }
}

struct EditGameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var game: Game

    init(game: Game) {
        _game = State(initialValue: game)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit game").font(.title2.bold())
            Form {
                TextField("Nama", text: $game.name)
                TextField("Argumen", text: $game.arguments, prompt: Text("mis. -dx11 -windowed"))
                LabeledContent("Sumber") { Text(sourceDescription).textSelection(.enabled).lineLimit(2) }
                Picker("Bottle", selection: $game.bottleID) {
                    ForEach(model.library.bottles) { Text($0.name).tag($0.id) }
                }
                .disabled(!isExecutable)
            }
            .formStyle(.grouped)

            HStack {
                Button("Lihat log") { model.openLog(for: game) }
                Spacer()
                Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Simpan") {
                    model.updateGame(game)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var isExecutable: Bool {
        if case .executable = game.launch { return true }
        return false
    }

    private var sourceDescription: String {
        switch game.launch {
        case let .executable(path): return path
        case let .steam(appID): return "Steam app \(appID)"
        case let .epic(appName): return "Epic: \(appName)"
        }
    }
}

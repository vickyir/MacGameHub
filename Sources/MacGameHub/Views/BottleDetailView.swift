import AppKit
import HubCore
import SwiftUI
import UniformTypeIdentifiers

struct BottleDetailView: View {
    @EnvironmentObject private var model: AppModel
    let bottleID: UUID

    private enum Tab: String, CaseIterable, Identifiable {
        case games = "Game"
        case settings = "Pengaturan"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .games
    @State private var scanResult: String?
    @State private var confirmDelete = false

    private var bottle: Bottle? { model.bottle(bottleID) }

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.bottleActivity[bottleID] {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.1))
            }
            if let scanResult {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(scanResult).font(.callout)
                    Spacer()
                    Button("Tutup") { self.scanResult = nil }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))
            }

            switch tab {
            case .games:
                LibraryView(bottleID: bottleID)
            case .settings:
                if let bottle {
                    BottleSettingsView(bottle: bottle)
                }
            }
        }
        .navigationTitle(bottle?.name ?? "Bottle")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tampilan", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Section("Toko game") {
                        ForEach(StoreInstaller.allCases) { store in
                            Button("Instal \(store.displayName)") {
                                Task { await model.installStore(store, in: bottleID) }
                            }
                        }
                    }
                    Section("File saya") {
                        Button("Jalankan installer (.exe / .msi)…") { pickInstaller() }
                        Button("Tambah game dari .exe…") { pickGameExecutable() }
                    }
                } label: {
                    Label("Tambah", systemImage: "plus")
                }
                .disabled(model.bottleActivity[bottleID] != nil)

                Button {
                    let added = model.scanGames(in: bottleID)
                    scanResult = added == 0 ? "Tidak ada game baru ditemukan." : "\(added) game baru ditambahkan."
                } label: {
                    Label("Pindai game", systemImage: "arrow.clockwise")
                }
                .help("Cari game Steam, Epic, dan .exe yang sudah terinstal di bottle ini")

                Menu {
                    Button("Buka drive C: di Finder") { model.openDriveC(bottleID) }
                    Button("Konfigurasi Wine (winecfg)") { model.runTool("winecfg", in: bottleID) }
                    Button("Registry editor") { model.runTool("regedit", in: bottleID) }
                    Button("Command prompt") { model.runTool("wineconsole", in: bottleID) }
                    Button("Task manager") { model.runTool("taskmgr", in: bottleID) }
                    Divider()
                    Button("Paksa tutup semua program") { Task { await model.killAll(bottleID) } }
                    Button("Hapus bottle…", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("Alat", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .confirmationDialog("Hapus bottle \(bottle?.name ?? "")?", isPresented: $confirmDelete) {
            Button("Pindahkan ke Trash", role: .destructive) {
                Task { await model.deleteBottle(bottleID) }
            }
        } message: {
            Text("Semua game yang terinstal di dalam bottle ini ikut terhapus (folder dipindah ke Trash).")
        }
    }

    // MARK: File pickers

    private static var windowsTypes: [UTType] {
        ["exe", "msi", "bat"].compactMap { UTType(filenameExtension: $0) }
    }

    private func pickInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Pilih installer Windows"
        panel.allowedContentTypes = Self.windowsTypes
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.runInstaller(url, in: bottleID)
    }

    private func pickGameExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Pilih file .exe game"
        panel.allowedContentTypes = Self.windowsTypes
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.paths.driveC(for: bottleID)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addExecutable(url, name: "", to: bottleID)
    }
}

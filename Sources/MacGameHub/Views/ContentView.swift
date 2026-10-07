import HubCore
import SwiftUI

enum SidebarItem: Hashable {
    case allGames
    case bottle(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .allGames
    @State private var showingNewBottle = false

    var body: some View {
        Group {
            if model.isReady {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            } else {
                SetupView()
            }
        }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $model.cleanupOffer) { offer in
            CleanupSheet(offer: offer)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingNewBottle) {
            NewBottleSheet { bottle in
                if let bottle { selection = .bottle(bottle.id) }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Perpustakaan") {
                Label("Semua Game", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.allGames)
            }
            Section("Bottles") {
                ForEach(model.library.bottles) { bottle in
                    HStack {
                        Label(bottle.name, systemImage: "shippingbox")
                        Spacer()
                        if model.bottleActivity[bottle.id] != nil {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .tag(SidebarItem.bottle(bottle.id))
                }
                Button {
                    showingNewBottle = true
                } label: {
                    Label("Bottle baru…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let game = model.runningGame {
                    Label("Sedang main: \(game.name)", systemImage: "gamecontroller.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                Button {
                    model.offerCleanup()
                } label: {
                    Label("Bersihkan RAM…", systemImage: "memorychip")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if let engine = model.engine {
                    Text("Engine: Wine \(engine.version)\(engine.d3dMetalVersion.map { " · D3DMetal \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .some(.bottle(let id)) where model.bottle(id) != nil:
            BottleDetailView(bottleID: id)
                .id(id)
        default:
            LibraryView(bottleID: nil, emptyAction: { showingNewBottle = true })
                .navigationTitle("Semua Game")
        }
    }
}

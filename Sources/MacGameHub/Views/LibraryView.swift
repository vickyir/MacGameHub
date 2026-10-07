import AppKit
import HubCore
import SwiftUI

/// Grid of games — all bottles (`bottleID == nil`) or one bottle.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    let bottleID: UUID?
    var emptyAction: (() -> Void)? = nil

    @State private var search = ""
    @State private var editing: Game?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)]

    private var games: [Game] {
        let all = model.games(in: bottleID)
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if model.games(in: bottleID).isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(games) { game in
                            GameCard(game: game, showBottle: bottleID == nil, onEdit: { editing = game })
                        }
                    }
                    .padding(20)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Cari game")
        .sheet(item: $editing) { game in
            EditGameSheet(game: game)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Belum ada game", systemImage: "gamecontroller")
        } description: {
            Text(model.library.bottles.isEmpty
                 ? "Buat bottle (lingkungan Windows) dulu, lalu instal Steam, Epic, atau file .exe Anda."
                 : "Buka sebuah bottle, lalu instal Steam/Epic, jalankan installer, atau tambahkan .exe.")
        } actions: {
            if model.library.bottles.isEmpty, let emptyAction {
                Button("Buat bottle", action: emptyAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct GameCard: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    var showBottle = false
    var onEdit: () -> Void

    @State private var hovering = false

    private var isRunning: Bool { model.running[game.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                GameArtwork(game: game)
                    .frame(height: 110)
                    .clipped()
                Text(game.launch.sourceLabel)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    isRunning ? model.stop(game) : model.launch(game)
                } label: {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .accentColor)
                .help(isRunning ? "Hentikan" : "Main")
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isRunning ? Color.green : Color.primary.opacity(hovering ? 0.2 : 0.08), lineWidth: isRunning ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isRunning ? "Hentikan" : "Main") { isRunning ? model.stop(game) : model.launch(game) }
            Button("Edit…", action: onEdit)
            Button("Lihat log") { model.openLog(for: game) }
            if case let .executable(path) = game.launch {
                Button("Tampilkan di Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Divider()
            Button("Hapus dari library", role: .destructive) { model.removeGame(game.id) }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if isRunning {
            parts.append("Sedang berjalan")
        } else if let last = game.lastPlayed {
            parts.append("Dimainkan " + last.formatted(.relative(presentation: .named)))
        } else {
            parts.append("Belum dimainkan")
        }
        if game.totalPlaySeconds >= 60 {
            let hours = game.totalPlaySeconds / 3600
            parts.append(hours >= 1 ? String(format: "%.1f jam", hours) : "\(Int(game.totalPlaySeconds / 60)) mnt")
        }
        if showBottle, let bottle = model.bottle(game.bottleID) {
            parts.append(bottle.name)
        }
        return parts.joined(separator: " · ")
    }
}

/// Steam header image when available, otherwise a generated gradient with initials.
struct GameArtwork: View {
    let game: Game

    var body: some View {
        if case let .steam(appID) = game.launch,
           let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg") {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        let hue = Double((game.name.hashValueStable & 0x7fff_ffff) % 360) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75),
                                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var initials: String {
        let words = game.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

private extension String {
    /// `hashValue` changes between launches; this doesn't, so a game keeps its colour.
    var hashValueStable: Int {
        unicodeScalars.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1.value) }
    }
}

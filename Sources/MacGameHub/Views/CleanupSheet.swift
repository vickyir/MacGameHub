import AppKit
import SwiftUI

/// Game Mode's question: which apps to quit so the game gets more memory.
struct CleanupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var offer: AppModel.CleanupOffer

    private var selectedMemory: UInt64 {
        offer.candidates.filter(\.selected).reduce(0) { $0 + $1.memory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(offer.game.map { "Mode Game: \($0.name)" } ?? "Bersihkan RAM").font(.title2.bold())
            Text("Tutup aplikasi yang tidak dipakai supaya game dapat RAM lebih banyak. Aplikasi ditutup seperti ⌘Q — yang punya pekerjaan belum disimpan akan bertanya dulu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if offer.candidates.isEmpty {
                Text("Tidak ada aplikasi lain yang bisa ditutup.").foregroundStyle(.secondary)
            } else {
                List($offer.candidates) { $candidate in
                    Toggle(isOn: $candidate.selected) {
                        HStack {
                            Image(nsImage: candidate.app.icon ?? NSImage())
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(candidate.name)
                            Spacer()
                            Text(Self.format(candidate.memory))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 220)
                Text("Dibebaskan sekitar \(Self.format(selectedMemory))")
                    .font(.callout)
            }

            Picker("Saat main game", selection: $model.gameModeBehavior) {
                ForEach(AppModel.GameModeBehavior.allCases) { Text($0.label).tag($0) }
            }
            Text("“Tutup otomatis” menutup pilihan ini tanpa bertanya, juga saat game dijalankan dari dalam Steam.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(offer.game == nil ? "Batal" : "Main saja") {
                    model.finishCleanup(offer, closeSelected: false)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(offer.game == nil ? "Tutup yang dipilih" : "Tutup & Main") {
                    model.finishCleanup(offer, closeSelected: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

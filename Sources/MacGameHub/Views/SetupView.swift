import HubCore
import SwiftUI

/// First-run screen: installs Rosetta 2 and the Wine/GPTK engine.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var installingRosetta = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("Selamat datang di MacGameHub")
                    .font(.largeTitle.bold())
                Text("Dua langkah sekali saja sebelum bisa main game Windows di Mac ini.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                step(number: 1,
                     title: "Rosetta 2",
                     detail: "Penerjemah Intel → Apple Silicon dari Apple. Wine membutuhkannya.",
                     done: model.rosettaInstalled) {
                    Button(installingRosetta ? "Menginstal…" : "Instal Rosetta") {
                        installingRosetta = true
                        Task {
                            await model.installRosetta()
                            installingRosetta = false
                        }
                    }
                    .disabled(installingRosetta)
                }

                step(number: 2,
                     title: "Engine Wine \(EngineManager.wineVersion) + D3DMetal",
                     detail: "Wine yang bisa menjalankan Steam versi sekarang, dengan D3DMetal dari Apple (DirectX 11/12 → Metal). Unduhan ±460 MB, ditambah ±230 MB Game Porting Toolkit bila belum ada.",
                     done: model.engine != nil) {
                    if let progress = model.engineProgress {
                        VStack(alignment: .trailing, spacing: 4) {
                            ProgressView(value: progress.fraction)
                                .frame(width: 180)
                            Text(progress.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Unduh & pasang") {
                            Task { await model.installEngine() }
                        }
                    }
                }
            }
            .frame(maxWidth: 620)

            if model.hasLegacyEngine && model.engine == nil {
                Text("Engine lama (GPTK, Wine 7.7) tidak bisa membuka Steam versi sekarang. Pasang engine baru — bottle dan game Anda tetap ada, dan D3DMetal-nya dipakai ulang.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }

            Button("Periksa lagi") { model.refreshEnvironment() }
                .buttonStyle(.link)

            Text("Punya Game Porting Toolkit dari Homebrew (`brew install --cask gcenx/wine/game-porting-toolkit`)? D3DMetal-nya dipakai, jadi tidak diunduh lagi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func step<Action: View>(number: Int, title: String, detail: String, done: Bool,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                if done {
                    Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.headline)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Text("Siap").foregroundStyle(.green)
            } else {
                action()
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

# MacGameHub

Launcher sederhana ala CrossOver/Whisky untuk main game **Windows** di Mac Apple Silicon.
Dibangun di atas **Wine 11 + D3DMetal dari Apple Game Porting Toolkit**:

- Wine: runtime Whisky v4.6.4-beta.1 (wine-11.16) dari [frankea/Whisky](https://github.com/frankea/Whisky),
  dibangun dari [frankea/winecx-gptk](https://github.com/frankea/winecx-gptk) supaya bisa menjalankan D3DMetal.
- D3DMetal: diambil dari [Gcenx/game-porting-toolkit](https://github.com/Gcenx/game-porting-toolkit) 3.0-3
  (sama dengan cask Homebrew). Kalau GPTK sudah ada di Mac, D3DMetal-nya dipakai ulang.

Kenapa bukan Wine bawaan GPTK? GPTK masih memakai Wine 7.7, dan di Wine 7.7 `steamwebhelper` milik Steam
crash setiap ±10 detik sehingga jendela Steam tidak pernah muncul.

## Fitur

- Setup sekali klik: pasang Rosetta 2 dan unduh engine Wine 11 + D3DMetal (±460 MB, +±230 MB GPTK bila belum ada) — tanpa Homebrew.
- **Bottle**: tiap bottle = satu "PC Windows" terpisah (WINEPREFIX sendiri).
- Instal **Steam** / **Epic Games Launcher** langsung dari app, atau jalankan installer `.exe` / `.msi` sendiri (GOG offline installer, dll).
- **Pindai game** otomatis: manifest Steam (`appmanifest_*.acf`), manifest Epic (`*.item`), dan `.exe` di Program Files / GOG Games.
- Grid library dengan cover Steam, tombol Main/Stop, waktu bermain, log per game.
- Pengaturan per bottle: versi Windows, MSync/ESync, AVX (Rosetta), DXR, Retina, Metal HUD, env vars tambahan.
- Alat: winecfg, regedit, command prompt, task manager, buka drive C: di Finder, paksa tutup.

## Kebutuhan

- Mac Apple Silicon, macOS 15 Sequoia atau lebih baru (engine Wine 11 dibangun untuk macOS 15+).
- Xcode 15+ atau Command Line Tools (`xcode-select --install`).

## Build & jalankan

```bash
cd ~/Documents/MacGameHub
chmod +x scripts/build-app.sh
./scripts/build-app.sh            # → build/MacGameHub.app lalu dibuka
./scripts/build-app.sh --install  # → salin juga ke /Applications
```

Atau buka `Package.swift` di Xcode → pilih scheme **MacGameHub** → Run.
Unit test inti (butuh Xcode penuh): `swift test`.

## Alur pemakaian

1. Buka app → **Instal Rosetta** → **Unduh & pasang** engine.
2. **Bottle baru…** → beri nama (mis. "Steam"), pilih "Langsung instal: Steam".
3. Login Steam, instal game seperti biasa.
4. Klik **Pindai game** → game muncul di grid → **Main**.

## Struktur data

```
~/Library/Application Support/MacGameHub/
  library.json       daftar bottle & game
  Engines/Wine/      engine Wine 11 (D3DMetal sudah terpasang di dalamnya, + DXVK)
  Engines/D3DMetal/  salinan D3DMetal dari GPTK (dipakai lagi kalau engine diinstal ulang)
  Bottles/<uuid>/    WINEPREFIX tiap bottle (drive_c di dalamnya)
  Logs/              log per game & per bottle
```

Pengguna versi lama: `Engines/Game Porting Toolkit.app` (engine Wine 7.7) tidak dipakai lagi setelah
engine baru terpasang dan boleh dihapus (±800 MB).

### Steam & D3DMetal

Game memakai D3DMetal. Tampilan Steam/Epic (Chromium) **tidak** bisa memakai D3DMetal (GPU process-nya crash),
jadi proses launcher (`steam.exe`, `steamwebhelper.exe`, `EpicWebHelper.exe`, …) diarahkan ke DXVK lewat
`HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`. Ini dipasang otomatis sekali per bottle
(`LauncherCompatibility.swift`), termasuk untuk bottle lama saat pertama dipakai dengan engine baru.

## Struktur kode

```
Sources/HubCore/         logika murni (Foundation saja)
  Models.swift           Bottle, Game, BottleSettings, LaunchKind
  Paths.swift            lokasi file + konversi path Windows → unix
  LibraryStore.swift     simpan/muat library.json
  EngineManager.swift    unduh/verifikasi/ekstrak engine Wine 11, cek & pasang Rosetta
  D3DMetal.swift         salin D3DMetal dari GPTK & pasang ke dalam Wine
  LauncherCompatibility.swift  DXVK + DllOverrides untuk proses Steam/Epic
  WineRunner.swift       env Wine, argumen peluncuran, wineboot/winecfg/reg, persiapan bottle
  GameScanner.swift      deteksi game Steam/Epic/.exe
  VDF.swift              parser format KeyValues Valve
  Installers.swift       URL installer resmi Steam & Epic
  Shell.swift            menjalankan proses + split argumen
Sources/MacGameHub/      UI SwiftUI
Tests/HubCoreTests/      unit test HubCore
scripts/build-app.sh     menyusun .app bundle
```

Tes integrasi (unduh engine sungguhan ±700 MB, lalu buat bottle):
`MACGAMEHUB_INTEGRATION=1 swift test --filter EngineIntegrationTests`.

### Controller

MacGameHub membaca controller lewat framework GameController macOS dan memberikannya ke game melalui
DLL XInput kecil (`Support/xinput-fix`, ditanam di `XInputFixDLLs.swift`). Jalur HID bawaan Wine dimatikan,
karena setiap laporan controller (ratusan per detik) harus lewat `wineserver` dan membuat game stutter
(terukur: wineserver/winedevice ±55% CPU saat main). MacGameHub harus tetap terbuka selama bermain.
Untuk game lama yang hanya memakai DirectInput, pilih **Controller → Wine HID** di pengaturan bottle.

## Tips kompatibilitas

- Yang paling lancar: game **DirectX 11/12** (lewat D3DMetal). DX9/OpenGL lewat wined3d, biasanya lebih lambat.
- Game dengan **anti-cheat kernel** (Valorant, Fortnite, banyak game online kompetitif) **tidak akan jalan** — ini batasan Wine, bukan app ini.
- Game crash saat dibuka → coba matikan **Advertise AVX**, ganti versi Windows, atau tambahkan argumen `-dx11`.
- Steam tidak muncul → pastikan engine sudah Wine 11 (lihat label "Engine" di bawah sidebar). Kalau layar Steam hitam, coba argumen Steam `-cef-disable-gpu` di Edit game.
- Epic launcher kosong → argumen default `-opengl -SkipBuildPatchPrereq` sudah dipasang; jangan dihapus.
- Cek [AppleGamingWiki](https://www.applegamingwiki.com) untuk status per game.

## Lisensi pihak ketiga

Wine (LGPL, sumber: [frankea/winecx-gptk](https://github.com/frankea/winecx-gptk)), DXVK (zlib) dan
Game Porting Toolkit (lisensi Apple) **diunduh** saat setup dari rilis frankea/Whisky dan Gcenx — tidak
disertakan di repo ini. Penggunaan D3DMetal tunduk pada syarat lisensi Apple Game Porting Toolkit.

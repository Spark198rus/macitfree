# MacItFree

**A free, open-source archive utility for macOS** — open, browse, edit and create archives the Mac way.
MacItFree is a no-cost alternative to paid archivers such as BetterZip: MIT licensed, no trial, no subscription, no telemetry.

It ships as three pieces that share one engine:

| Piece | What it is |
|---|---|
| **MacItFree.app** | SwiftUI app: archive browser, drag-and-drop compress/extract, presets, password vault, Finder Services |
| **`mif`** | Command-line tool for scripts, Shortcuts, Automator, Hazel, Alfred, LaunchBar, Keyboard Maestro … |
| **ArchiveKit** | Swift library (macOS + Linux) that drives `bsdtar`/libarchive, Info-ZIP, 7-Zip and `hdiutil` |

---

## Features

### Open & extract (30+ formats)
ZIP (incl. ZIPX, EPUB, JAR, APK, IPA, CBZ, Office files) · 7z · RAR (v4/v5) · TAR · TAR.GZ/TGZ · TAR.BZ2/TBZ · TAR.XZ/TXZ · TAR.ZST · TAR.LZ4 · TAR.Z · XAR/PKG/XIP · ISO · CPIO · CAB · LHA/LZH · ARJ · DMG/sparseimage · GZ · BZ2 · XZ/LZMA · ZST · BR · LZ4 · Z

- **Split volumes** (`.001`, `.002`, …) are joined transparently and open as one archive
- **winmail.dat (TNEF)** — Outlook’s mystery attachment is decoded natively, long file names included
- **Smart folders** — wraps the output in a folder only when the archive has several top-level items (configurable: smart / always / never)
- **Clutter removal** — `__MACOSX`, `._*` AppleDouble files, `.DS_Store`, `Thumbs.db`, `desktop.ini` never land on your disk
- Never overwrites: existing items get Finder-style names (`report 2.pdf`)
- Format detection by extension **and** magic bytes (a mis-named `.dat` that is really a ZIP still opens)

### Browse without extracting
- Outline view and flat list, sortable columns, instant search
- **Quick Look** any item (⌘Y), **open** it in its app with a double-click
- **Drag items out** to Finder or any app
- **Image viewer** — flip through every picture in an archive or comic book (CBZ/CBR/CB7) with Quick Look’s arrows
- Info panel: format, sizes, compression ratio, methods, encryption, SHA-256 of the archive

### Edit archives in place
- **Add** files (toolbar or drop onto the window), **delete**, **rename**, **new folder**
- **Edit in any app** — open an item, change it, switch back: MacItFree offers to write the change into the archive
- Works for ZIP, 7z, TAR (all compressions), XAR and CPIO; encryption is preserved
- EPUB-safe: `mimetype` is kept first and uncompressed

### Create
ZIP · 7z · TAR.GZ · TAR.BZ2 · TAR.XZ · TAR.ZST · TAR · DMG · XAR · ISO · CPIO · GZ · BZ2 · XZ · ZST · BR · LZ4

- **AES-256 encryption** for ZIP, 7z (optionally hiding file names) and DMG
- Compression level 0 (store) … 9 (maximum)
- **Filters**: strip Mac/Windows clutter, `.git`/`.svn`/`.hg`, `node_modules`/`.build`/`DerivedData`/`__pycache__`, hidden files, custom glob patterns, files over a size limit, by age
- **Split** output into parts (`archive.zip.001`, …) — e.g. 20 MB for e-mail
- **Presets** capture everything (format, level, encryption, filters, split size, destination, what to do afterwards). Nine useful ones are built in.
- **Collect mode** — a basket you fill from different folders over time, then compress in one go

### Security
- **Password vault** in your macOS Keychain; saved passwords are tried automatically when an encrypted archive is opened
- **Password generator** with strength estimate
- **SHA-256 checksums** — compute, copy, and verify against a pasted value (a whole line from a `.sha256` file works)
- Integrity test for any archive

### Integration
- **Finder Services / Quick Actions** (right-click): *Compress with MacItFree*, *Compress (Options…)*, *Extract*, *Extract To…*, *Browse Archive*, *Add to Collect Basket*
- **Dock icon & Finder toolbar button** — drop files to compress, archives to browse or extract (⌘-drag `MacItFree.app` into a Finder window’s toolbar)
- “Open With › MacItFree” for every archive type
- **`mif` CLI** for automation (below)

---

## Install

### Download
Grab `MacItFree.dmg` from the [Releases](../../releases) page (or the latest CI run’s *MacItFree* artifact), open it and drag **MacItFree** to **Applications**.

The build is ad-hoc signed, not notarized. On first launch, right-click the app › **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/MacItFree.app
```

### Build from source
Requires macOS 14 Sonoma or later and Xcode 16 (or the Swift 6 toolchain).

```sh
git clone https://github.com/spark198rus/macitfree.git
cd macitfree
make test          # run the test suite
make install       # builds MacItFree.app → /Applications, links `mif` into /usr/local/bin
```

`scripts/build-app.sh --dmg` produces `build/MacItFree.app` (universal arm64 + x86_64) and `build/MacItFree.dmg`.
For a faster single-architecture build: `ARCHS=$(uname -m) scripts/build-app.sh`.

### Optional helper tools
Everything essential ships with macOS (`bsdtar`/libarchive, Info-ZIP `zip`/`unzip`, `gzip`, `bzip2`, `hdiutil`).
For the extras, install with [Homebrew](https://brew.sh):

```sh
brew install sevenzip xz zstd brotli lz4
```

| Tool | Unlocks |
|---|---|
| `7zz` (sevenzip) | Creating/encrypting **.7z**, encrypted RAR, ARJ, faster ZIP AES-256 |
| `xz`, `zstd`, `brotli`, `lz4` | Single-file `.xz`, `.zst`, `.br`, `.lz4` (TAR variants work without them) |

*Settings › Helper Tools* shows what is installed.

---

## Command line: `mif`

```text
mif list    <archive> [-v]                         List contents
mif extract <archive> [items…] [-d DEST]           Extract everything or selected items
mif create  <output> <files…> [options]            Create (format from extension or -f)
mif add     <archive> <files…> [--to FOLDER]       Add files
mif delete  <archive> <items…>                     Remove items
mif rename  <archive> <item> <new-name>            Rename an item
mif test    <archive>                              Verify integrity
mif info    <archive>                              Format, sizes, encryption
mif hash    <files…> [--verify HEX]                SHA-256
mif join    <file.001> [-o OUTPUT]                 Join split volumes
mif split   <file> <size>                          Split into volumes (100m, 4.7g…)
mif genpass [--length N] [--count N] [--no-symbols]
mif formats                                        Formats + installed helper tools
mif presets                                        Saved presets
```

Examples:

```sh
# Clean ZIP of a project, without .git and node_modules
mif create ~/Desktop/project.zip ~/Code/project --exclude-vcs --exclude-build

# AES-256 encrypted 7z with hidden file names and a generated password
mif create secrets.7z Documents/Taxes --generate-password

# 7-Zip split into 100 MB parts
mif create backup.7z Photos --level 9 --split 100m

# Use a preset from the app
mif create out Folder --preset "Source code"

# Extract only two items, never wrapping in a folder
mif extract archive.tar.gz docs/readme.md src -d ~/Desktop --folder never

# Verify a download
mif hash MacItFree.dmg --verify 3a7bd3e2360a3d…
```

Passwords can be given with `-p`, the `MIF_PASSWORD` environment variable, or interactively (you are prompted when needed).
Exit codes: `0` success, `1` failure, `2` usage error, `3` password required/incorrect.

---

## MacItFree vs. BetterZip

| | MacItFree | BetterZip 6 |
|---|---|---|
| Price | **Free, MIT licensed** | $35 (30-day trial) |
| Source code | Open | Closed |
| Browse / Quick Look / drag out | ✅ | ✅ |
| Edit archives in place, edit in external app | ✅ | ✅ |
| Create ZIP / 7z / TAR.* / DMG / XAR / ISO | ✅ | ✅ |
| RAR creation | ❌ (needs proprietary `rar`) | ✅ via external `rar` |
| AES-256 encryption | ✅ ZIP, 7z, DMG | ✅ |
| Password vault + generator | ✅ (Keychain) | ✅ |
| Presets, filters, clutter removal | ✅ | ✅ |
| Split / join volumes | ✅ | ✅ |
| winmail.dat decoding | ✅ | ✅ |
| Finder integration | ✅ Services / Quick Actions, Dock, toolbar button | ✅ + Finder extension |
| Collect mode | ✅ | ✅ |
| SHA-256 checksums | ✅ | ✅ |
| CLI | ✅ `mif` | ✅ |
| AppleScript / Shortcuts actions | ❌ (use `mif` via “Run Shell Script”) | ✅ |
| Spotlight importer for archive contents | ❌ | ✅ |
| Icon / column views | ❌ (outline + flat list) | ✅ |
| User-defined formats (JSON) | ❌ | ✅ |

The ❌ rows are good first contributions — see *Roadmap*.

---

## How it works

MacItFree doesn’t reinvent compression. **ArchiveKit** drives battle-tested tools and adds the Mac niceties on top:

- **Listing** — ZIP central directories (incl. ZIP64, Unicode paths, CP437 names, per-entry encryption flags) are parsed natively in Swift; other formats via `bsdtar -tv` or `7zz l -slt`.
- **Extraction** always goes into a hidden staging folder next to the destination, then clutter is removed and items are moved into place — so “smart folder”, selective extraction and never-overwrite behave identically for every format.
- **Editing** uses in-place `zip` updates when safe, otherwise extract → modify → re-create → atomic replace, keeping format and encryption.
- **Passwords** go to helpers without a terminal attached, so nothing can hang on a hidden prompt; wrong/missing passwords are detected and surfaced as a prompt.

```
Sources/
  ArchiveKit/     formats, backends (bsdtar, 7-Zip, ZIP, DMG, TNEF, single-file), creator,
                  filters, presets, split/join, SHA-256, password generator
  mif/            the CLI
  MacItFree/      the SwiftUI app (macOS only)
Tests/            unit + end-to-end tests (run on macOS and Linux in CI)
Packaging/        Info.plist (document types, Finder Services)
scripts/          build-app.sh (app bundle + DMG), make-icon.swift
```

## Roadmap
- Finder Sync extension with a proper context-menu submenu (needs an Xcode project for the appex)
- App Intents for Shortcuts
- Icon/column browser views
- Spotlight importer
- JSON-defined custom formats
- Localizations

## Contributing
Bug reports and pull requests are welcome. `swift test` runs everything (tests skip formats whose helper tools aren’t installed).

## License
[MIT](LICENSE). MacItFree is an independent project and is not affiliated with BetterZip or MacItBetter.

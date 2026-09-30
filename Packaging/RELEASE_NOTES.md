**MacItFree** is a free, open-source archive utility for macOS 14 Sonoma and later: open, browse, edit and create archives the Mac way.

## Download
- **MacItFree.dmg** — open it and drag MacItFree to Applications
- **MacItFree.zip** — the same app, zipped
- **SHA256SUMS.txt** — checksums (verify with `shasum -a 256 -c SHA256SUMS.txt`, or `mif hash`)

Universal build (Apple silicon + Intel). The app is ad-hoc signed but **not notarized**, so on first launch right-click it › **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/MacItFree.app
```

## Highlights
- Opens 30+ formats: ZIP, 7z, RAR, TAR (gz/bz2/xz/zst/lz4), XAR/PKG, ISO, CPIO, CAB, LHA, DMG, GZ, BZ2, XZ, ZST, BR, LZ4, split `.001` volumes and Outlook `winmail.dat`
- Creates ZIP, 7z, TAR.*, DMG, XAR, ISO, CPIO and single-file formats, with **AES-256** encryption for ZIP, 7z and DMG
- Archive browser with search, Quick Look, drag-out, and in-place **add / delete / rename / new folder**; edit a file in any app and write it back
- Presets, clutter filters (.DS_Store, __MACOSX, .git, node_modules…), split output, smart extraction folders
- Keychain password vault (tried automatically), password generator, SHA-256 checksum tool, Collect basket
- Finder right-click Services: Compress, Compress (Options…), Extract, Extract To…, Browse, Add to Basket
- `mif` command-line tool inside the app at `MacItFree.app/Contents/Resources/bin/mif` (link it with `ln -s /Applications/MacItFree.app/Contents/Resources/bin/mif /usr/local/bin/mif`)

Optional extras via Homebrew — `brew install sevenzip xz zstd brotli lz4` — add .7z creation, encrypted RAR and more single-file formats. See *Settings › Helper Tools*.

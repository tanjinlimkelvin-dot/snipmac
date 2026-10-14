# SnipMac

A lightweight, native macOS screenshot & pin tool — screenshot, annotate, pin to screen, OCR and scrolling capture. Single Swift file, no dependencies, runs from the menu bar.

一个轻量的 macOS 原生截图 / 贴图工具：截图、标注、贴图、文字识别（OCR）、长截图。

## Features

- **Smart capture** — hover to auto-detect windows, click to select, or drag a custom area; resize with handles, nudge with arrow keys
- **Magnifier & color picker** — pixel coordinates, RGB / HEX; press `C` to copy the color
- **Annotate** — rectangle, ellipse, arrow, pen, highlighter, mosaic, text; 8 colors, 3 sizes, `Shift` to constrain
- **Pin to screen** — floating always-on-top images; drag, scroll to zoom, `⌃/⌥ + scroll` for opacity; pin clipboard images or text
- **OCR** — on-device text recognition (Simplified / Traditional Chinese, English) via Apple Vision, copied to clipboard
- **Scrolling capture** — select a region, scroll slowly, get one long image (sticky headers/footers handled)
- Launch at login, no network access, ~40 MB RAM idle

## Shortcuts

| Action | Keys |
|---|---|
| Capture | `F1` (`fn+F1` on Mac keyboards) or `⌃⌥A` |
| Pin clipboard | `F3` or `⌃⌥P` |
| Copy & finish | `F1` / `Enter` / double-click / `⌘C` |
| Save | `⌘S` |
| Pin selection | `F3` / `⌘T` |
| OCR | `O` |
| Scrolling capture | `L` |
| Tools | `R` rect · `E` ellipse · `A` arrow · `P` pen · `M` highlighter · `B` mosaic · `T` text · `1/2/3` size |
| Undo | `⌘Z` |
| Clear selection / quit | right-click / `Esc` |

Hover any toolbar button to see what it does.

## Build & install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This compiles `Sources/main.swift`, generates the app icon, signs the app and installs it to `/Applications/SnipMac.app`.

On first launch, allow SnipMac in **System Settings › Privacy & Security › Screen & System Audio Recording**, then relaunch it.

### Keeping the permission across rebuilds (optional)

Ad-hoc signed apps lose the Screen Recording permission on every rebuild. If a code-signing identity named `SnipMac Local Signing` exists in your keychain, `build.sh` uses it so the permission sticks. To create one:

```bash
cat > /tmp/snip.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = SnipMac Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/snip.key -out /tmp/snip.crt -days 3650 -config /tmp/snip.cnf
openssl pkcs12 -export -inkey /tmp/snip.key -in /tmp/snip.crt -out /tmp/snip.p12 -passout pass:snipmac -name "SnipMac Local Signing"
security import /tmp/snip.p12 -k ~/Library/Keychains/login.keychain-db -P snipmac -T /usr/bin/codesign
rm /tmp/snip.key /tmp/snip.crt /tmp/snip.p12 /tmp/snip.cnf
```

## Notes

- Global hotkeys use Carbon `RegisterEventHotKey`, so no Accessibility permission is needed.
- Captures use ScreenCaptureKit; only the screen under the mouse is captured.
- The app icon is rendered at build time from the SF Symbols "scissors" glyph — replace `make_icon.swift` with your own artwork before distributing binaries.
- Debug log: `~/Library/Logs/SnipMac.log`.

## License

MIT

# Toolkit

A personal macOS app I built to add small features I wished my Mac had. I open-sourced it in case any of these are useful to you too.

It's a single app that bundles a handful of independent features — each can be toggled on or off from Settings.

## Features

### System Health
A small menu-bar dot that reflects current memory pressure (green / amber / red). Click it to see circular rings for CPU, memory, disk, battery, and swap usage. Reads metrics locally from macOS APIs — no accessibility permission needed.

### Text Expander
Type a shortcut followed by a space and it expands to the full text in any app. Shortcuts are case-sensitive. Manage shortcuts from Settings.

### Rewritely
Type a trigger word at the end of any text field and Apple Intelligence rewrites the text in place. Each trigger has its own custom prompt (use `{{text}}` to position the input). Useful for fixing typos, tightening grammar, or any rewrite you do often. Can also be invoked via a keyboard shortcut.

### Quick Notes & Tasks
A two-pane todo + notebook panel that opens when you flick the cursor into the bottom-right corner of the screen. Flick again to dismiss. No accessibility permission needed — it uses cursor position only.

### Media Controls
Shows current playback controls at the top center of the display. On Macs with a notch, hover the top-center area to open a compact now-playing panel with artwork plus previous, play or pause, and next controls. On Macs without a notch, the controls appear inline in the menu bar instead. For long-form media, previous and next switch to 10-second seek controls.

### App Windows (Dock Hover)
Hover an app icon in the Dock to peek at that app's open windows by title. Configurable hover delay. For VS Code, you can also configure a list of favorite folders to show in the popup instead — tap a row to open the folder directly. Right-click an icon to suppress the popup for that app until you move away.

## Requirements

- macOS (built with Xcode / SwiftUI)
- Some features (Text Expander, Rewritely, App Windows) require Accessibility permission. The app will prompt for it and there's a master switch in Settings.
- Rewritely requires Apple Intelligence to be enabled.

## Building

Open `Toolkit.xcodeproj` in Xcode and run.

## License

MIT — see [LICENSE](LICENSE).

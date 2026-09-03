# CoffeeBar

A minimal macOS menu bar item hider. It does one thing: tuck away the menu bar icons you rarely use.

Same principle as Bartender / Ice: an oversized separator `NSStatusItem` pushes everything to its left off screen. Only the Accessibility permission is needed; no screen recording.

[中文说明](README.md)

## Usage

Download the latest `CoffeeBar-x.y.z.zip` from [Releases](https://github.com/zjywill/coffeebar/releases), unzip, drag into Applications. Signed with a Developer ID and notarized. Updates arrive via Sparkle (right-click `<` → Check for Updates…).

- A `<` button appears at the right of the menu bar. On first launch everything to its left is hidden.
- **Click `<`**: a panel drops down listing hidden items by app icon. Clicking one moves *that single item* next to `<`, clicks it, and moves it back once its menu or window is gone. Other hidden items never move, so a narrow or notched display is fine.
- **Search**: with the panel open, just type to filter by app name, ← → to select, Enter to open, Esc to close.
- **Hide / show an item**: ⌘-drag it to the left of `<` to hide, to the right to keep it visible; CoffeeBar remembers. For bulk changes right-click `<` → Arrange Items… (or ⌥-click): all hidden items expand and stay expanded until you click `<` (shown as ✓).
- **New apps stay visible** by default so you know they exist; drag them away to hide.
- **Layout memory**: each app's side is remembered; after a restart drifted items are moved back. Manual ⌘-drags are recorded as intent, not reverted.
- **System items** (battery, Wi-Fi, Control Center, Spotlight, input menu) are never left hidden.
- **Panel only on built-in display**: optional; on external displays `<` expands inline instead.

## Building

```bash
ARCHS=arm64 ./scripts/make-app.sh   # local build for the native arch
open build/CoffeeBar.app
```

Run the bundled app, not the bare binary: TCC permissions are granted per app bundle. `scripts/release.sh --publish` builds a universal binary, notarizes, generates the Sparkle appcast and publishes a GitHub Release.

## Requirements

macOS 14+. Developed and verified on macOS 26. See [issue #1](https://github.com/zjywill/coffeebar/issues/1) for the macOS 27 situation.

## License

AGPL-3.0, see [LICENSE](LICENSE).

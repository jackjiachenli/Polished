# Polished

A suite of macOS utilities that fix the small things Windows switchers miss.

**Requires macOS 26.5 or later.**

Polished lives in the menu bar. Enable modules from the menu or **Settings…**, grant the permissions each module needs, and quit/reopen Polished after changing privacy settings.

## Modules

- **App Quitter** — quits apps when their last window closes (red X)
- **Window Snapper** — drag windows to screen edges and corners to snap
- **Window Switcher** — hold-to-cycle window overlay (default ⌥Tab)
- **Clipboard History** — rolling clipboard history with global hotkey (default ⌘⇧V)
- **Finder Enhancements** — Explorer-like cut-to-move in Finder (⌘X / ⌘V)

Built with Swift and AppKit. Licensed under the [MIT License](LICENSE).

## Requirements

- macOS 26.5 or later (see `MACOSX_DEPLOYMENT_TARGET` in the Xcode project)
- Xcode 26 or later to build from source

## Install

### Download (recommended)

Download **Polished.dmg** from [GitHub Releases](https://github.com/jackjiachenli/Polished/releases/latest), open it, and drag **Polished** to Applications.

Because v1.0 builds are not notarized, macOS Gatekeeper may block the first launch:

1. Right-click **Polished** in Applications → **Open**, then confirm, **or**
2. System Settings → Privacy & Security → allow Polished to open

### Build from source

```bash
git clone https://github.com/jackjiachenli/Polished.git
cd Polished
xcodebuild -scheme Polished -configuration Release -derivedDataPath .derivedData build
open .derivedData/Build/Products/Release/Polished.app
```

Or open `Polished.xcodeproj` in Xcode, select the **Polished** scheme, and press **⌘R**.

### Create a release DMG locally

```bash
./scripts/build-dmg.sh
```

Output: `dist/Polished.dmg`

## Permissions

| Permission | Required for |
|------------|----------------|
| **Accessibility** | All modules (window inspection, simulated paste, app quit detection) |
| **Input Monitoring** | Window Switcher, Finder Cut (global keyboard / event taps) |
| **Automation** (Finder) | Finder Cut paste destination in some setups |

Check status in **Settings → Permissions**. After changing permissions in System Settings, **quit and reopen Polished**.

## Known limitations

- **App Quitter** works well on native macOS apps and many Chromium apps (e.g. Google Chrome). Some Electron apps (e.g. Discord, Steam) may not quit reliably when the last window closes. Contributions welcome.
- **Window Switcher** and **Finder Cut** need Input Monitoring; if the overlay or ⌘X shortcut does nothing, enable it under Privacy & Security → Input Monitoring.
- Unsigned release builds require the Gatekeeper steps above until a signed/notarized build is published.

## Acknowledgments

- **Window Snapper** — snap area detection and frame math adapted from [Rectangle](https://github.com/rxhanson/Rectangle) (MIT), which is based on Spectacle. See [NOTICE](NOTICE).

## Project layout

```
Polished/
├── App/           App entry point and delegate
├── Core/          Shared infrastructure used across modules
├── Modules/       One folder per feature module
├── UI/            Settings and shared SwiftUI views
```

- **`Core/`** — cross-module utilities (module protocol, hotkeys, pasteboard helpers, permissions).
- **`Modules/<Name>/`** — self-contained feature modules. Multi-feature modules may use `Features/` for sub-features and `Shared/` for helpers used only within that module (not app-wide `Core/` code).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

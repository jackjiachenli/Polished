# Polished

A suite of macOS utilities that fix the small things Windows switchers miss.

## Modules

- **App Quitter** — quits apps when their last window closes
- **Window Snapper** — drag windows to screen edges and corners to snap
- **Clipboard History** — clipboard history with global hotkey (default ⌘⇧V)
- **Finder Enhancements** — Explorer-like improvements for Finder (cut to move files)

Built with Swift and AppKit. Requires Accessibility permission. Free and open source.

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

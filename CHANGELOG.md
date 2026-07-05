# Changelog

All notable changes to Polished are documented in this file.

## [1.0.0] - 2026-07-05

First public release.

### Added

- **App Quitter** — quit regular apps when their last visible window closes
- **Window Snapper** — edge and corner snap when dragging windows (Rectangle-derived logic)
- **Window Switcher** — hold-to-cycle overlay with MRU ordering and clickable window cards
- **Clipboard History** — text, image, and file URL history with configurable hotkey and persistence
- **Finder Enhancements** — cut-to-move files with ⌘X / ⌘V
- Menu bar toggles and Settings window for module configuration
- **Launch at Login** — start Polished automatically at sign-in (Settings → General; install to Applications)
- Accessibility permission prompt and status in Settings

### Known issues

- Requires macOS 26.5 or later
- App Quitter may not quit some Electron apps (Discord, Steam)
- Release builds are signed with Automatic code signing; Developer ID + notarization not yet set up for public distribution

[1.0.0]: https://github.com/jackjiachenli/Polished/releases/tag/v1.0.0

# Release smoke-test checklist

Run before tagging a release.

## Build

- [ ] `xcodebuild -scheme Polished -configuration Debug build` succeeds
- [ ] `./scripts/build-dmg.sh` produces `dist/Polished.dmg`
- [ ] `hdiutil verify dist/Polished.dmg` passes

## Permissions (Settings)

- [ ] Accessibility status reflects System Settings
- [ ] Input Monitoring status reflects System Settings
- [ ] Automation (Finder) status reflects System Settings (may show Not granted until Finder Cut triggers the prompt)
- [ ] Deep links open the correct Privacy panes

## Modules (enable → exercise → disable)

- [ ] **App Quitter** — close last window on a native app; Chrome if available
- [ ] **Window Snapper** — drag window to edge/corner snap
- [ ] **Window Switcher** — hold hotkey, cycle, click card or release to confirm
- [ ] **Clipboard History** — copy text, open picker, paste into another app
- [ ] **Finder Cut** — ⌘X files, ⌘V in another folder (move)

## Persistence

- [ ] Enabled modules and settings survive quit/relaunch

## Install from DMG

- [ ] Drag to Applications, launch (Gatekeeper override if unsigned)

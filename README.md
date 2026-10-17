# Leap

A fast ⌘Tab replacement for macOS with Vimium-style hint keys.

- **⌘Tab** opens the switcher; keep ⌘ held. **Tab / ⇧Tab** cycle, **releasing ⌘** switches (just like native).
- **Hint keys** jump straight to an app: the 16 right-hand keys at the QWERTY positions
  `7 8 9 0 / U I O P / J K L ; / M , . /`. Labels come from your **active keyboard layout**
  (Colemak-DH shows `7 8 9 0 / L U Y ; / N E I O / H , . /`).
- The grid sizes itself to the number of apps (`ceil(n/4)` rows) and mirrors the physical keys.
  Most recent app gets the home-row index finger; the current app goes last. Over 16 apps → two-key hints.
- **Space** toggles Icons ⇄ Window Previews (remembered). **Arrows** move, **Return** switches,
  **Esc** cancels, **Q** quits the selected app. Clicking a cell works too.
- Switching to an app whose windows are all minimized restores one; an app with no windows gets reopened (like a Dock click).

## Build

```sh
./build.sh            # build/Leap.app
./build.sh --install  # copy to /Applications and launch
swift test            # grid/hint logic tests
```

No paid developer account needed. The build signs with your free "Apple Development" certificate
so macOS keeps permissions across rebuilds (falls back to ad-hoc signing, which re-prompts every build).

## Permissions

- **Accessibility** (required): intercepts ⌘Tab and activates apps.
- **Screen Recording** (previews mode only): window thumbnails.

The native switcher is disabled while Leap runs and restored when it quits.

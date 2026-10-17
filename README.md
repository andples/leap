# Leap

A fast ⌘Tab replacement for macOS with Vimium-style hint keys.

- **⌘Tab** opens the switcher; keep ⌘ held. **Tab / ⇧Tab** cycle, **releasing ⌘** switches (just like native).
- **Hint keys** jump straight to an app: the 16 right-hand keys at the QWERTY positions
  `7 8 9 0 / U I O P / J K L ; / M , . /`. Labels come from your **active keyboard layout**
  (Colemak-DH shows `7 8 9 0 / L U Y ; / N E I O / H , . /`).
- **Keep jumping**: while ⌘ is held, each hint tap (or click) switches straight to that app and the switcher
  stays open, so you can hop between several apps in one go. Releasing ⌘ closes it.
- The grid sizes itself to the number of apps (`ceil(n/4)` rows) and mirrors the physical keys.
  Most recent app gets the home-row index finger; the current app goes last. Over 16 apps → two-key hints.
- **Space** toggles Icons ⇄ Window Previews (remembered). **Arrows** move, **Return** switches,
  **Esc** cancels, **Q** quits the selected app (the switcher stays open and re-renders). Clicking a cell works too.
- **Order**: the home row holds your most recent or most used apps (Settings). Everything else is
  alphabetical so those keys stay put. Tab goes left to right: home row, then top, then bottom.
- **Hold a hint key** to peek: a larger window preview pops up and the app stays selected; **Q** while holding quits it. A tap still switches (on key release; turn hold-to-preview off in Settings to switch on key press).
- **Mouse**: moving the pointer over the switcher highlights apps (release ⌘ to switch); clicking switches.
- **Drag and drop**: drag a file, press ⌘Tab, and hover it over an app for half a second to switch to it
  and keep dragging into its window, or drop it on the app to open it there (like the Dock).
- A quick ⌘Tab always lands on your previous app, so flicking swaps between your last two apps.
- **Finder** only shows up when it has a window open (toggle in Settings).
- **Settings… (⌘,)** in the menu bar: theme, size, background opacity, corner radius, app names,
  hint badge position/size/color, selection color, show delay. Changes preview live.
- Switching to an app whose windows are all minimized restores one; an app with no windows gets reopened (like a Dock click).

## Build

```sh
./build.sh            # build/Leap.app (universal: Apple silicon + Intel, macOS 14+)
./build.sh --install  # copy to /Applications and launch
swift test            # grid/hint logic tests
```

No paid developer account needed. The build signs with your free "Apple Development" certificate
so macOS keeps permissions across rebuilds (falls back to ad-hoc signing, which re-prompts every build).

## Permissions

- **Accessibility** (required): intercepts ⌘Tab and activates apps.
- **Screen Recording** (previews mode only): window thumbnails.

The native switcher is disabled while Leap runs and restored when it quits or crashes. While
Secure Input is on (password fields, Terminal's Secure Keyboard Entry) apps can't see keystrokes,
so Leap hands ⌘Tab back to macOS until it's off. If Leap is force-quit (which can't be intercepted),
open and quit it once, or log out, to get the native ⌘Tab back.

## Privacy

Everything stays on your Mac. Keystrokes are never logged or stored: the event tap only looks for
⌘Tab and, while the switcher is open, the keys you press in it. Leap remembers settings and how
often you switch to each app (by bundle ID) in its preferences. With Screen Recording granted,
window thumbnails are captured for previews/hold-to-peek and kept in memory only.

## Speed

The event tap runs on its own thread and decides pass/swallow from a tiny locked state, so nothing
on the main thread can delay your typing. Icons are pre-rendered, the panel is reused, nothing animates,
and window captures happen in the background.

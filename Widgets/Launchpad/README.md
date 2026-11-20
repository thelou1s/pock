# Launchpad (Pock widget)

A [Pock](https://pock.app) widget that puts **Launchpad** on the Touch Bar as a
single button: tap the grid icon and Launchpad opens, exactly as it does from the
Dock.

## The icon

The button shows the nine tiles Launchpad is made of, as the
`square.grid.3x3.fill` symbol in flat white (`contentTintColor`), which is the
same treatment the system monitor items use, so the whole bar keeps one style.
The app's own icon was tried first — `NSWorkspace.icon(forFile:)` gives exactly
what the Dock draws — but its light plate reads as grey on the dark Touch Bar
and looks out of place next to the other items.

`PKButton` draws its rounded bezel all the time, which is a background that
never goes away, so the button is created with `isBordered = false` and the
highlight is a separate view behind the glyph, hidden until the item is pressed
or pointed at.

## Matching the neighbours

The only backgrounds on this bar belong to the Dock widget, so the plate copies
its recipe instead of guessing at one. From `pock/dock-widget`
(`Dock/Sources/DockItemView.swift`, `Dock/Sources/Constants.swift`):

| | Dock widget | this item |
| --- | --- | --- |
| tile | `dockItemSize` = 40 × 30 pt | 40 × 30 pt |
| background view | `frontmostView`, `edgesToSuperview()` — the whole tile | the whole cell |
| corner radius | `dockItemCornerRadius` = 6 | 6 |
| colour | `NSColor.darkGray`, opaque (`set(isFrontmost:)` swaps it for `clear`) | `NSColor.darkGray`, opaque |
| icon | 24 × 24 (`dockItemIconSize`, `hideRunningIndicator` off) | 19 pt symbol, which lays out as 24 × 21 |

The icon's bottom edge lands 5 pt above the bottom of the cell in both, so the
two sit on the same line.

Two things worth knowing about that recipe:

- The plate the neighbours show is **not a pressed highlight** — it marks the
  frontmost app (`didUpdateActiveItem` → `set(isFrontmost: activated)`), and it
  stays up. Their mouse-over is something else entirely: a white `NSShadow`
  (blur 5, offset −2.35) on the icon, no background at all. This item uses the
  plate for both pressing and pointing, because a white shadow on a white glyph
  is barely visible.
- Colour was never the problem. `NSColor.darkGray` is `rgb(67, 67, 67)`, and the
  translucent white tried earlier (`white: 1, alpha: 0.28`) composites to about
  `rgb(71, 71, 71)` on the black bar — the same tone. What made the neighbours
  read as a bigger, brighter block was the footprint: 40 × 30 filling the tile
  against 26 × 24 hugging the glyph. Pock's palette grey `rgb(45, 41, 44)` is a
  different matter and really is invisible on the bar, since the panel it was
  picked for is already grey.

The item is 10 pt wider than it was, which is the price of the same footprint.

## Pressing it

Both ways of pressing work, and they arrive through different doors:

- A **finger on the bar** is recognised by an `NSPressGestureRecognizer` on the
  button, with `allowedTouchTypes = .direct` and `minimumPressDuration = 0`.
  A press gesture reports every state change, so the plate comes up on `.began`
  — while the finger is still down — and Launchpad opens on `.ended`;
  `.cancelled` and `.failed` only take the plate away.
  This is the mechanism the shipped Dock widget uses (its binary contains
  `_didTriggerPressGestureRecognizer:` alongside `setHighlighted:`).
  `PKButton`'s own click gesture is removed: it is reported only once the finger
  has lifted, which is too late for a highlight, and answering both would open
  Launchpad twice — which toggles the grid shut again.
- **Mouse support** (`mouseSupportEnabled`, Pock's preferences) does not send
  events to any view: `PKScreenEdgeController` watches a 10 pt strip along the
  bottom edge of the screen and reports what happens there to the *widgets*
  that conform to `PKScreenEdgeMouseDelegate` — the Dock widget is notified the
  same way. Without that conformance a button simply never learns it was
  clicked, which is why the widget implements the four delegate methods. Since
  only the click is reported, never a press and a release, a mouse click flashes
  the plate for 0.2 s; pointing at the item holds the plate up the whole time.

Only the horizontal position is compared when deciding whether a mouse event
belongs to this item: the strip is 10 pt tall while the bar is 30 pt, so the
reported `y` says nothing about the item.

## How it opens Launchpad

The button asks the workspace to open `/System/Applications/Launchpad.app`. That
bundle is a launcher (`LSUIElement`, `com.apple.launchpad.launcher`) which hands
the grid over to the system, so pressing again while Launchpad is already open
toggles the grid away rather than starting a second copy.

No special privileges are involved: opening an app is a plain workspace call, so
the widget needs neither Accessibility nor Screen Recording permission, and it
does not send synthetic key events.

## Build & install

```bash
cd Widgets/Launchpad
make install
```

The widget is one Swift file that needs nothing but PockKit, so it is compiled
directly with `swiftc` instead of through an Xcode project. `make` therefore
needs PockKit's Swift interface, which it takes from the SystemMonitor widget's
Release build (`../SystemMonitor/build/Build/Products/Release/PockKit`); build
that once first, or point `POCKKIT_DIR` somewhere else:

```bash
make POCKKIT_DIR=/path/containing/PockKit.framework
```

## Position on the Touch Bar

Pock does not decide the order of its items: macOS persists it, in Pock's own
defaults, under the key `NSTouchBarConfig: PockTouchBarController` as the array
`CurrentItems` (bundle identifiers, left to right). To keep this button at the
far left, put `com.luis.pock.Launchpad` first in that array and restart Pock:

```bash
killall Pock
defaults write com.pigigaldi.pock "NSTouchBarConfig: PockTouchBarController" \
	'{CurrentItems = ("com.luis.pock.Launchpad", "com.pigigaldi.pock.Dock", "com.luis.pock.SystemMonitor"); DefaultItems = ();}'
open -a Pock
```

## Project layout

```
Widgets/Launchpad/
├── Makefile
└── Launchpad/
    ├── Info.plist
    └── Sources/
        └── LaunchpadWidget.swift             # PKWidget entry point
```

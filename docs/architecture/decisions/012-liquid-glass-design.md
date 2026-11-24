---
audience: all
owner: Malashkin
updated: 2026-11-24
---

# 012. Liquid Glass look built from NSVisualEffectView and layers

**Status:** Accepted (2026-11-24)

## Context
The app moved to a "Liquid Glass" design: the desktop shows through the window, content sits on translucent
panels with a light edge, and controls are capsules. macOS 26 has a native glass API (`NSGlassEffectView`), but the
app supports macOS 13+ and is built with the Command Line Tools, whose SDK (14.4 on the build Mac) doesn't have it.

## Decision
- The window is borderless-looking (transparent title bar, hidden title, full-size content) over one behind-window
  `NSVisualEffectView` (`.fullScreenUI`), so the blurred desktop shows through the whole window.
- Panels, cards and capsules are plain layer-backed views (`GlassView`, `CapsuleButton`, `CapsuleSegments`) with a
  translucent white fill and a light edge. The colors are dynamic (`Glass.fill`, `Glass.raised`, `Glass.edge`) and are
  resolved for the view's appearance (`cg(_:)`), so Light and Dark mode both work.
- Floating panels (recording pill, cards) clip their behind-window blur with a stretchable `maskImage`;
  `layer.cornerRadius` does not clip that blur.
- Colors come from one palette, `Brick`: blue #006CB7, yellow #FFCD03, green #00A650, orange #F57D20, with darker/lighter text variants for Light/Dark mode. There is no red: destructive actions and overdue dates are orange. Window buttons and system alerts keep their system colors.
- Native controls stay where they work well (pop-up menus inside a glass capsule, checkboxes, settings).

## Consequences
- One look on macOS 13–26, no new SDK needed. When the build moves to the macOS 26 SDK, `GlassView` can switch to
  `NSGlassEffectView` behind an availability check without touching the pages.
- "Reduce transparency" makes `NSVisualEffectView` opaque by itself; the white fills stay readable on it.
- Off-screen renders (`--demo-window`, README screenshots) can't capture the blurred desktop, so they draw the glass
  over a sample wallpaper.

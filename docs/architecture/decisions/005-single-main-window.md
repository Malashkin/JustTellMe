---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# 005. One main window

**Status:** Accepted (2026-11-10)

## Context
Clicking the app icon only showed a permissions/welcome window. History, statistics and the dictionary were separate
windows reachable only from the menu-bar menu, so the user couldn't find the history. Wispr Flow has one window with
the feed on its home page.

## Decision
One `MainWindow` (split view, sidebar) with four pages: Главная (status, quick stats, feed), Статистика, Словарь and
Настройки. It opens on reopen (Finder, Launchpad, Dock) and from the menu. The app switches to `.regular` activation
while the window is open (Dock icon, ⌘Tab) and back to `.accessory` when it closes. Permission problems are
shown on the home page.

## Consequences
- Everything is in one place. The menu-bar «Настройки» submenu stays for quick access and duplicates the Settings page.
- The fix-and-remember dialog (`CorrectionWindow`) stays a separate small window.

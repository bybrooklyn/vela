# ADR-0002: Native macOS, Not Catalyst or Electron

**Status:** Accepted

Use SwiftUI for composition and AppKit where desktop behavior/performance requires
it. Do not make Catalyst or Electron the application shell. This keeps lifecycle,
menus, keyboard navigation, accessibility, windows, drag-and-drop, and system
integration native.

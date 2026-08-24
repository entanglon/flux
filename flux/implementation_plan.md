# Sidebar Restoration & Selection Polish Plan

We will revert the "Carousel Mirror" and sidebar transparency changes to restore your UI's integrity, while keeping the full-width selection indicator fix that you liked.

## User Review Required

> [!IMPORTANT]
> **No Mirror / No Transparency**: We are completely removing the carousel mirror and sidebar background modifications. The sidebar will return to its original appearance.

> [!IMPORTANT]
> **Preserved Fix**: The **sidebar selection indicator** will remain full-width (spanning the sidebar) as requested.

## Proposed Changes

### 1. UI Restoration

#### [MODIFY] [ContentView.swift](file:///Users/zainulnazir/Projects/flux/flux/ContentView.swift)
- **Remove Mirror**: Delete the `AsyncImage` background logic from the `NavigationSplitView`.
- **Restore Sidebar Background**: Remove any manual background overrides to allow the system `List` material to take over again.
- **Maintain Selection**: Keep the current `sidebarRow` implementation that uses `HStack` and `Spacer` for edge-to-edge row hits.

### 2. Top Bar Fidelity

#### [MODIFY] [ContentView.swift](file:///Users/zainulnazir/Projects/flux/flux/ContentView.swift)
- Ensure the window toolbar background is set to `.hidden` to attempt the transparency you requested, but we will simplify the layering to avoid "something behind it" artifacts.

## Verification Plan

### Automated Tests
- Build verification via `xcodebuild`.

### Manual Verification
- **Sidebar Check**: Verify the sidebar is no longer transparent and has no blurred image behind it.
- **Selection Check**: Confirm selection indicators still span the full width of the sidebar.
- **Top Bar Check**: Confirm window controls are visible and the title bar area is as clean as possible.

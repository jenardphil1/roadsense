# UI Consolidation: Single-Button Route Switching

This plan outlines the removal of the bottom route cards and the consolidation of all routing choices (Fastest, Alternative, and Optimized) into a single, high-efficiency toggle button on the right side of the screen.

## User Review Required

> [!IMPORTANT]
> **Cycle Interaction**: With the cards gone, you will switch between routes by tapping the **Optimize button** on the right. Each tap will cycle to the next available road (e.g., Road 1 -> Road 2 -> Smart Optimized Route).
> **Visibility**: The current route's travel time and pothole count will be displayed in the **Top Navigation Banner** and on the **Button's Badge**, ensuring you still have all the critical info without the screen being cluttered.

## Proposed Changes

### UI & Logic Consolidation

#### [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)

- **Remove Route Cards**:
    - [DELETE] The `Positioned` widget containing the horizontal `ListView` of route cards.
    - [MODIFY] Adjust the vertical positioning of the right-side buttons to stay consistently near the bottom since the cards are removed.

- **Unified Switcher Logic**:
    - Update `_smartOptimizeRoute()` to act as a **Route Cycle** controller:
        1. If no Optimized route exists yet, first-click performs the "Big Scan" and adds the "Safe Route" to the list.
        2. Subsequent clicks cycle through the available paths: `(selectedIndex + 1) % totalRoutes`.
    - Automatically update the map polyline and the top banner on every click.

- **Button Design**:
    - The button will show a small counter of which route you are on (e.g., "1/3") or just the pothole count for the current view.

---

## Open Questions

- **Cycling Order**: When you click the button, do you want it to always prioritize the "Safest" route first, or should it just step through all options in order?

## Verification Plan

### Manual Verification
- Search for a destination.
- Verify that **NO cards** appear at the bottom.
- Click the right-side button to cycle through the standard routes.
- Verify that the map path changes and the pothole count updates on the button.
- Verify that optimization still works and becomes one of the choices in the cycle.

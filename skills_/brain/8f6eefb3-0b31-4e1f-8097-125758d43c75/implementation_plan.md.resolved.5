# Implementation Plan - Standard Navigation Mode

Following industry standards (Google Maps/Waze), I will implement the most robust navigation experience for drivers.

## Proposed Decisions (Based on Standards)

1. **Rotation Source**: I will use **GPS Heading (Course)** instead of the compass. This is the standard for driving apps because it aligns the map with the road you are traveling on, regardless of how the phone is tilted in the car mount.
2. **Smooth Animations**: I will use a `MapController` with an animation loop (or the `flutter_map_animations` logic) to ensure the map moves smoothly, not in jumps.
3. **UI/UX Lifecycle**:
    - **Active**: Map stays centered and rotates with your car.
    - **User-Interruption**: If you drag the map, "Follow Mode" automatically pauses (Google Maps behavior).
    - **Re-center Button**: A new floating button will appear to bring you back into Navigation Mode.

## Proposed Changes

### Logic & State

#### [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)
* **New Variables**:
    * `bool _isFollowing = false;` (Navigation Mode status)
    * `double _currentRotation = 0.0;`
* **Navigation Stream**:
    * Start a separate location listener that triggers camera moves only when `_isFollowing` is true.
* **Auto-Pause**:
    * Add a `onMapEvent` listener to `MapOptions`. If an event like `MapEventMoveStart` is triggered by a human, set `_isFollowing = false`.

### UI

#### [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)
* **Navigation Button**: 
    * Add a modern "Explore/Navigate" button on the map.
    * When inactive: Icon is an open compass.
    * When active: Icon is a blue navigation arrow.

## Verification Plan

### Manual Verification
* **Smooth Movement**: Use mock GPS to "drive" a route; verify the map pans and rotates without stuttering.
* **Manual Override**: Drag the map with a finger while navigating; verify the follow mode stops automatically.
* **Re-centering**: Press the nav button and verify it snaps back to your location and begins following again.

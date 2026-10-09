# Goal Description
Implement a "Start Navigation" flow and restrict pothole warnings to only those that lie along the active navigation route. The "Next Pothole" info bar will strictly show the distance to the next pothole on the route that is *outside* the current 50m proximity zone.

## User Review Required
- Is a 30-meter radius around the route line acceptable for determining if a pothole is "on the route"?
- When a user is NOT actively routing to a destination, should we show nearest potholes everywhere, or disable the banner until they start navigating? (Plan assumes: show everywhere if not routing, restrict to route if routing).

## Proposed Changes

### [MODIFY] `map_screen.dart`

1. **State additions:**
   - Add `bool _isNavigatingRun = false;` to track if the user clicked Start.
   - Add `List<LatLng> _potholesOnRoute = [];` to cache potholes relevant to the current trip.

2. **Route Generation (`_fetchRoute`):**
   - After fetching `_routePoints`, iterate over `_allPotholeLocations`. Keep those that are within ~30m of any `_routePoints`. Store in `_potholesOnRoute`.
   - Set `_isNavigatingRun = false;` to show the preview state. The Follow mapping shouldn't hijack the camera until they click "Start".

3. **UI Updates (Start Button):**
   - Above the search bar (or bottom center), if `_destination != null` and `!_isNavigatingRun`, show a prominent massive "START" FloatingActionButton (like Google Maps).
   - If they press "Start":
     - Set `_isNavigatingRun = true`.
     - Force `_followMode = FollowMode.location`.
     - Call `_toggleFollowMode()` (or `_startFollowing()`).

4. **Proximity Check (`_checkPotholeProximity`):**
   - If `_isNavigatingRun == true`, use `_potholesOnRoute` instead of `_allPotholeLocations`.
   - Ensure the logic for "closest pothole outside 50m" correctly ignores the one currently triggering the red 50m alert (This is already functioning correctly, but we will ensure it prioritizes the route's direction).

## Open Questions
- Do you want the distance to the next pothole to be the *driving distance along the blue line*, or is *straight-line distance* (as the crow flies) fine? (Straight line is computationally much faster for mobile).

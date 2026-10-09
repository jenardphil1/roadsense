# Integrate OpenStreetMap & Pothole Tracking

This plan outlines the steps to add an interactive OpenStreetMap to the app, allowing users to view a map, their current location, and automatically plot detected potholes based on AI results.

## Proposed Changes

We will introduce a bottom navigation bar to switch between the Pothole Scanner and the new Map interface smoothly, and establish a cross-file data flow to share GPS markers.

### 1. Add Dependencies
Add three essential packages to `pubspec.yaml`:
- **`flutter_map`**: The core package for rendering OpenStreetMap tiles.
- **`latlong2`**: Required for handling Latitude/Longitude map coordinates.
- **`geolocator`**: To request GPS permissions and locate the user when plotting a pothole.

### 2. Architecture Updates (lib/main.dart)
Modify `main.dart` to support multiple screens natively without clutter:
- Add a top-level `List<LatLng> detectedPotholes` to store logged potholes.
- Wrap the main scaffold body in an `IndexedStack` to preserve the states of the camera and map when switching.
- Add a `BottomNavigationBar` with icons for "Camera" and "Map".
- Update the AI plotting logic: When `_detectPotholeOnStatic` or `_detectRealtimeFrame` triggers a picture with a >0 detection count, use `Geolocator` to fetch the phone's current coordinates and save it to the list.

### 3. Implement MapScreen Widget (lib/map_screen.dart)
Create a clean, isolated file for the map:
- Accept `List<LatLng> detectedPotholes` as a parameter.
- Render a `FlutterMap` widget using the `<https://tile.openstreetmap.org/{z}/{x}/{y}.png>` tile server.
- Render a `MarkerLayer` to draw a red icon at every plotted coordinate in `detectedPotholes`.
- Request user location and pan visually using a map controller.

### 4. Native Permissions (Android)
Update `android/app/src/main/AndroidManifest.xml` to include:
- `android.permission.ACCESS_FINE_LOCATION`
- `android.permission.ACCESS_COARSE_LOCATION`

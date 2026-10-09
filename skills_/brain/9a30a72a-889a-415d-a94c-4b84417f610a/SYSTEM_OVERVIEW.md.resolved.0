# Pothole Detection & Smart Navigation System: Hand-over Documentation

This document provides a comprehensive overview of the Flutter application built to detect potholes and navigate users through "smooth" optimized routes.

## 📱 System Purpose
The application is a pro-active driving assistant that:
1.  **Detects** potholes in real-time using a mobile camera and YOLOv8 TFLite model.
2.  **Maps** these potholes globally and stores them in a local SQLite database.
3.  **Navigates** users to a destination while calculating the total potholes on every available route.
4.  **Optimizes** trips by requesting routes that explicitly avoid dense pothole clusters ("Smart Optimize").

---

## 🏗️ Core Architecture

### 1. Primary Files
- **map_screen.dart**: The heart of the app. Handles map rendering, routing logic, proximity alerts, and the Master Control UI.
- **database_helper.dart**: Manages the local SQLite storage for detected potholes.
- **main.dart**: App entry point and overall navigation structure.

### 2. External Services & APIs
- **OpenRouteService (ORS)**: 
  - Used for `driving-car` profiles.
  - **Customization**: Uses the `avoid_polygons` parameter in POST requests to steer the route away from potholes.
- **Nominatim (OpenStreetMap)**:
  - Used for the search bar suggestions with proximity bias toward the user's current GPS location.
- **OpenStreetMap Tiles**: Standard tile provider for `flutter_map`.

---

## 🌟 Key Features & Implementation Logic

### A. "One-Button" Master Routing
Instead of complex menus, the user interacts with a single **Master Control Button** on the right side:
- **Cycling Logic**: Tapping the button cycles between `Road 1`, `Road 2`, and `Smart Route`. 
- **Dynamic Feedback**: The button displays the travel time, road label, and pothole count for the active choice.
- **Caching**: Standard and Optimized routes are cached in `_cachedStandardRoute` and `_cachedOptimizedRoute` to allow instant switching.

### B. Regional Smart Optimization ("Big Scan")
When the user clicks "Optimize", the app performs a **Regional Scan**:
1.  **Clustering**: Identified potholes within the trip bounding box are grouped into clusters (100m radius).
2.  **Exclusion Zones**: Clusters of **3+ potholes** are converted into GeoJSON `MultiPolygon` objects.
3.  **Avoiding**: These polygons are sent to ORS, which returns a route that detours around the "minefields".

### C. Proximity Alerts (The Banner)
A Top Green/Red Banner provides a heads-up:
- **Distance Calculation**: The app projects the user onto the route and calculates the distance to the next upcoming pothole marker.
- **Multi-Modal Alert**: When within 50m, the app triggers **Text-to-Speech (TTS)** and a visual red flashing circle on the map.
- **Dynamic Update**: Every time the route is cycled or optimized, the distance is recalculated instantly.

---

## 🛠️ Technical Details for Future AI

### State Variables (`_MapScreenState`)
- `_alternativeRoutes`: List of all path points (Fastest first).
- `_potholesOnRoute`: Pre-filtered list of potholes that literally lie on the current path.
- `_isOptimizedActive`: Boolean flag toggling the UI between "Safe Mode" and "Standard Mode".
- `_nearestPotholeInfo`: String displayed in the top banner.

### Critical Methods
- `_getAvoidancePolygons()`: Generates the GeoJSON for ORS.
- `_checkPotholeProximity()`: The logic loop for distance calculation.
- `_smartOptimizeRoute()`: Handles the cycling and re-routing API calls.

### UI Styling Tokens
- **Master Button**: `FloatingActionButton.extended`.
- **Nav Pill**: Glassmorphic-inspired container at the top for distance info.
- **Proximity Circle**: `CircleLayer` that turns red and thickens when a hazard is near.

---

## 🚀 Future Roadmap Suggestions
- **Cloud Sync**: Syncing the local SQL database to a central server (e.g., Azure or Firebase) so all users see each other's detections.
- **Offline Maps**: Caching OSM tiles for areas with poor connectivity.
- **Directional Audio**: Using TTS to say "Pothole on the left/right" based on GPS heading.

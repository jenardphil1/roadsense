# Azure Maps Integration Plan

Migrate the search, routing, and map visualization components to Azure Maps to leverage better performance and professional styling.

## User Review Required

> [!IMPORTANT]
> **API Key Required**: To proceed, I will need your **Azure Maps Primary Key** (found in the Azure Portal under your Azure Maps account > Authentication).
> **Geographic Focus**: I will default the search bias to the **Philippines (PH)** as the current app coordinates suggest this is the primary area of operation.

## Proposed Changes

### 1. Centralized Configuration [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)
- Replace individual API keys for OpenRouteService with a single `_azureMapsKey`.
- Define the base URLs for Azure Maps services.

### 2. Search & Geocoding Migration [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)
- **Function**: `_fetchSuggestions`
- **Change**: Replace Nominatim (OSM) endpoint with Azure Maps Fuzzy Search.
- **Benefit**: Faster results, better relevance, and support for "Points of Interest" (POIs).

### 3. Professional Routing migration [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)
- **Function**: `_calculateRoute` and `_searchAndRoute`
- **Change**: Replace OpenRouteService (ORS) and OSRM with Azure Maps Route Direction API.
- **Benefit**: More accurate driving paths and better handling of destination geocoding in a single ecosystem.

### 4. Tile Layer Upgrade [MODIFY] [map_screen.dart](file:///c:/ssdd/flutter/lib/map_screen.dart)
- **Widget**: `TileLayer`
- **Change**: Update `urlTemplate` to load tiles from Azure Maps instead of OpenStreetMap.
- **Benefit**: Cleaner, more "premium" look and feel for the map.

---

## Open Questions

1. Do you already have the **Azure Maps Primary Key**? If not, I can guide you on where to find it in the portal.
2. Should I keep the current "Philippines only" filter for search results, or would you like it to be global?

## Verification Plan

### Automated Tests
- Run `flutter analyze` to ensure no syntax errors in the new HTTP requests.

### Manual Verification
1. Open the search bar and type a local landmark (e.g., "SM North EDSA"). Verify suggestions appear instantly.
2. Select a destination and confirm the blue route line draws correctly using Azure Maps data.
3. Observe the map tiles to ensure the Azure "Road" style is active and loading correctly.

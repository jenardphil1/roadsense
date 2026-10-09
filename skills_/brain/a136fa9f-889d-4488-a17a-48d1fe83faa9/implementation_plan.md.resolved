# Pothole Tracker - Implementation Plan

## Goal Description
Build a visual-first, mobile-optimized web application that allows users to view and report potholes on a map. The app will use the device's geolocation to center the map and allow users to pin pothole locations.

## User Review Required
> [!IMPORTANT]
> **Why Web App (PWA) vs Flutter?**
> The user requested the "best if free" option.
> - **Flutter**: Great for native performance but requires **$25 (Google) / $99 (Apple)** developer fees to publish to stores. Installing via APK is difficult for casual users.
> - **Web App (PWA)**: **100% Free**. Works instantly in the browser. Users can "Add to Home Screen" to install it like a real app. No app store approval needed.
>
> **Decision**: We will build specific PWA features (manifest, icons) so it feels native.

## Proposed Changes

### Technology Stack
- **Framework**: Next.js (React)
- **PWA**: `next-pwa` or manual manifest injection for installability.
- **Styling**: Vanilla CSS (CSS Modules for components) - *Focusing on premium, glassmorphism aesthetics*
- **Map Engine**: Leaflet (via `react-leaflet`) with OpenStreetMap tiles (Free, no API key required for demo)

### Project Structure
#### [NEW] `pothole-tracker/`
- `app/` - Next.js App Router
    - `page.js` - Main map view
    - `layout.js` - Root layout with meta tags for mobile optimization
    - `globals.css` - Global variables, resets, and typography
- `components/`
    - `Map/`
        - `Map.js` - The interactive map component (client-side only)
        - `Map.module.css`
    - `UI/`
        - `FloatingButton.js` - Main action button
        - `ReportModal.js` - Form to add details

### Key Features
1. **Interactive Map**: Full-screen map interface.
2. **Geolocation**: Auto-center on user's location.
3. **Reporting**: Tap to add a marker, or use a central "+" button to mark current location.
4. **Visuals**: Dark mode capability, smooth animations, "Glass" UI elements for controls.

## Verification Plan

### Automated Tests
- Build verification via `npm run build`.

### Manual Verification
- **Browser Testing**: Use Browser Subagent to simulate mobile viewport (375x812).
- **Functionality Check**:
    1. Load app -> Check if map loads.
    2. Click "+" button -> Verify marker appears.
    3. Click marker -> Verify info popup.

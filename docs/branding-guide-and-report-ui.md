# Branding, mobile guides and report UI

The current branding derives from the user's `Downloads/icon.jpg` and
`Downloads/full logo.jpg`. Runtime artwork is in `assets/branding/`.
`full_logo.png` contains the supplied wordmark with its pale background.
`icon.png` is a PNG with transparent background and transparent negative space.
The app and web share `RoadSenseBrand`; the mobile `RoadSenseLogo` API remains
available to existing screens. Launcher and browser assets were regenerated.
iOS launcher and web maskable variants retain an opaque platform background.

The transparent icon was edited with the built-in imagegen tool. Prompt:

> Edit the supplied RoadSense R icon only: remove the entire pale white/gray
> photographic background and white/gray negative space within the R. Preserve
> the exact silhouette, proportions, deep navy road ribbon, cyan-to-teal center
> stripe and teal circular dot. The hole in the upper bowl around the dot must be
> transparent too. No redesign, no added text, no shadows or glow, no checkerboard
> baked into pixels. Clean antialiased edges, centered square icon with small
> padding. Output PNG with genuine alpha transparency.

Mobile Help now opens a section picker instead of resetting every tour or
discarding the reviewed photo. Map, scanner, reports, profile and photo review
guides use real widget anchors. Existing completion preferences are retained.
Section replay is explicit; Back, Next and Skip remain available.

Severity controls, badges, report-note inputs and report-note displays have been
removed from the principal mobile, user web and admin views. Class, confidence,
approval status, location and report count remain visible. Report and barangay
CSV exports omit severity columns. Editing no longer rewrites the hidden legacy
severity or note fields. The storage schema and historical records are retained;
structured moderation/rejection reasons are separate from report comments.

The marker design follows the earlier mobile app: round surface-backed pins
with class-colored glyphs and outlines. Both map screens use `RoadHazardMarker`
for individual and expanded-cluster markers. Web shield pins and their additional
sonar wrapper were removed. A regression test renders all four classes in both
real map widgets and checks each individual marker's glyph, circular shape and
class-colored border. Severity filters and labels remain removed.

Validation: 50 focused mobile, web, admin, report-sync, route and forecast widget
tests plus the four-class individual-pin regression pass (51 total). Analysis of changed app entry points and screens has no errors or
warnings. App-icon and favicon corner alpha values were checked as zero.

The final APK was installed with `adb install -r`, preserving app data. Local and
device SHA-256 matched `ff2838636f8ce36e00b2ec0662c7786a444dfa93196efda157864e7956fd127f`.
The phone's My Reports page showed six pending reports without severity labels;
the new Help section picker opened. USB disconnected before spotlight-step
interaction could be checked. Full physical verification of every guide remains
outstanding. The rebuilt web app is served locally at `http://127.0.0.1:8080`.
Its authentication page was inspected in headless Edge. Hosted production was
not published.

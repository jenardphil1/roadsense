# Implementation prompt (copy into a new agent session)

```text
ROLE
Senior Flutter engineer. Work inside C:\Users\jenar\ssdd\flutter (existing app, Android + Flutter Web).
Reference doc: docs/google_maps_thesis_report.md — read it first; it contains the observed
Google Maps patterns, measured numbers, and policy rules this spec derives from.

MISSION
Align the existing DPWH Road Distress Detection System codebase to the report spec:
map-first screen, 5-class categorical markers with clustering, offline capture +
idempotent sync, GPS accuracy metadata, dashboard. Non-destructive: read every file
you touch before editing; keep existing patterns; do not delete features without a
written reason in the PR text.

HARD CONSTRAINTS — DO NOT VIOLATE
1. Exactly 5 model classes. Verify the exported TFLite model's class mapping before
   wiring labels; dataset IDs may differ from deployed IDs:
     0 = Pothole (DPWH 01)          1 = Alligator crack (02)
     2 = Longitudinal crack (12)    3 = Transverse crack (12)
     4 = Edge break (01)
   Class 5 "Depression" (Code 05) is EXCLUDED: never shown, never filterable, never legend.
2. NO severity classification anywhere — no severity labels, colors, chips, or filters.
   The three numbers stay separate and separate-labeled: model confidence ≠ GPS
   accuracy_m ≠ anything physical-severity.
3. Zero-budget: only free tiers / self-host. No paid APIs for core flows.
4. Legal/policy:
   - OSM tiles (tile.openstreetmap.org): visible attribution bottom-right, correct UA
     from Dart http clients, NO tile prefetch/offline packs, respect HTTP cache headers.
   - Geocoding via backend proxy only; Nominatim submit-triggered (never autocomplete,
     never client-direct), 1 req/s cap, cached responses. Optional Photon for
     suggestions, also proxied. Never call from the device directly.
   - No Google assets/icons/branding in the UI.

STACK (audit the repo; align to these)
- Map renderer: flutter_map 8.x + MapController (raster tiles)
- Clustering: flutter_map_supercluster (default below zoom 15; tap = zoom to spread)
- State: flutter_riverpod 2.x with select()/family granularity; map widgets const-friendly
- Local DB: Drift (SQLite; Web via sqlite3 WASM). One detections table:
  id (UUID v4, also sync idempotency key), classId, confidence, lat, lng, accuracy_m,
  capturedAt, note, imagePath, thumbPath, remote_id (nullable), pendingSync,
  gps_pending (bool), deletedAt/tombstone
- GPS: geolocator, one-shot getCurrentPosition(LocationAccuracy.high, timeLimit 15 s)
  per capture; store Position.accuracy → accuracy_m. No continuous watch except
  explicit follow-mode.
- Inference: Android = tflite_flutter 0.12.1 in a background Isolate, model from
  assets, preprocess 640x640, NMS, multiple detections per image, identical output
  schema on both platforms: {classId, confidence, bbox, imageRef, capturedAt, lat,
  lng, accuracyM}. Web = post image to backend endpoint (FastAPI + ultralytics on the
  sync backend); show "Model starting…" cold-start state. Keep tflite strictly no-op on web.
- Sync: batched upsert-by-UUID, tombstones for deletes, ≤10 records or ≤5 MB per
  batch, on connectivity_plus restore + workmanager (Android only) periodic retry;
  clear pendingSync per record after ACK.
- Tiles/geocoder/backend URLs live in one AppConfig file; runtime switchable (no
  hard-coded tile URL).
- Audit existing Firebase usage (cloud_service.dart, firebase_options.dart): either
  keep it as the sync backend if already working, or migrate to Supabase/FastAPI —
  pick one, write the decision in the delivery notes; don't run both.

MAP SCREEN SPEC (map owns the screen — logicFanStack floor: map visible ≥ 60%)
1. Search bar (44dp pill, top-left): 3 modes — (a) local defect search (Drift
   LIKE on road/note, instant, works offline); (b) place search (submit-triggered,
   proxied geocoding; debounced 400 ms if suggestions enabled via Photon); (c) filters.
2. Control stack (bottom-right): Capture FAB (primary, 56dp) → my-location (40dp,
   3 states: ready / denied = muted + "Cannot access your location"-style chip with
   open-settings tap / searching = pulse; long-press follow-mode) → zoom buttons.
3. Markers: CustomPainter glyphs per class, circle 30dp, 1.5dp white border,
   Okabe-Ito colors — Pothole #D55E00, Alligator #56B4E9, Longitudinal #009E73,
   Transverse #F0E442 (dark border), Edge #CC79A7. Shape differs per class; color
   never the only signal; legend chips + semantic labels for a11y. Cluster badge =
   neutral navy, never a class color. No Image/Image-decode inside any marker
   widget; thumbnails (96px) only in detail sheet, LRU-cached.
4. Detail bottom sheet (mobile) / side panel (web ≥ 900dp, collapsible edge-tab):
   thumb, class name + confidence %, capture timestamp, lat/lng + "±X m" accuracy
   chip (green ≤8 / amber 9–20 / red >20 with "Move for better signal"), sync state
   badge, note, actions locate/delete. Never place confidence next to accuracy as
   if comparable.
5. Filters: 5 class toggles (legend colors, with counts), date presets
   (24 h/7 d/30 d/all), "Pending sync" toggle; changes re-run viewport query, no
   full-screen rebuild.
6. Data flow: markers from viewport-bounded Drift query
   (lat/lng BETWEEN bbox, filters, LIMIT 500) refreshed on MapEvent.moveEnd only.
7. Offline/sync banner top-of-map: "N changes pending · will sync" / "Syncing…" /
   "Offline — saved on device"; capture NEVER blocked while offline; records saved
   locally first with gps_pending flag when accuracy unacceptable.
8. Scale attribution row bottom-right: "© OpenStreetMap contributors" + "Report a
   map issue" link (https://www.openstreetmap.org/fixthemap). Scale-bar chip bottom.
9. Web only: encode camera to URL (history.replaceState on idle 300 ms:
   ?c=lat,lng,z&f=id), parse on boot. Android ignores.
10. Dashboard: separate page from left-rail hamburger / analytics chip — never an
    overlay on the map. Class counts, 14-day trend, accuracy distribution, sync health.

CAPTURE FLOW
FAB → camera → single-shot GPS (accuracy chip live, if >20 m show amber/red hint,
still allow) → inference (isolate on Android / backend on Web) → review sheet:
per-detection chips [Class 90%] multi-select, must show a class-name mapping notice
if ids remapped → confirm → Drift insert (UUID) → "1 saved · will sync" → back to
map in < 1 s. Capture-to-review target ≤ 2.5 s on mid-range Android.

PERFORMANCE RULES (enforce; measure, don't guess)
- Viewport-bounded query + LIMIT 500; clustering below z15.
- Rebuilds: Riverpod select per chip; MarkerLayer rebuilds only on cluster/query change.
- Inference never on UI thread; image decode only in its isolate.
- Search debounce ≥ 400 ms; zero network before idle.
- Log/Profile: DevTools frame times (target p99 build <16 ms pan), Memory plateau,
  Network tile-only growth. Update docs/rea-evidence checklist numbers when you
  re-measure in-app.

TESTS TO ADD (integration_test; pass criteria from report §13)
T4 capture round-trip ≤2.5 s, classes ∈ {0,1,2,3,4} only
T5 accuracy_m stored = Position.accuracy
T6 offline capture 5 → reconnect → exactly 5 on server (no dupes)
T7 airplanet mid-sync 3× → no dupes, no losses
T9 geocoder rate limit: ≤1 rps to Nominatim, zero during typing
T12 markers distinguishable by glyph not color; semantic labels present
T10 attribution visible at 360/600/1000dp

WORK ORDER (each = one PR-sized chunk, verify before next)
P1: audit pubspec + class mapping + DB schema (align file names, add missing cols)
P2: map screen alignment (controls, markers, clustering, viewport query, filters)
P3: detail sheet/panel + image thumbs + LRU cache
P4: capture flow (camera, GPS one-shot, inference isolate, review, multi-detection)
P5: sync service (UUID batch, tombstones, banner, connectivity/watchmanager)
P6: search (local mode + proxied place mode) + legend + scale bar
P7: dashboard page + URL-camera for web
P8: tests + performance pass + attribution/a11y audit

DEFINITION OF DONE
- flutter analyze clean; flutter test green; integration tests T4–T12 pass or
  skipped with written reason
- No class-5 leak, no severity concept, confidence/accuracy separated (grep-audit:
  finding for words severity|medium|low/high priority in UI strings)
- Offline airplane capture → sync runs with zero duplicates (manual demo script in
  docs/runbook.md, 10 steps max)
- Attribution + report-issue link visible all layouts; UA set in tile/geo clients
- README section (10 lines): stack, provider policies honored, how to switch
  tile/geocoder/backend providers at runtime

RULES OF ENGAGEMENT
- Ask before adding any new dependency; justify vs existing package.
- Ask before replacing Firebase or schema migrations.
- No placeholder/stub code committed as "done"; unfinished items get TODO with
  trigger condition.
- Every PR: 1-line summary + test result + files touched.
```

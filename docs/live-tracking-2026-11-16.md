# Mobile live detection consistency

## Subsequent appearance change requested by the user

The user requested the normal scanner appearance after this investigation:
boxes and class/confidence labels on the main camera view, with no numbered IDs,
tracking counter, status badge or analyzed-photo inset. `main.dart` now renders
the latest confirmed detections directly; held snapshots are retained for paired
capture but are not projected onto the camera view. The inset component and its
dedicated widget test were removed. The 21 remaining focused tests pass.
Spatial association, class hysteresis, expiry and exact photo/result capture
pairing remain unchanged. This UI uses the most recent inference, not optical
flow tracking of every preview frame; boxes can lag camera motion between results.
The sections below record the earlier inset-based evaluation, not the restored UI.

The restored build exposed a native reply/busy-guard race: Dart's immediate
same-photo retry received a bare list instead of a mapped response. The native
worker now releases resources and its guard before replying, and returns a typed
DETECTOR_BUSY error for overlapping requests. The corrected profile APK was
installed with `adb install -r` (data preserved); device and local SHA-256 matched
`64ab20093b0662e4379406df656991599a7262d99e535f562432df97703cf9fb`.
On-device verification recorded 30 consecutive empty-scene full/detail cycles
from 09:04:37 to 09:05:19 with no inference errors. The normal UI was inspected;
this empty-scene check does not validate moving-target accuracy or box alignment.
The scanner was closed and the scoped log collector stopped afterward.
Mobile analysis has 13 informational diagnostics, no errors/warnings. Required
web analysis reports 66 issues in the independently edited web source; no web
files were changed for this restoration.

The source baseline was built and installed before editing. The installed APK
SHA-256 matched `572c9fbb5820e90750068a5e5ffec21e499d8e7336ff977546a46a7efb550501`.
On the TECNO LH7n it produced 56 logged cycles, median 844 ms, three empty
results/center retries. The user identified the target as a photo on a screen;
the screenshot shows multiple photographs and screen moire. This is not a
real-road accuracy or walking benchmark. Initial GPU compilation took 66.4 s.

The baseline already checked the full image every cycle and retried a center
crop of the same JPEG when empty. Remaining source issues were whole-list
replacement, confidence-order-dependent widget identity, immediate class changes,
and drawing delayed photo coordinates over the newer camera preview.

## Correction

- `live_detection_snapshot.dart`: greedy highest-IoU, one-to-one association,
  with an IoU gate of 0.30. This tolerates modest box displacement while refusing
  disjoint boxes; it is not optical flow or motion prediction. Nearby observations
  remain separate assignments. Identity is stable across result ordering changes.
- A class change needs three consecutive matched observations of the new class.
  A miss or return to the established class resets the streak. Conflicting
  predictions are withheld from the saved analyzed result, never relabeled or
  given an invented probability. No global confidence threshold was lowered.
- One missed analyzed frame is tolerated. Tracks expire on two missed frames or
  four seconds since their source photo, whichever comes first. Photos expire
  after three seconds independently. The extra second for identity was added
  after a device observation: one missed full/detail cycle plus processing the
  recovery frame could exceed three seconds and unnecessarily assign a new ID.
  A regression test covers that case without extending old-photo lifetime. Per-track
  expiry also works while other defects remain detected. Slow/out-of-order
  results cannot renew stale tracks. Changing image dimensions resets matching.
- `analyzed_frame_preview.dart`: continuously running camera preview remains
  unobstructed by delayed boxes. A labeled analyzed-photo inset shows boxes only
  on their source JPEG. Its aspect ratio matches source dimensions, coordinates
  change atomically without interpolation, and boxes wait for image decoding.
  It does not claim to track pixels on the live video between inference samples.
- `main.dart`: stable tracking count/status, independent expiry timers, source
  capture timestamps, and diagnostic tracking/capture logs. Saving a scan keeps
  the copied JPEG/results pair even if another inference finishes concurrently.
  Existing fresh/manual capture, permissions, report handling, native GPU model,
  full/detail strategy and serial inference scheduling remain in place.

## Verification

22 focused tests passed: original model/letterbox/snapshot checks plus movement,
confidence misses, class jitter/reclassification, nearby objects, individual
disappearance, timer expiry, stale/out-of-order results, resolution change,
capture pairing and atomic image/box rendering. Analysis found no errors or
warnings, with 23 existing informational diagnostics across mobile and required
web files. Web UI files were not edited by this work; concurrent changes in
web_main.dart and web_map_screen.dart were observed and preserved.

First tracking-build device evaluation (before the four-second identity change):
- Installed APK hash matched `18726e90f95aa8d8aab85b2af9bf66cb5a9fe9f57a36326c39ec54de77713249`.
- 08:37:00–08:37:25 steady screen-photo window: 25 cycles, median 960 ms, no empty
  results, both IDs 1 and 2 retained throughout. The live preview and correctly
  aligned analyzed-photo inset were visually checked.
- 08:37:25–08:38:00 movement window: 30 cycles, median 984 ms, four empty results.
  IDs were lost/reacquired during larger image displacements and detector misses;
  this was not a full movement-stability pass. It exposed the recovery timeout
  corrected above. Other objects entered/left view, so count changes alone are
  not an accuracy score.
- 08:39:30–08:39:53 away window: 14 cycles, all empty with zero active tracks and
  no analyzed-photo inset. Median 1634 ms because empty scenes run both passes.
- First GPU compilation took 70.1 s after installation. No repeated model loading
  during those windows. Baseline versus updated timing is not a controlled speed
  comparison: scene, thermal state and rendering workload differed.

Final build installed at 08:43:28 with app data preserved. Installed APK SHA-256
matched `ae5de0bab6ae4902438cff83d06be73530a1dab5f26ee08190d3a4200339ba76`.
- 84 logged cycles from 08:45:12.778 to 08:46:46.784: median combined capture and
  processing 1034.5 ms (processing 581 ms, capture 448 ms), three empty results.
- The requested steady/gentle-movement sequence was performed against a screen
  collage, with user completion acknowledged. The view changed substantially
  and smaller predictions appeared/disappeared. In 08:45:20–08:46:00, 34 cycles
  had three empty results and active counts ranged 0–14; this is NOT a successful
  claim of uniform movement stability. Main pothole IDs 30 and 31 both persisted
  across all 13 cycles in 08:45:46–08:46:00 despite smaller prediction changes.
- Saving the frame opened Capture Review with eight detections, matching the
  immediately preceding analyzed result. The saved JPEG was 720 x 1280 upright;
  capture log records source timestamp 08:46:45.740598 and age 1274 ms. Review
  showed Saved locally / Not submitted. No report submission was invoked.
- Stopping the scanner for review canceled an already-started still capture;
  the old callback logged `Camera is closed`. Its stale epoch prevented it from
  replacing the review or presenting an error. This was a capture-stop
  cancellation, not a camera restart or inference failure while scanning.
- First GPU setup after this reinstall took 71.0 s; model setup was not repeated
  within the run. Scanner was left stopped in review and log collectors ended.

Artifacts are under ignored `.dart_tool/tracking-*`: build hashes, scoped logs,
phase timestamps, tests/analysis and screen/photo captures. The camera checks
establish frame pairing and bounded behavior on these screen scenes, not field
accuracy. Model output still varies with screen moire, changing scale/view and
scene content; temporal association cannot recover a defect the model stops
recognizing for longer than the configured limits.
Fast pans, crossing/occlusion of similar objects, large scale changes and detector
misclassification can still break spatial association. Real-road walking remains
unverified until tested on actual road surfaces.

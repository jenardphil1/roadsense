# Live detection and capture consistency

Live scanning alternates full-frame and center-detail inference. Previously each empty pass immediately removed the overlay, and Capture analyzed a new photo with only the full-frame pass. A visible detail-pass detection could disappear on capture.

- Retain the matching JPEG, dimensions and detections through one missed pass, for at most three seconds after the successful result. A second miss or expiry clears it. Held results display `RECENT DETECTION`.
- Capture saves that exact retained image and its detections for review. It never attaches those boxes to a newly captured image. The confirmation explicitly says the detected scan frame was saved.
- With no retained result, capture a fresh photo. Photo analysis now uses both native full-frame and detail passes, merging overlapping same-class detections without boosting confidence.
- Serialize capture taps and skip live timer ticks during capture. Existing four-class filtering and confidence thresholds remain unchanged.

Verification:

- Eleven tests passed across `live_detection_snapshot_test.dart`, `model_alignment_test.dart`, and `letterbox_test.dart`, covering image/result association, copying, missed passes, expiry, coordinate mapping and class-aware merging.
- Mobile analyzer: no errors; existing style diagnostics remain. Android debug APK built and installed with app data preserved.
- On the connected TECNO LH7n at 23:43, live scanning detected a longitudinal crack shown on a monitor. Tapping Capture opened REVIEW with one longitudinal crack at 48% confidence and the saved-frame confirmation. Screenshot retained locally in ignored `.dart_tool/capture-fixed-review.png`. No report was submitted. This checks the capture workflow, not field accuracy.
- Required web analysis found separate current errors in `web_map_screen.dart`: missing search helpers and a truncated expression around lines 12677–12678. This mobile change does not edit those web files.

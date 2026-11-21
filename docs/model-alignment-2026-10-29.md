# Package 6 model alignment — 2026-10-29

Mobile, web, and admin share the supported class definitions while retaining independent screens.

| Model slot | Supported class | DPWH code |
| --- | --- | --- |
| 0 | Pothole | 01 |
| 1 | Alligator crack | 02 |
| 3 | Longitudinal crack | 12 |
| 4 | Transverse crack | 12 |

Both bundled TFLite files have input `[1, 896, 896, 3]` and output `[1, 9, 16464]`. The five output labels must stay in their original order: slot 2 is the untrained depression class. Package 6 metadata and test metrics identify four trained classes. Dropping the fifth label or renumbering slots would corrupt inference mapping.

## Behavior

- Load only compatible Package 6 FP32/FP16 models; validate the complete label order.
- Discard depression, edge break, unknown labels, malformed boxes, and detections below the configured confidence (default 0.25).
- Preserve model probabilities and class identity; remove heuristic relabeling and confidence boosts.
- Clear stale results when inference returns no supported detections; prevent empty detections from becoming fabricated pothole reports.
- Use distinct class names/IDs for the two Code 12 orientations in admin filters and editing. Reclassification preserves severity.
- Store canonical class ID/name/code on new reports. Mark inference provenance only when detections are supplied.
- Keep historical depression/edge-break records readable, separate from the four trained-class totals. Reports containing only Code 12 remain orientation unspecified.
- Show Package 6 macro metrics rather than older model statistics. The reported 640px T4 speed benchmark is explicitly distinguished from the bundled model's 896px input.
- Capture the admin notification messenger before saving, so a filtered-out row does not cause a deactivated-context exception.

## Verification

- `flutter test`: 36 tests passed, including six model alignment regressions.
- `node test/firebase_workflows.cjs`: 17 local Firebase workflow checks passed.
- `node test/model_alignment_browser.cjs`: local Emulator Suite checks for four-class creation, unsupported/mismatched-class rejection, admin filters and Code 12 reclassification; machine-readable results in `model-alignment-results.json`, screenshot in `model-alignment-admin.png`.
- Android debug APK and JavaScript web builds succeed.
- Required web analysis has no errors; 14 existing informational diagnostics remain (logging, deprecated APIs, async context guidance).

Tests use `demo-roadsense-qa`, not production accounts or data. This pass does not establish physical-camera detection accuracy, production Azure uploads, or live email/OAuth delivery. Website hosting and Firestore rules have not been deployed; the APK must be installed to use the mobile changes.

# Scanner camera lifecycle correction

Azure uploads were confirmed working by the user with USB disconnected. This correction concerns CameraX `Not bound to a valid Camera`, not upload or model accuracy.

Changes in lib/main.dart: invalidate startup when the app loses foreground (including while initializing); retain and await asynchronous camera disposal before reopening; keep the initialized controller local and reject stale startup epochs; guard camera capture readiness; allow one camera-unbound recovery per scanner session after frame cleanup; display a camera-specific Retry message when recovery is exhausted. Detection thresholds and photo/result pairing are preserved.

Verification: 20 existing detection buffer/tracking/upload-queue tests pass. Main and mandatory web analysis has existing informational lints only. Release built with the dedicated public Azure upload define, installed with adb install -r preserving data, installed hash verified: 51f7b358f8750edb85779ce92ed01de937794a6a79b75a2d9e145ed374d1f17d. Downloads/RoadSense-latest.apk updated.

TECNO LH7n manual ADB checks: live startup, background/resume then reopen, interrupt startup with Home after 100 ms then resume/reopen. Six completed processing cycles across the checks, zero camera-unbound/live errors in process-scoped Flutter logs. The auto-recovery branch was not fault-injected. No reports submitted. Returned to map to stop the test scanner. First model initialization measured 57461 ms; slow initial model loading remains separate from this lifecycle error.

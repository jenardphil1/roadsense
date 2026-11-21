# Live scanner optimization

- Fixed tensor shape signatures in a separate FP32 asset; weights/operators are unchanged. All output tensors matched the original exactly on six bundled annotated sample images. This establishes export parity, not field accuracy.
- Confirmed on TECNO LH7n: GPU delegated 271 of 273 operators. Original dynamic signatures caused GPU rejection. FP16 CPU fallback was slower and was not retained as the preferred runtime.
- Initialize, invoke, and close the GPU interpreter on one worker in a licensed local flutter_vision fork; retain original FP32 CPU fallback with four threads.
- Android live inference decodes JPEG and orientation once, pads to 896px directly in native code, and maps boxes to original dimensions. Removes Dart image decoding/PNG encoding from live scans.
- Alternate full-frame and centered detail passes to preserve thin-crack detail without increasing per-frame inference count. Keep the four classes and 25% threshold; no confidence boosts or orientation relabeling.
- Skip timer ticks during inference, reject results from stopped sessions, serialize model/scanner startup, and preserve scanning when Capture is retried while busy.

Observed a longitudinal crack at confidence 0.462 on the connected phone during testing. A longitudinal crack follows the road direction; its screen orientation alone does not establish the class. Photos of monitors and the small bundled sample set are not sufficient to measure recall or false positives.

Eight focused detection tests passed. Mobile and required web analysis have no errors (existing diagnostics remain). Shared admin component API mismatches encountered during concurrent edits were repaired to allow the Android build.

Final installed build, 23:34 on the connected TECNO: observed processing cycles of 729–904ms after camera capture (capture time excluded from this timer); result timestamps about 1.3–1.5s apart. Longitudinal detections included 0.6367 and 0.5049 on a center-detail pass and 0.5313 / 0.4456 on the following full-frame pass. No live inference exception occurred during this check. These are short-session observations, not guaranteed FPS or accuracy; scene, temperature, hardware and camera capture latency affect performance.

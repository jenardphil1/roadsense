# Mobile map rendering investigation ? 2026-11-17

Device: TECNO LH7n, USB. Stationary map interaction, not driving.

## Evidence

Flutter profile build, same APK, renderer selected through the Android launch argument. Three repeated sequences of zoom in, zoom out and pan. Dart VM timeline `GPURasterizer::Draw` spans:

| Renderer/sample | Completed spans | Median ms | P95 ms | Maximum ms |
|---|---:|---:|---:|---:|
| Impeller GLES | 16 | 135.71 | 876.81 | 921.38 |
| Skia | 274 | 8.42 | 15.44 | 604.19 |
| Skia repeated | 260 | 9.33 | 17.52 | 80.83 |

Impeller trace includes texture uploads up to 567 ms. These are render durations, not input latency or YOLO execution time. Samples were sequential, not randomized; tile warmth, camera location and phone temperature differed. Android reported severe thermal status (3). Results support a renderer-specific problem on this device, not a universal speedup claim.

## Correction

- Android uses the supported Skia opt-out for this Flutter version. Flutter warns that the opt-out is deprecated; re-evaluate this workaround after engine upgrades and on other devices.
- Restore flutter_map default tile buffers: panBuffer 1, keepBuffer 2 (previously 2 and 6). Nearby tiles remain buffered without retaining such a large off-screen tile set.
- Ignore mouse-cursor touch state on native mobile; previously each pointer down/up rebuilt the whole map.
- Place the animated location marker inside a RepaintBoundary so its pulse/heading updates do not repaint all sibling map layers.
- Preserve the prior warning isolation and camera-event coalescing.

## Verification

15 map UI tests passed, including native pointer down/cancel without recreating FlutterMap, warning close/swipes, routing and marker visibility. Mobile/web analysis: existing informational lints only, no errors or warnings. Web source files unchanged. Raw profiles and logs: `.dart_tool/warning-lag/` (local diagnostic artifacts).

Final release installed with adb install -r and APK hash verified: `ded3f9617db07868908b6aee1f09eeb098372c195f0b5580ac161ea0f42f3f7f`. Confirmed renderer opt-out in running process. Repeated zoom in/out, pans, opening/closing filters and dismissing warning on the phone. Graphics memory snapshot 284392 KB versus initial 428284 KB; different viewport/warmth means this is observational, not a controlled memory benchmark. APK copied to Downloads/RoadSense-latest.apk.

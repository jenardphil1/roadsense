# Scanner performance investigation

The active model is now Optimized v2 (608 × 608 input, `[1, 9, 7581]` output), not the older 896px Package 6 model. The installed Android app forced CPU inference with four threads. On the connected TECNO LH7n, processing after capture took 2935–5138ms in the first observed cycles and around 2838–4253ms in a later sample. The live UI could close back to the map; no ANR was established by this observation.

Full-model GPU trials failed: OpenGL reported `No shader implementation for transpose`; OpenCL did not finish initialization during the observed period exceeding one minute. CPU fallback timing separated the bottleneck: inference about 5.8–6.2s, camera about 0.4s, preprocessing roughly 0.1s, and negligible postprocessing. CPU/GPU sensor status also reached the device's 55°C throttling threshold. These samples were taken under different thermal conditions.

Final changes:
- Partition the same model before the six NHWC-to-NCHW feature transposes: 290 convolution operations in `live_backbone.tflite`, 30 output/DFL operations in `live_head.tflite`. Run the backbone on OpenCL with sustained-speed/FP16-permitted options and decode its six float feature buffers with a small CPU interpreter. Retain the original FP32 CPU fallback on initialization failure. Initialization, inference and disposal remain on the same native worker.
- Cache the GPU compilation in the private code cache. The token includes SHA-256 of the actual model bytes and a versioned backend/options prefix, preventing reuse across changed model weights. OS cache eviction or model/app updates can require compilation again.
- Release interpreter/delegate resources after failed model initialization.
- Log capture time separately from processing and total time, and native inference separately from postprocessing.
- Delete temporary camera files asynchronously instead of performing synchronous filesystem work on the Dart UI isolate.

Verification completed before device evaluation:
- Original and static exports have identical stored data buffers and expected input/output shapes. The static export has concrete shape signatures.
- `python tools/prepare_split_live_model.py` reproducibly partitions operations without changing their weights. `python tools/verify_live_model.py`: original, static and partitioned CPU output tensors match exactly on six bundled annotated sample pictures. This validates export parity on those inputs, not field accuracy or GPU numerical parity.
- Eleven focused detection tests passed.
- Analysis of main.dart, detection helpers and the three required web screens found no errors; existing diagnostics remain.

Backend API reference: https://developers.google.com/edge/api/tflite/java/org/tensorflow/lite/gpu/GpuDelegateFactory.Options.GpuBackend

Device results on TECNO LH7n:
- Split OpenGL worked, but backbone processing remained around 3.2s; it was not selected.
- Split OpenCL finished its initial compilation and detected longitudinal cracks in both passes. At 01:09, backbone timings were 334–351ms, head 6–8ms, and complete capture/processing cycles 775–812ms in the recorded sample. These are short-session observations, not guaranteed FPS or field accuracy.
- Capture retained the matching longitudinal-crack image and showed 73% confidence in review. No report was submitted.
- Final cache-enabled profile APK installed with existing user data preserved. First model setup took 53069ms. After force-stop/relaunch, the native log explicitly confirmed loading serialized GPU data and model startup took 2760ms.
- Final restarted build at 01:12: backbone 364–378ms, complete capture/processing 952–1017ms in the recorded sample. Capture immediately opened review with the matching longitudinal crack at 72%; the scanner was left stopped on review. Capture and earlier Close interactions responded successfully; a formal input-latency benchmark was not performed.
- Source/UI/model weights and partition parity were checked as described above. GPU reduced-precision numerical equivalence has not been established across a representative dataset; sample detections and capture consistency were observed on the device.

## Follow-up: intermittent detection

The next observed scene was a monitor showing several small road photographs.
Both alternating full-frame and center-crop passes returned empty results, and
the captured photo also returned no detections. A local CPU comparison on that
same 720 x 1280 upright JPEG isolated substantial sensitivity to downsampling:
OpenCV linear resize gave a maximum longitudinal score of 0.0018, while area
resize gave 0.7468. A separate affine simulation of the previous Canvas resize
gave 0.0019. These simulations are not a bit-exact measurement of Android Canvas
or GPU output; filming a screen introduces moire that is especially sensitive to
sampling. This is evidence for a preprocessing issue on this example, not proof
that every missed detection has the same cause.

Changes:
- Use OpenCV INTER_AREA when reducing RoadSense photos before inference; retain
  linear interpolation for enlargement. Preserve RGB normalization, 608 input,
  EXIF handling, RGB 114 padding, weights, and the 0.25 detection threshold.
- Map boxes using the actual rounded resize dimensions and integer crop/padding
  offsets. Preprocessing remains on the native worker.
- Check the full view on every live cycle. If it has no accepted detections,
  retry the center crop of the same JPEG before publishing the result. A crop
  miss can no longer replace a successful full-frame result on alternate cycles.
  Empty full frames cost a second inference; additional small objects needing
  the crop are not searched for when the full view already detects an object.
- Retain the existing bounded one-miss display hold and matching capture image.
  No confidence boosting or extended persistence was introduced.

Verification:
- All 11 focused snapshot, model-alignment and letterbox tests passed.
- Analysis of the mobile entry point, detection helpers and required web screens
  reported no errors and 23 existing informational diagnostics.
- Profile APK built successfully. Six bundled annotated longitudinal examples
  retained maximum scores above 0.25 with both linear and area resize (area
  range 0.2532 to 0.7310). These are preprocessing smoke checks, not a recall,
  precision or all-class benchmark; annotations are already drawn on the images.
- The captured monitor scene reached 0.7468 with area preprocessing on CPU.
  Local diagnostic scripts/results are under ignored `.dart_tool/` and the
  captured user image is not added to project assets.
- The phone disconnected before installation of this follow-up APK. Live GPU
  consistency, updated cycle timings and capture behavior still need device
  verification; the earlier device timings above apply to the preceding build.

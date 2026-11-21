# RoadSense local changes to flutter_vision 2.0.0

Upstream license is retained in LICENSE. This path dependency keeps the Android
GPU lifecycle fix reproducible rather than modifying a machine's pub cache.

- Initialize, invoke, and close the interpreter on the same single worker.
- Dispose the GPU delegate after the interpreter, including CPU fallback.
- Queue cleanup after pending work when the plugin detaches.
- Close an existing model before replacing it.
- Optional RoadSense image preprocessing: decode JPEG/EXIF orientation once,
  letterbox or center-crop on the worker, return original dimensions and mapped
  boxes. Ordinary plugin image calls retain their original response format.

The original Dart API and iOS implementation are retained.

Optimized v2 performance update (2026-11-15): optional `headModelPath` loads a
partitioned YOLOv8 detector. The six convolution feature outputs run through a
small CPU decoding model, allowing sustained-speed OpenCL acceleration without
delegating the output transposes/DFL. GPU binaries are cached in the app-private
code cache using a SHA-256 token of the model plus an options-version prefix.
Original single-model calls and CPU fallback remain supported. The partition
script and CPU parity checks live in `tools/prepare_split_live_model.py` and
`tools/verify_live_model.py`.

Detection consistency update (2026-11-15): RoadSense photo preprocessing now
uses OpenCV area downsampling, with linear interpolation only when enlarging,
to suppress aliasing of fine detail. Letterbox and crop coordinates use the
actual integer resize dimensions when mapping boxes back to the source image.
Model normalization, weights and detection thresholds are unchanged.

Retry race correction (2026-11-16): release image resources and the inference
busy guard before replying to Dart. A same-photo detail retry can arrive as soon
as the first reply completes. Busy image requests now return DETECTOR_BUSY
instead of a bare list incompatible with RoadSense's mapped image response.

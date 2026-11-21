# Detection preprocessing investigation

The connected Android phone successfully loaded the model and ran inference, but repeatedly returned zero detections on a portrait frame showing a pothole photograph on a monitor. The plugin resized 720x1280 frames directly to 896x896, distorting their proportions.

An offline comparison using the visible camera region of that screenshot and the bundled FP32 model gave maximum pothole scores of 0.0031 with stretched input, 0.6894 with aspect-preserving gray padding, and 0.0887 with a center crop. This is a diagnostic example, not a representative accuracy benchmark; it includes screen artifacts and scanner overlays.

Live and captured-photo inference now use an aspect-preserving 896px square with RGB 114 padding. Returned boxes are transformed back to original image coordinates before validation and clipping. The 0.25 threshold and model weights remain unchanged. Native image resources are disposed after inference.

Live scanning now stops with a visible error and Retry action if inference fails, and does not start when model loading fails.

Eight focused regression tests pass, including portrait/landscape coordinate mapping and rejection of boxes entirely in padding. Required web and mobile analysis found no errors. The debug APK was built and installed over the existing app without clearing its data. On-device logs confirm 896x896 preprocessed input reaches inference.

On-device confirmation at 23:02:07: native inference returned one pothole with probability 0.7687199. The live UI displayed “1 DETECTED” and “[CODE 01] Pothole • 77%” over the same monitor image used in the investigation. This verifies the pipeline correction on the connected phone, not accuracy across all four classes or field conditions.

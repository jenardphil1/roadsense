# Switch to New Pothole Detection Model

The user wants to switch to a new TFLite model located in `assets/best_saved_model`. This model only has one classification: `pothole`.

## Proposed Changes

### Assets

#### [MODIFY] [labels.txt](file:///c:/ssdd/flutter/assets/labels.txt)
- Update the labels to only include `pothole` to match the new model's output.

### Flutter Code

#### [MODIFY] [main.dart](file:///c:/ssdd/flutter/lib/main.dart)
- Verify the model path is correctly set to `assets/best_saved_model/best_float32.tflite`. (It appears already set, but I will double-check the filename and path).

## Verification Plan

### Manual Verification
- The user should run the app and verify that detected potholes are now labeled simply as "pothole" instead of "minor/medium/major_pothole".
- Ensure that the model loads correctly on startup.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Result of cropping a captured scan image to the live-scanner visible viewport.
class CroppedScanImage {
  final Uint8List bytes;
  final int width;
  final int height;
  final ui.Rect cropRect;
  final int sourceWidth;
  final int sourceHeight;

  const CroppedScanImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.cropRect,
    required this.sourceWidth,
    required this.sourceHeight,
  });
}

ui.Rect _centerCropRect(ui.Rect bounds, double targetAspect) {
  final double boundsAspect = bounds.width / bounds.height;
  if ((boundsAspect - targetAspect).abs() < 1e-4) {
    return bounds;
  }
  if (boundsAspect > targetAspect) {
    final double newW = bounds.height * targetAspect;
    final double dx = (bounds.width - newW) / 2.0;
    return ui.Rect.fromLTWH(bounds.left + dx, bounds.top, newW, bounds.height);
  }
  final double newH = bounds.width / targetAspect;
  final double dy = (bounds.height - newH) / 2.0;
  return ui.Rect.fromLTWH(bounds.left, bounds.top + dy, bounds.width, newH);
}

/// Computes the pixel crop rectangle inside [imageWidth]x[imageHeight] that
/// corresponds to the visible region rendered by `CameraPreview` inside a
/// `BoxFit.cover` viewport of size [viewWidth]x[viewHeight].
ui.Rect computeVisibleScanCropRect({
  required int imageWidth,
  required int imageHeight,
  required double viewWidth,
  required double viewHeight,
  double? previewAspectRatio,
}) {
  if (imageWidth <= 0 ||
      imageHeight <= 0 ||
      !viewWidth.isFinite ||
      !viewHeight.isFinite ||
      viewWidth <= 0 ||
      viewHeight <= 0) {
    return ui.Rect.fromLTWH(
      0,
      0,
      math.max(0, imageWidth).toDouble(),
      math.max(0, imageHeight).toDouble(),
    );
  }

  ui.Rect rect = ui.Rect.fromLTWH(
    0,
    0,
    imageWidth.toDouble(),
    imageHeight.toDouble(),
  );

  // Step 1: sensor-to-preview aspect crop if camera preview stream aspect differs
  // from full-res JPEG capture aspect.
  if (previewAspectRatio != null &&
      previewAspectRatio.isFinite &&
      previewAspectRatio > 0) {
    rect = _centerCropRect(rect, previewAspectRatio);
  }

  // Step 2: preview-to-viewport BoxFit.cover crop.
  rect = _centerCropRect(rect, viewWidth / viewHeight);

  final int left = rect.left.round().clamp(0, imageWidth - 1);
  final int top = rect.top.round().clamp(0, imageHeight - 1);
  final int width = rect.width.round().clamp(1, imageWidth - left);
  final int height = rect.height.round().clamp(1, imageHeight - top);

  return ui.Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
}

/// Remaps detection bounding boxes from source image space into the cropped
/// output image coordinates, dropping boxes outside [cropRect].
List<Map<String, dynamic>> remapDetectionsToCropRect(
  List<Map<String, dynamic>> detections, {
  required ui.Rect cropRect,
  required int sourceWidth,
  required int sourceHeight,
  int? detectionImageWidth,
  int? detectionImageHeight,
  required int outputWidth,
  required int outputHeight,
  double minVisibleFraction = 0.15,
}) {
  if (detections.isEmpty ||
      cropRect.width <= 0 ||
      cropRect.height <= 0 ||
      outputWidth <= 0 ||
      outputHeight <= 0) {
    return const [];
  }

  final double srcScaleX =
      (detectionImageWidth != null && detectionImageWidth > 0)
      ? sourceWidth / detectionImageWidth
      : 1.0;
  final double srcScaleY =
      (detectionImageHeight != null && detectionImageHeight > 0)
      ? sourceHeight / detectionImageHeight
      : 1.0;

  final double outScaleX = outputWidth / cropRect.width;
  final double outScaleY = outputHeight / cropRect.height;

  final List<Map<String, dynamic>> remapped = [];
  for (final det in detections) {
    final box = det['box'];
    if (box is! List || box.length < 4) continue;

    final double x1 = (box[0] as num).toDouble() * srcScaleX;
    final double y1 = (box[1] as num).toDouble() * srcScaleY;
    final double x2 = (box[2] as num).toDouble() * srcScaleX;
    final double y2 = (box[3] as num).toDouble() * srcScaleY;

    final double origArea = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);

    final double cl = x1.clamp(cropRect.left, cropRect.right);
    final double ct = y1.clamp(cropRect.top, cropRect.bottom);
    final double cr = x2.clamp(cropRect.left, cropRect.right);
    final double cb = y2.clamp(cropRect.top, cropRect.bottom);

    final double visArea = math.max(0.0, cr - cl) * math.max(0.0, cb - ct);
    if (visArea <= 0 ||
        (origArea > 0 && visArea / origArea < minVisibleFraction)) {
      continue;
    }

    final double outL = ((cl - cropRect.left) * outScaleX).clamp(
      0.0,
      outputWidth.toDouble(),
    );
    final double outT = ((ct - cropRect.top) * outScaleY).clamp(
      0.0,
      outputHeight.toDouble(),
    );
    final double outR = ((cr - cropRect.left) * outScaleX).clamp(
      0.0,
      outputWidth.toDouble(),
    );
    final double outB = ((cb - cropRect.top) * outScaleY).clamp(
      0.0,
      outputHeight.toDouble(),
    );

    if (outR - outL < 2.0 || outB - outT < 2.0) continue;

    remapped.add(<String, dynamic>{
      ...det,
      'box': <dynamic>[outL, outT, outR, outB, ...box.sublist(4)],
    });
  }
  return remapped;
}

/// Computes a privacy-preserving pixel crop rectangle tightly framing the
/// union of all valid [detections] in [sourceWidth]x[sourceHeight] with a
/// proportional [paddingFraction] context margin. Returns `null` if no valid
/// bounding boxes are present.
ui.Rect? computeHazardPrivacyCropRect({
  required List<Map<String, dynamic>> detections,
  required int sourceWidth,
  required int sourceHeight,
  int? detectionImageWidth,
  int? detectionImageHeight,
  double paddingFraction = 0.22,
  double minCropSide = 160.0,
}) {
  if (detections.isEmpty || sourceWidth <= 0 || sourceHeight <= 0) {
    return null;
  }
  final double srcScaleX =
      (detectionImageWidth != null && detectionImageWidth > 0)
      ? sourceWidth / detectionImageWidth
      : 1.0;
  final double srcScaleY =
      (detectionImageHeight != null && detectionImageHeight > 0)
      ? sourceHeight / detectionImageHeight
      : 1.0;

  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = double.negativeInfinity;
  double maxY = double.negativeInfinity;

  for (final det in detections) {
    final box = det['box'];
    if (box is! List || box.length < 4) continue;
    final double x1 = ((box[0] as num).toDouble() * srcScaleX).clamp(
      0.0,
      sourceWidth.toDouble(),
    );
    final double y1 = ((box[1] as num).toDouble() * srcScaleY).clamp(
      0.0,
      sourceHeight.toDouble(),
    );
    final double x2 = ((box[2] as num).toDouble() * srcScaleX).clamp(
      0.0,
      sourceWidth.toDouble(),
    );
    final double y2 = ((box[3] as num).toDouble() * srcScaleY).clamp(
      0.0,
      sourceHeight.toDouble(),
    );
    if (x2 - x1 < 2.0 || y2 - y1 < 2.0) continue;
    if (x1 < minX) minX = x1;
    if (y1 < minY) minY = y1;
    if (x2 > maxX) maxX = x2;
    if (y2 > maxY) maxY = y2;
  }

  if (!minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite) {
    return null;
  }

  final double boxW = maxX - minX;
  final double boxH = maxY - minY;
  final double padX = math.max(boxW * paddingFraction, (minCropSide - boxW) / 2);
  final double padY = math.max(boxH * paddingFraction, (minCropSide - boxH) / 2);

  final int left = (minX - padX).floor().clamp(0, sourceWidth - 1);
  final int top = (minY - padY).floor().clamp(0, sourceHeight - 1);
  final int right = (maxX + padX).ceil().clamp(left + 1, sourceWidth);
  final int bottom = (maxY + padY).ceil().clamp(top + 1, sourceHeight);

  return ui.Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// Decodes [rawBytes], physically crops to the detected hazard bounding box
/// union (with context margin) for privacy, or falls back to the visible
/// scanner viewport if no valid bounding boxes are present.
Future<CroppedScanImage> cropImageBytesToHazardRegion(
  Uint8List rawBytes, {
  required List<Map<String, dynamic>> detections,
  int? detectionImageWidth,
  int? detectionImageHeight,
  ui.Size? fallbackViewSize,
  double? fallbackPreviewAspectRatio,
  double paddingFraction = 0.22,
  double maxDimension = 1280.0,
}) async {
  ui.Codec? codec;
  ui.Image? src;
  ui.Picture? picture;
  ui.Image? cropped;
  try {
    codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    src = frame.image;

    final ui.Rect cropRect =
        computeHazardPrivacyCropRect(
          detections: detections,
          sourceWidth: src.width,
          sourceHeight: src.height,
          detectionImageWidth: detectionImageWidth,
          detectionImageHeight: detectionImageHeight,
          paddingFraction: paddingFraction,
        ) ??
        (fallbackViewSize != null &&
                fallbackViewSize.width > 0 &&
                fallbackViewSize.height > 0
            ? computeVisibleScanCropRect(
                imageWidth: src.width,
                imageHeight: src.height,
                viewWidth: fallbackViewSize.width,
                viewHeight: fallbackViewSize.height,
                previewAspectRatio: fallbackPreviewAspectRatio,
              )
            : ui.Rect.fromLTWH(
                0,
                0,
                src.width.toDouble(),
                src.height.toDouble(),
              ));

    final double maxSide = math.max(cropRect.width, cropRect.height);
    final double scale = maxSide > 0
        ? math.min(1.0, maxDimension / maxSide)
        : 1.0;
    final int targetW = math.max(1, (cropRect.width * scale).round());
    final int targetH = math.max(1, (cropRect.height * scale).round());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
    );
    canvas.drawImageRect(
      src,
      cropRect,
      ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    picture = recorder.endRecording();
    cropped = await picture.toImage(targetW, targetH);
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('Failed to encode hazard-cropped scan image as PNG.');
    }
    return CroppedScanImage(
      bytes: byteData.buffer.asUint8List(),
      width: targetW,
      height: targetH,
      cropRect: cropRect,
      sourceWidth: src.width,
      sourceHeight: src.height,
    );
  } finally {
    cropped?.dispose();
    picture?.dispose();
    src?.dispose();
    codec?.dispose();
  }
}

/// Decodes [rawBytes], physically crops to the visible scanner area computed
/// for [viewSize] (and optional [previewAspectRatio]), caps max dimension at
/// [maxDimension], and encodes the resulting upright PNG.
Future<CroppedScanImage> cropImageBytesToVisibleScan(
  Uint8List rawBytes, {
  required ui.Size viewSize,
  double? previewAspectRatio,
  double maxDimension = 1280.0,
}) async {
  ui.Codec? codec;
  ui.Image? src;
  ui.Picture? picture;
  ui.Image? cropped;
  try {
    codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    src = frame.image;

    final cropRect = computeVisibleScanCropRect(
      imageWidth: src.width,
      imageHeight: src.height,
      viewWidth: viewSize.width,
      viewHeight: viewSize.height,
      previewAspectRatio: previewAspectRatio,
    );

    final double maxSide = math.max(cropRect.width, cropRect.height);
    final double scale = maxSide > 0
        ? math.min(1.0, maxDimension / maxSide)
        : 1.0;
    final int targetW = math.max(1, (cropRect.width * scale).round());
    final int targetH = math.max(1, (cropRect.height * scale).round());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
    );
    canvas.drawImageRect(
      src,
      cropRect,
      ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    picture = recorder.endRecording();
    cropped = await picture.toImage(targetW, targetH);
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('Failed to encode cropped scan image as PNG.');
    }
    return CroppedScanImage(
      bytes: byteData.buffer.asUint8List(),
      width: targetW,
      height: targetH,
      cropRect: cropRect,
      sourceWidth: src.width,
      sourceHeight: src.height,
    );
  } finally {
    cropped?.dispose();
    picture?.dispose();
    src?.dispose();
    codec?.dispose();
  }
}

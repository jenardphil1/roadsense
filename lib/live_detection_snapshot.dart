import 'dart:typed_data';
import 'dart:math' as math;

class LiveDetectionSnapshot {
  final Uint8List bytes;
  final int width, height;
  final DateTime detectedAt;
  final List<Map<String, dynamic>> detections;

  LiveDetectionSnapshot(
    Uint8List image,
    this.width,
    this.height,
    List<Map<String, dynamic>> results,
    this.detectedAt,
  ) : bytes = Uint8List.fromList(image),
      detections = results
          .map(
            (d) => <String, dynamic>{
              ...d,
              'box': List<dynamic>.from(d['box'] as List),
            },
          )
          .toList();
}

class _Track {
  final int id;
  int classId, misses = 0, candidateHits = 0;
  int? candidate;
  List<num> box;
  DateTime seenAt;

  _Track(this.id, this.classId, this.box, this.seenAt);

  bool observe(Map<String, dynamic> result, DateTime time) {
    box = List<num>.from(result['box'] as List);
    seenAt = time;
    misses = 0;
    final observed = result['classId'] as int;
    if (observed == classId) {
      candidate = null;
      candidateHits = 0;
    } else {
      candidateHits = candidate == observed ? candidateHits + 1 : 1;
      candidate = observed;
      if (candidateHits >= 3) {
        classId = observed;
        candidate = null;
        candidateHits = 0;
      }
    }
    return observed == classId;
  }
}

/// Associates analyzed photos, not camera-preview frames. Never predicts boxes
/// on a newer image. A class change needs three consecutive matched observations.
class LiveDetectionBuffer {
  static const hold = Duration(seconds: 3);
  // One missed ~1.5 s full/detail cycle plus the next result's processing time.
  // The photo has a shorter lifetime; identity never extends stale imagery.
  static const trackHold = Duration(seconds: 4);
  static const minimumIou = 0.30;
  LiveDetectionSnapshot? _snapshot;
  final _tracks = <_Track>[];
  int _nextId = 1, _width = 0, _height = 0;
  DateTime? _lastFrame;
  bool _held = false;
  bool get isHeld => _held;

  int activeCount(DateTime now) =>
      _tracks.where((track) => now.difference(track.seenAt) < trackHold).length;

  Duration? untilExpiry(DateTime now) {
    final deadlines = [
      if (_snapshot != null) _snapshot!.detectedAt.add(hold),
      ..._tracks.map((track) => track.seenAt.add(trackHold)),
    ];
    if (deadlines.isEmpty) return null;
    deadlines.sort();
    final remaining = deadlines.first.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void expire(DateTime now) {
    _tracks.removeWhere((track) => now.difference(track.seenAt) >= trackHold);
    if (_snapshot != null && now.difference(_snapshot!.detectedAt) >= hold) {
      _snapshot = null;
    }
  }

  LiveDetectionSnapshot? current(DateTime now) {
    final snapshot = _snapshot;
    return snapshot != null && now.difference(snapshot.detectedAt) < hold
        ? snapshot
        : null;
  }

  LiveDetectionSnapshot? update(
    Uint8List image,
    int width,
    int height,
    List<Map<String, dynamic>> results,
    DateTime now, {
    DateTime? capturedAt,
  }) {
    final frameTime = capturedAt ?? now;
    expire(now);
    // Late/out-of-order results must not renew an expired detection.
    if (now.difference(frameTime) >= hold ||
        frameTime.isAfter(now) ||
        (_lastFrame != null && !frameTime.isAfter(_lastFrame!))) {
      return current(now);
    }
    if (_width != width || _height != height) {
      clear();
    }
    _width = width;
    _height = height;
    _lastFrame = frameTime;

    // Highest-overlap one-to-one assignment keeps neighboring defects separate.
    // honey: O(tracks * detections), small detector output; revisit for crowds.
    final pairs = <({int track, int result, double iou})>[];
    for (var t = 0; t < _tracks.length; t++) {
      for (var r = 0; r < results.length; r++) {
        final iou = _iou(_tracks[t].box, results[r]['box'] as List);
        if (iou >= minimumIou) pairs.add((track: t, result: r, iou: iou));
      }
    }
    pairs.sort((a, b) => b.iou.compareTo(a.iou));
    final usedTracks = <int>{}, usedResults = <int>{};
    final accepted = <Map<String, dynamic>>[];
    for (final pair in pairs) {
      if (usedTracks.contains(pair.track) ||
          usedResults.contains(pair.result)) {
        continue;
      }
      usedTracks.add(pair.track);
      usedResults.add(pair.result);
      final track = _tracks[pair.track];
      final result = results[pair.result];
      if (track.observe(result, frameTime)) {
        accepted.add({...result, 'trackId': track.id});
      }
    }
    for (var t = 0; t < _tracks.length; t++) {
      if (!usedTracks.contains(t)) {
        _tracks[t].misses++;
        _tracks[t].candidate = null;
        _tracks[t].candidateHits = 0;
      }
    }
    _tracks.removeWhere((track) => track.misses >= 2);
    for (var r = 0; r < results.length; r++) {
      if (usedResults.contains(r)) continue;
      final result = results[r];
      final track = _Track(
        _nextId++,
        result['classId'] as int,
        List<num>.from(result['box'] as List),
        frameTime,
      );
      _tracks.add(track);
      accepted.add({...result, 'trackId': track.id});
    }
    accepted.sort(
      (a, b) => (a['trackId'] as int).compareTo(b['trackId'] as int),
    );
    _held = accepted.isEmpty;
    if (accepted.isNotEmpty) {
      // Retain original classes, probabilities and coordinates from THIS photo.
      // Conflicting classifications are withheld, never relabeled for capture.
      _snapshot = LiveDetectionSnapshot(
        image,
        width,
        height,
        accepted,
        frameTime,
      );
    } else if (_tracks.isEmpty) {
      _snapshot = null;
    }
    return current(now);
  }

  static double _iou(List a, List b) {
    final intersection =
        math.max(0, math.min(a[2], b[2]) - math.max(a[0], b[0])) *
        math.max(0, math.min(a[3], b[3]) - math.max(a[1], b[1]));
    final union =
        (a[2] - a[0]) * (a[3] - a[1]) +
        (b[2] - b[0]) * (b[3] - b[1]) -
        intersection;
    return union > 0 ? intersection / union : 0;
  }

  void clear() {
    _snapshot = null;
    _tracks.clear();
    _held = false;
    _lastFrame = null;
  }
}

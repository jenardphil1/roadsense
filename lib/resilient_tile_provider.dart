import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Offline-capable, multi-host resilient tile provider for mobile [TileLayer].
///
/// Key guarantees:
/// 1. Coordinate-normalized disk cache (`z/x_y`) stored in persistent app
///    support storage so tiles survive OS temp-cache clears and subdomain splits.
/// 2. Always falls back to existing cached tiles when offline/unreachable even if
///    HTTP cache headers would consider them stale.
/// 3. Concurrency-capped outbound fetches + multi-host failover (Google -> alternate
///    Google subdomain -> CartoDB Voyager -> OSM Standard) to eliminate partial
///    blank tile checkerboards on spotty mobile data.
/// 4. Offline ancestor-tile cropping (zoom levels z-1..z-4) and a subtle grid
///    placeholder (never saved to disk) that auto-evicts once back online.
class ResilientTileProvider extends TileProvider {
  ResilientTileProvider({
    super.headers,
    http.Client? httpClient,
    String? cacheDirectoryPath,
    this.freshAge = const Duration(days: 14),
    this.requestTimeout = const Duration(seconds: 6),
    this.maxDiskCacheBytes = 250 * 1024 * 1024,
    this.isOfflineCheck,
    this.onFallbackStateChanged,
    bool? enableBackgroundPrewarm,
  }) : _ownsHttpClient = httpClient == null,
       _httpClient = httpClient ?? http.Client(),
       _explicitCacheDirectoryPath = cacheDirectoryPath,
       enableBackgroundPrewarm =
           enableBackgroundPrewarm ??
           (!kIsWeb && !io.Platform.environment.containsKey('FLUTTER_TEST'));

  final bool _ownsHttpClient;
  final http.Client _httpClient;
  final String? _explicitCacheDirectoryPath;
  final Duration freshAge;
  final Duration requestTimeout;
  final int maxDiskCacheBytes;
  final bool Function()? isOfflineCheck;
  final VoidCallback? onFallbackStateChanged;
  final bool enableBackgroundPrewarm;

  final _AsyncSemaphore _networkSemaphore = _AsyncSemaphore(6);
  final LinkedHashMap<String, ({Uint8List bytes, DateTime savedAt})>
  _memoryTiles = LinkedHashMap();
  static const int _maxMemoryTiles = 128;

  final Map<TileCoordinates, _ResilientTileImageProvider> _fallbackKeys = {};
  final Set<String> _prewarmRequestedKeys = {};
  final Set<Future<void>> _pendingDiskWrites = {};
  Future<String?>? _cacheDirFuture;
  String? _resolvedCacheDir;
  bool _pruneScheduled = false;
  bool _disposed = false;
  Uint8List? _cachedGridTilePng;

  @override
  bool get supportsCancelLoading => true;

  bool get hasFallbackTiles => _fallbackKeys.isNotEmpty;

  int get fallbackTileCount => _fallbackKeys.length;

  /// Waits for all currently scheduled background disk writes to complete.
  Future<void> flushPendingDiskWrites() async {
    while (_pendingDiskWrites.isNotEmpty) {
      await Future.wait(_pendingDiskWrites.toList());
    }
  }

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final primaryUrl = getTileUrl(coordinates, options);
    final candidateUrls = candidateUrlsForTile(coordinates, primaryUrl);
    return _ResilientTileImageProvider(
      provider: this,
      coordinates: coordinates,
      candidateUrls: candidateUrls,
      abortTrigger: cancelLoading,
    );
  }

  /// Evicts only temporary fallback/grid image keys from Flutter's [ImageCache]
  /// so real network tiles can reload cleanly when connectivity returns.
  int evictFallbackTiles() {
    if (_fallbackKeys.isEmpty) return 0;
    final keysToEvict = _fallbackKeys.values.toList(growable: false);
    _fallbackKeys.clear();
    for (final key in keysToEvict) {
      try {
        PaintingBinding.instance.imageCache.evict(key);
      } catch (_) {}
    }
    onFallbackStateChanged?.call();
    return keysToEvict.length;
  }

  void _recordFallbackKey(
    TileCoordinates coordinates,
    _ResilientTileImageProvider key,
  ) {
    final wasEmpty = _fallbackKeys.isEmpty;
    _fallbackKeys[coordinates] = key;
    if (wasEmpty) {
      onFallbackStateChanged?.call();
    }
  }

  void _clearFallbackKey(TileCoordinates coordinates) {
    if (_fallbackKeys.remove(coordinates) != null && _fallbackKeys.isEmpty) {
      onFallbackStateChanged?.call();
    }
  }

  static String normalizedTileKey(int z, int x, int y) => '${z}_${x}_$y';

  /// Validates common raster tile headers (PNG, JPEG, WebP, GIF) so JSON/HTML
  /// error bodies or truncated payloads are rejected before caching.
  static bool isValidTileImageBytes(Uint8List bytes) {
    final len = bytes.lengthInBytes;
    if (len < 16) return false;
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return true;
    }
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // GIF8
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true;
    }
    return false;
  }

  /// Builds ordered unique failover URLs for a tile coordinate.
  static List<String> candidateUrlsForTile(
    TileCoordinates coordinates,
    String primaryUrl,
  ) {
    final z = coordinates.z;
    final x = coordinates.x;
    final y = coordinates.y;
    final urls = <String>[primaryUrl];

    // If primary uses a Google subdomain, add an alternate subdomain first in case
    // one edge node drops/rate-limits a burst of mobile connections.
    final mtMatch = RegExp(
      r'https://mt([0-3])\.google\.com/',
    ).firstMatch(primaryUrl);
    if (mtMatch != null) {
      final currSub = int.parse(mtMatch.group(1)!);
      final altSub = (currSub + 1) % 4;
      urls.add(
        primaryUrl.replaceFirst(
          'https://mt$currSub.google.com/',
          'https://mt$altSub.google.com/',
        ),
      );
    }

    if (z >= 0 && z <= 19) {
      urls.add(
        'https://a.basemaps.cartocdn.com/rastertiles/voyager/$z/$x/$y.png',
      );
      urls.add('https://tile.openstreetmap.org/$z/$x/$y.png');
    }

    final deduped = <String>[];
    final seen = <String>{};
    for (final url in urls) {
      if (url.isNotEmpty && seen.add(url)) {
        deduped.add(url);
      }
    }
    return deduped;
  }

  static (int x, int y) latLngToTile(double lat, double lng, int zoom) {
    final n = 1 << zoom;
    final clampedLat = lat.clamp(-85.05112878, 85.05112878);
    final latRad = clampedLat * math.pi / 180.0;
    final x = (((lng + 180.0) / 360.0) * n).floor().clamp(0, n - 1);
    final y =
        ((1.0 -
                    math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) /
                        math.pi) /
                2.0 *
                n)
            .floor()
            .clamp(0, n - 1);
    return (x, y);
  }

  Future<String?> _ensureCacheDir() {
    if (_resolvedCacheDir != null) return Future.value(_resolvedCacheDir);
    if (kIsWeb) return Future.value(null);
    return _cacheDirFuture ??= () async {
      try {
        final String base;
        if (_explicitCacheDirectoryPath != null) {
          base = _explicitCacheDirectoryPath;
        } else {
          final supportDir = await getApplicationSupportDirectory();
          base = p.join(supportDir.path, 'roadsense_tiles');
        }
        final v1Dir = io.Directory(p.join(base, 'v1'));
        await v1Dir.create(recursive: true);
        _resolvedCacheDir = v1Dir.path;
        if (!_pruneScheduled) {
          _pruneScheduled = true;
          unawaited(_pruneCacheIfOversized(v1Dir.path));
        }
        return _resolvedCacheDir;
      } catch (_) {
        return null;
      }
    }();
  }

  Future<void> _pruneCacheIfOversized(String rootPath) async {
    try {
      final root = io.Directory(rootPath);
      if (!await root.exists()) return;
      final files = <({io.File file, int size, DateTime modified})>[];
      int totalBytes = 0;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (_disposed) return;
        if (entity is io.File && entity.path.endsWith('.tile')) {
          try {
            final stat = await entity.stat();
            totalBytes += stat.size;
            files.add((file: entity, size: stat.size, modified: stat.modified));
          } catch (_) {}
        }
      }
      if (totalBytes <= maxDiskCacheBytes) return;
      final targetBytes = (maxDiskCacheBytes * 0.72).round();
      files.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in files) {
        if (_disposed || totalBytes <= targetBytes) break;
        try {
          await entry.file.delete();
          totalBytes -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _putMemory(String key, Uint8List bytes) {
    _memoryTiles.remove(key);
    _memoryTiles[key] = (bytes: bytes, savedAt: DateTime.now());
    while (_memoryTiles.length > _maxMemoryTiles) {
      _memoryTiles.remove(_memoryTiles.keys.first);
    }
  }

  Future<({Uint8List bytes, bool isFresh})?> _readCachedTile(
    int z,
    int x,
    int y,
  ) async {
    final key = normalizedTileKey(z, x, y);
    final mem = _memoryTiles[key];
    if (mem != null) {
      // Touch for LRU ordering.
      _memoryTiles.remove(key);
      _memoryTiles[key] = mem;
      final fresh = DateTime.now().difference(mem.savedAt) < freshAge;
      return (bytes: mem.bytes, isFresh: fresh);
    }

    final dir = await _ensureCacheDir();
    if (dir == null) return null;
    final file = io.File(p.join(dir, '$z', '${x}_$y.tile'));
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (!isValidTileImageBytes(bytes)) {
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      DateTime modified;
      try {
        modified = await file.lastModified();
      } catch (_) {
        modified = DateTime.now();
      }
      final isFresh = DateTime.now().difference(modified) < freshAge;
      _putMemory(key, bytes);
      return (bytes: bytes, isFresh: isFresh);
    } catch (_) {
      return null;
    }
  }

  void _scheduleTileDiskWrite(int z, int x, int y, Uint8List bytes) {
    if (_disposed || !isValidTileImageBytes(bytes)) return;
    _putMemory(normalizedTileKey(z, x, y), bytes);
    late final Future<void> writeFuture;
    writeFuture = _writeCachedTile(z, x, y, bytes).whenComplete(() {
      _pendingDiskWrites.remove(writeFuture);
    });
    _pendingDiskWrites.add(writeFuture);
  }

  Future<void> _writeCachedTile(int z, int x, int y, Uint8List bytes) async {
    if (_disposed || !isValidTileImageBytes(bytes)) return;
    _putMemory(normalizedTileKey(z, x, y), bytes);
    final dir = await _ensureCacheDir();
    if (dir == null || _disposed) return;
    try {
      final zoomDir = io.Directory(p.join(dir, '$z'));
      if (!await zoomDir.exists()) {
        await zoomDir.create(recursive: true);
      }
      final targetPath = p.join(zoomDir.path, '${x}_$y.tile');
      final tmpFile = io.File('$targetPath.tmp');
      await tmpFile.writeAsBytes(bytes, flush: false);
      try {
        await tmpFile.rename(targetPath);
      } catch (_) {
        await io.File(targetPath).writeAsBytes(bytes, flush: false);
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
      }
    } catch (_) {}
  }

  Future<({Uint8List bytes, bool isFallback, bool aborted})> loadTileBytes({
    required TileCoordinates coordinates,
    required List<String> candidateUrls,
    Future<void>? abortTrigger,
  }) async {
    final z = coordinates.z;
    final x = coordinates.x;
    final y = coordinates.y;

    bool isAborted = false;
    unawaited(abortTrigger?.then((_) => isAborted = true));

    // 1. Memory & persistent disk cache lookup first.
    final cached = await _readCachedTile(z, x, y);
    if (cached != null && cached.isFresh) {
      return (bytes: cached.bytes, isFallback: false, aborted: false);
    }

    final bool offline = isOfflineCheck?.call() ?? false;
    if (!offline && !isAborted && !_disposed) {
      final fetched = await _fetchFromUrls(
        candidateUrls: candidateUrls,
        abortTrigger: abortTrigger,
        isAbortedCheck: () => isAborted || _disposed,
      );
      if (isAborted) {
        return (
          bytes: TileProvider.transparentImage,
          isFallback: false,
          aborted: true,
        );
      }
      if (fetched != null) {
        _scheduleTileDiskWrite(z, x, y, fetched);
        return (bytes: fetched, isFallback: false, aborted: false);
      }
    }

    if (isAborted) {
      return (
        bytes: TileProvider.transparentImage,
        isFallback: false,
        aborted: true,
      );
    }

    // 2. When offline or all hosts fail, ALWAYS keep serving stale cached tile!
    if (cached != null) {
      return (bytes: cached.bytes, isFallback: false, aborted: false);
    }

    // 3. Try cropping & upscaling a cached parent tile (z-1 .. z-4).
    final ancestorBytes = await _buildAncestorFallbackPng(z, x, y);
    if (ancestorBytes != null) {
      return (bytes: ancestorBytes, isFallback: true, aborted: false);
    }

    // 4. Clean subtle cartographic grid fallback (never persisted to disk).
    final gridBytes = await _getOfflineGridTileBytes();
    return (bytes: gridBytes, isFallback: true, aborted: false);
  }

  Future<Uint8List?> _fetchFromUrls({
    required List<String> candidateUrls,
    required Future<void>? abortTrigger,
    required bool Function() isAbortedCheck,
  }) async {
    for (final rawUrl in candidateUrls) {
      if (isAbortedCheck()) return null;
      final acquired = await _networkSemaphore.acquire(
        abortTrigger: abortTrigger,
        isAbortedCheck: isAbortedCheck,
      );
      if (!acquired) return null;
      try {
        if (isAbortedCheck()) return null;
        final uri = Uri.parse(rawUrl);
        final reqHeaders = <String, String>{
          ...headers,
          'Accept': 'image/png,image/webp,image/jpeg,image/*;q=0.8',
          if (!headers.containsKey('User-Agent'))
            'User-Agent': 'RoadSenseAI/1.0 (com.example.my_flutter_app)',
        };
        final responseFuture = _httpClient
            .get(uri, headers: reqHeaders)
            .timeout(requestTimeout);
        final http.Response response;
        if (abortTrigger != null) {
          final result = await Future.any<http.Response?>([
            responseFuture,
            abortTrigger.then((_) => null),
          ]);
          if (result == null || isAbortedCheck()) return null;
          response = result;
        } else {
          response = await responseFuture;
        }
        if (response.statusCode == 200 &&
            isValidTileImageBytes(response.bodyBytes)) {
          return response.bodyBytes;
        }
      } catch (_) {
        // Try next failover host.
      } finally {
        _networkSemaphore.release();
      }
    }
    return null;
  }

  Future<Uint8List?> _buildAncestorFallbackPng(int z, int x, int y) async {
    if (x < 0 || y < 0 || z <= 8) return null;
    for (int delta = 1; delta <= 4; delta++) {
      final parentZ = z - delta;
      if (parentZ < 8) break;
      final scale = 1 << delta;
      final parentX = x ~/ scale;
      final parentY = y ~/ scale;
      final cachedParent = await _readCachedTile(parentZ, parentX, parentY);
      if (cachedParent == null) continue;

      ui.Codec? codec;
      ui.Image? srcImage;
      ui.Picture? picture;
      ui.Image? outImage;
      try {
        codec = await ui.instantiateImageCodec(cachedParent.bytes);
        final frame = await codec.getNextFrame();
        srcImage = frame.image;
        final subX = x % scale;
        final subY = y % scale;
        final tileW = srcImage.width / scale;
        final tileH = srcImage.height / scale;
        final srcRect = Rect.fromLTWH(
          subX * tileW,
          subY * tileH,
          tileW,
          tileH,
        );

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        const outRect = ui.Rect.fromLTWH(0, 0, 256, 256);
        final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
        canvas.drawImageRect(srcImage, srcRect, outRect, paint);
        picture = recorder.endRecording();
        outImage = await picture.toImage(256, 256);
        final bd = await outImage.toByteData(format: ui.ImageByteFormat.png);
        if (bd != null) {
          return bd.buffer.asUint8List();
        }
      } catch (_) {
        // Fall through cleanly to next delta or grid tile.
      } finally {
        outImage?.dispose();
        picture?.dispose();
        srcImage?.dispose();
        codec?.dispose();
      }
    }
    return null;
  }

  Future<Uint8List> _getOfflineGridTileBytes() async {
    final existing = _cachedGridTilePng;
    if (existing != null) return existing;

    ui.Picture? picture;
    ui.Image? image;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final bgPaint = ui.Paint()..color = const ui.Color(0xFFF1F5F9);
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 256, 256), bgPaint);

      final minorGrid = ui.Paint()
        ..color = const ui.Color(0xFFE2E8F0)
        ..strokeWidth = 1.0;
      for (double i = 64; i < 256; i += 64) {
        canvas.drawLine(ui.Offset(i, 0), ui.Offset(i, 256), minorGrid);
        canvas.drawLine(ui.Offset(0, i), ui.Offset(256, i), minorGrid);
      }

      final majorGrid = ui.Paint()
        ..color = const ui.Color(0xFFCBD5E1)
        ..strokeWidth = 1.2;
      canvas.drawLine(const ui.Offset(0, 0), const ui.Offset(256, 0), majorGrid);
      canvas.drawLine(const ui.Offset(0, 0), const ui.Offset(0, 256), majorGrid);

      picture = recorder.endRecording();
      image = await picture.toImage(256, 256);
      final bd = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bd != null) {
        final bytes = bd.buffer.asUint8List();
        _cachedGridTilePng = bytes;
        return bytes;
      }
    } catch (_) {
    } finally {
      image?.dispose();
      picture?.dispose();
    }
    return TileProvider.transparentImage;
  }

  /// Gently warms regional base tiles in background when online so brief offline
  /// drops still have overview road map coverage + parent tiles for deep zooms.
  Future<void> prewarmArea({
    required LatLng center,
    int minZoom = 12,
    int maxZoom = 14,
    int maxNewTiles = 36,
  }) async {
    if (!enableBackgroundPrewarm ||
        kIsWeb ||
        _disposed ||
        (isOfflineCheck?.call() ?? false)) {
      return;
    }
    final coords = <TileCoordinates>[];
    for (int z = minZoom; z <= maxZoom; z++) {
      final (cx, cy) = latLngToTile(center.latitude, center.longitude, z);
      final radius = z == minZoom ? 1 : 2;
      final n = 1 << z;
      for (int dx = -radius; dx <= radius; dx++) {
        for (int dy = -radius; dy <= radius; dy++) {
          final x = cx + dx;
          final y = cy + dy;
          if (x >= 0 && x < n && y >= 0 && y < n) {
            coords.add(TileCoordinates(x, y, z));
          }
        }
      }
    }
    await _prewarmTileList(coords, maxNewTiles: maxNewTiles);
  }

  /// Pre-caches tiles along a planned route polyline at street-level zoom so
  /// offline/tunnel sections along the trip remain mapped.
  Future<void> prewarmRoute(
    List<LatLng> routePoints, {
    int zoom = 15,
    int maxNewTiles = 28,
  }) async {
    if (!enableBackgroundPrewarm ||
        kIsWeb ||
        _disposed ||
        routePoints.isEmpty ||
        (isOfflineCheck?.call() ?? false)) {
      return;
    }
    final coords = <TileCoordinates>[];
    final seen = <String>{};
    for (int i = 0; i < routePoints.length; i++) {
      final pt = routePoints[i];
      for (final z in [zoom - 1, zoom]) {
        final (tx, ty) = latLngToTile(pt.latitude, pt.longitude, z);
        final key = normalizedTileKey(z, tx, ty);
        if (seen.add(key)) {
          coords.add(TileCoordinates(tx, ty, z));
        }
      }
    }
    await _prewarmTileList(coords, maxNewTiles: maxNewTiles);
  }

  Future<void> _prewarmTileList(
    List<TileCoordinates> coords, {
    required int maxNewTiles,
  }) async {
    int fetchedCount = 0;
    for (final c in coords) {
      if (_disposed ||
          fetchedCount >= maxNewTiles ||
          (isOfflineCheck?.call() ?? false)) {
        return;
      }
      final key = normalizedTileKey(c.z, c.x, c.y);
      if (!_prewarmRequestedKeys.add(key)) continue;
      final existing = await _readCachedTile(c.z, c.x, c.y);
      if (existing != null && existing.isFresh) continue;
      final primary =
          'https://mt${(c.x + c.y) & 3}.google.com/vt/lyrs=m&x=${c.x}&y=${c.y}&z=${c.z}';
      final bytes = await _fetchFromUrls(
        candidateUrls: candidateUrlsForTile(c, primary),
        abortTrigger: null,
        isAbortedCheck: () => _disposed || (isOfflineCheck?.call() ?? false),
      );
      if (bytes != null && !_disposed) {
        await _writeCachedTile(c.z, c.x, c.y, bytes);
        fetchedCount++;
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _networkSemaphore.cancelAll();
    _fallbackKeys.clear();
    _memoryTiles.clear();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    super.dispose();
  }
}

@immutable
class _ResilientTileImageProvider
    extends ImageProvider<_ResilientTileImageProvider> {
  const _ResilientTileImageProvider({
    required this.provider,
    required this.coordinates,
    required this.candidateUrls,
    required this.abortTrigger,
  });

  final ResilientTileProvider provider;
  final TileCoordinates coordinates;
  final List<String> candidateUrls;
  final Future<void>? abortTrigger;

  @override
  ImageStreamCompleter loadImage(
    _ResilientTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _decodeTile(key, decode)
        ..then(
          (_) => unawaited(chunkEvents.close()),
          onError: (_) => unawaited(chunkEvents.close()),
        ),
      chunkEvents: chunkEvents.stream,
      scale: 1,
      debugLabel: 'tile_${coordinates.z}_${coordinates.x}_${coordinates.y}',
    );
  }

  Future<ui.Codec> _decodeTile(
    _ResilientTileImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final result = await provider.loadTileBytes(
      coordinates: coordinates,
      candidateUrls: candidateUrls,
      abortTrigger: abortTrigger,
    );
    if (result.aborted) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    } else if (result.isFallback) {
      provider._recordFallbackKey(coordinates, key);
    } else {
      provider._clearFallbackKey(coordinates);
    }
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(result.bytes);
      return await decode(buffer);
    } catch (_) {
      // If cached/downloaded image failed native codec decode, serve offline grid
      // and mark key for retry on next reconnect rather than leaving a broken tile.
      provider._recordFallbackKey(coordinates, key);
      final gridBytes = await provider._getOfflineGridTileBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(gridBytes);
      return decode(buffer);
    }
  }

  @override
  SynchronousFuture<_ResilientTileImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _ResilientTileImageProvider &&
          identical(provider, other.provider) &&
          coordinates == other.coordinates);

  @override
  int get hashCode => Object.hash(identityHashCode(provider), coordinates);
}

class _AsyncSemaphore {
  _AsyncSemaphore(this.maxConcurrent);
  final int maxConcurrent;
  int _inFlight = 0;
  final Queue<Completer<bool>> _waiters = Queue();

  Future<bool> acquire({
    Future<void>? abortTrigger,
    required bool Function() isAbortedCheck,
  }) async {
    if (isAbortedCheck()) return false;
    if (_inFlight < maxConcurrent) {
      _inFlight++;
      return true;
    }
    final waiter = Completer<bool>();
    _waiters.addLast(waiter);
    unawaited(
      abortTrigger?.then((_) {
        if (!waiter.isCompleted) {
          _waiters.remove(waiter);
          waiter.complete(false);
        }
      }),
    );
    return waiter.future;
  }

  void release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.isCompleted) {
        next.complete(true);
        return;
      }
    }
    if (_inFlight > 0) {
      _inFlight--;
    }
  }

  void cancelAll() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.isCompleted) {
        next.complete(false);
      }
    }
  }
}

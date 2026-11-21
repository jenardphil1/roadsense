import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_flutter_app/resilient_tile_provider.dart';

Future<Uint8List> _createSolidPng(Color color, {int size = 256}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bd = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bd!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isValidTileImageBytes accepts raster images and rejects HTML/JSON', () async {
    final png = await _createSolidPng(const Color(0xFF2563EB), size: 32);
    expect(ResilientTileProvider.isValidTileImageBytes(png), isTrue);
    expect(
      ResilientTileProvider.isValidTileImageBytes(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(20, 0)]),
      ),
      isTrue,
    );
    expect(
      ResilientTileProvider.isValidTileImageBytes(
        Uint8List.fromList(utf8.encode('{}')),
      ),
      isFalse,
    );
    expect(
      ResilientTileProvider.isValidTileImageBytes(
        Uint8List.fromList(utf8.encode('<html><body>429 Too Many</body></html>')),
      ),
      isFalse,
    );
  });

  test(
    'normalizes disk cache across Google subdomains and serves stale tiles offline',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('roadsense_tiles_');
      addTearDown(() => tempDir.delete(recursive: true));

      final samplePng = await _createSolidPng(const Color(0xFF10B981), size: 32);
      int networkHits = 0;
      bool offline = false;

      final client = MockClient((request) async {
        networkHits++;
        if (offline) {
          throw const SocketException('No route to host');
        }
        return http.Response.bytes(samplePng, 200);
      });

      final provider = ResilientTileProvider(
        httpClient: client,
        cacheDirectoryPath: tempDir.path,
        freshAge: const Duration(days: 14),
        isOfflineCheck: () => offline,
        enableBackgroundPrewarm: false,
      );
      addTearDown(provider.dispose);

      const coords = TileCoordinates(13700, 7500, 14);

      // 1. Online fetch caches under normalized z/x_y regardless of subdomain.
      final first = await provider.loadTileBytes(
        coordinates: coords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          coords,
          'https://mt0.google.com/vt/lyrs=m&x=13700&y=7500&z=14',
        ),
      );
      expect(first.bytes, samplePng);
      expect(first.isFallback, isFalse);
      expect(networkHits, 1);

      // Wait for async disk write flush.
      await provider.flushPendingDiskWrites();

      // 2. Fresh provider instance reading from same disk cache with offline=true
      //    and different subdomain URL hits disk with 0 network calls.
      offline = true;
      final coldProvider = ResilientTileProvider(
        httpClient: client,
        cacheDirectoryPath: tempDir.path,
        freshAge: const Duration(days: 14),
        isOfflineCheck: () => offline,
        enableBackgroundPrewarm: false,
      );
      addTearDown(coldProvider.dispose);

      final cachedHit = await coldProvider.loadTileBytes(
        coordinates: coords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          coords,
          'https://mt2.google.com/vt/lyrs=m&x=13700&y=7500&z=14',
        ),
      );
      expect(cachedHit.bytes, samplePng);
      expect(cachedHit.isFallback, isFalse);
      expect(networkHits, 1);

      // 3. Even when cached tile exceeds freshAge, offline/failing network still
      //    falls back to stale cached bytes instead of returning blank.
      final zeroFreshProvider = ResilientTileProvider(
        httpClient: client,
        cacheDirectoryPath: tempDir.path,
        freshAge: Duration.zero,
        isOfflineCheck: () => offline,
        enableBackgroundPrewarm: false,
      );
      addTearDown(zeroFreshProvider.dispose);

      final staleOfflineHit = await zeroFreshProvider.loadTileBytes(
        coordinates: coords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          coords,
          'https://mt3.google.com/vt/lyrs=m&x=13700&y=7500&z=14',
        ),
      );
      expect(staleOfflineHit.bytes, samplePng);
      expect(staleOfflineHit.isFallback, isFalse);
      expect(networkHits, 1);

      // Even if marked online while network throws SocketException, stale bytes survive.
      offline = false;
      final failingClient = MockClient(
        (_) async => throw const SocketException('Timeout'),
      );
      final staleResilient = ResilientTileProvider(
        httpClient: failingClient,
        cacheDirectoryPath: tempDir.path,
        freshAge: Duration.zero,
        isOfflineCheck: () => false,
        enableBackgroundPrewarm: false,
      );
      addTearDown(staleResilient.dispose);
      final staleRecovered = await staleResilient.loadTileBytes(
        coordinates: coords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          coords,
          'https://mt1.google.com/vt/lyrs=m&x=13700&y=7500&z=14',
        ),
      );
      expect(staleRecovered.bytes, samplePng);
      expect(staleRecovered.isFallback, isFalse);
    },
  );

  test(
    'fails over across hosts on 429/invalid payload and upscales parent tile or grid when uncached offline',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('roadsense_failover_');
      addTearDown(() => tempDir.delete(recursive: true));

      final parentPng = await _createSolidPng(const Color(0xFF0EA5E9), size: 256);
      final mirrorPng = await _createSolidPng(const Color(0xFFF59E0B), size: 32);
      final attemptedHosts = <String>[];

      final client = MockClient((request) async {
        attemptedHosts.add(request.url.host);
        if (request.url.host.startsWith('mt') &&
            (request.url.queryParameters['x'] == '200' ||
             request.url.path.contains('x=200') ||
             request.url.toString().contains('x=200'))) {
          // Primary returns invalid JSON / rate limit on mirror failover test.
          return request.url.host == 'mt0.google.com'
              ? http.Response('{}', 200)
              : http.Response('rate limited', 429);
        }
        if (request.url.host == 'a.basemaps.cartocdn.com') {
          return http.Response.bytes(mirrorPng, 200);
        }
        return http.Response.bytes(parentPng, 200);
      });

      bool offline = false;
      final provider = ResilientTileProvider(
        httpClient: client,
        cacheDirectoryPath: tempDir.path,
        isOfflineCheck: () => offline,
        enableBackgroundPrewarm: false,
      );
      addTearDown(provider.dispose);

      // 1. Failover succeeds via CartoDB mirror when mt0 returns JSON {} and mt1 returns 429.
      const mirrorCoords = TileCoordinates(200, 300, 14);
      final mirrorResult = await provider.loadTileBytes(
        coordinates: mirrorCoords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          mirrorCoords,
          'https://mt0.google.com/vt/lyrs=m&x=200&y=300&z=14',
        ),
      );
      expect(mirrorResult.bytes, mirrorPng);
      expect(mirrorResult.isFallback, isFalse);
      expect(
        attemptedHosts,
        containsAll(['mt0.google.com', 'mt1.google.com', 'a.basemaps.cartocdn.com']),
      );

      // 2. Cache a z=14 parent tile, then go offline and request z=15 child tile.
      const parentCoords = TileCoordinates(100, 200, 14);
      final parentResult = await provider.loadTileBytes(
        coordinates: parentCoords,
        candidateUrls: const [
          'https://mt0.google.com/vt/lyrs=m&x=100&y=200&z=14',
        ],
      );
      expect(parentResult.isFallback, isFalse);
      await provider.flushPendingDiskWrites();

      offline = true;
      const childCoords = TileCoordinates(200, 401, 15);
      final upscaledChild = await provider.loadTileBytes(
        coordinates: childCoords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          childCoords,
          'https://mt0.google.com/vt/lyrs=m&x=200&y=401&z=15',
        ),
      );
      expect(upscaledChild.isFallback, isTrue);
      expect(ResilientTileProvider.isValidTileImageBytes(upscaledChild.bytes), isTrue);
      // Must NOT persist ancestor fallback as a real z=15 tile on disk.
      expect(
        File('${tempDir.path}/v1/15/200_401.tile').existsSync(),
        isFalse,
      );

      // 3. Totally uncached region while offline serves clean grid tile & never persists it.
      const remoteCoords = TileCoordinates(999, 999, 14);
      final gridResult = await provider.loadTileBytes(
        coordinates: remoteCoords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          remoteCoords,
          'https://mt0.google.com/vt/lyrs=m&x=999&y=999&z=14',
        ),
      );
      expect(gridResult.isFallback, isTrue);
      expect(ResilientTileProvider.isValidTileImageBytes(gridResult.bytes), isTrue);
      expect(
        File('${tempDir.path}/v1/14/999_999.tile').existsSync(),
        isFalse,
      );

      // 4. When back online, newly requested tiles load real bytes and are not fallbacks.
      offline = false;
      final recoveredOnline = await provider.loadTileBytes(
        coordinates: remoteCoords,
        candidateUrls: ResilientTileProvider.candidateUrlsForTile(
          remoteCoords,
          'https://mt0.google.com/vt/lyrs=m&x=999&y=999&z=14',
        ),
      );
      expect(recoveredOnline.isFallback, isFalse);
      expect(recoveredOnline.bytes, parentPng);
      await provider.flushPendingDiskWrites();
      expect(
        File('${tempDir.path}/v1/14/999_999.tile').existsSync(),
        isTrue,
      );
    },
  );
}

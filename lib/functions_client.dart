import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

/// Structured error returned by Firebase v2 `onCall` endpoints or network calls.
class FirebaseCallableException implements Exception {
  final String code;
  final String reason;
  final String message;
  final int? httpStatus;
  final Map<String, dynamic> details;
  final bool isNetworkError;

  const FirebaseCallableException({
    required this.code,
    required this.reason,
    required this.message,
    this.httpStatus,
    this.details = const {},
    this.isNetworkError = false,
  });

  @override
  String toString() => message;
}

/// Minimal shared client for invoking Firebase Cloud Functions v2 `onCall`
/// endpoints with a Firebase ID token over HTTP, including local emulator/bridge
/// resolution in debug and web dev builds.
class FirebaseFunctionsClient {
  static const String _emulatorHost = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
  );
  static const String _functionsEmulatorHost = String.fromEnvironment(
    'FUNCTIONS_EMULATOR_HOST',
  );
  static const String _functionsBaseUrl = String.fromEnvironment(
    'FUNCTIONS_BASE_URL',
  );
  static const String _uploadFunctionsBaseUrl = String.fromEnvironment(
    'UPLOAD_FUNCTIONS_BASE_URL',
  );

  final http.Client _httpClient;
  final bool hasCustomHttpClient;
  final Future<String?> Function()? _idTokenProvider;
  final Map<String, DateTime> _unreachableProbeUntil = {};

  FirebaseFunctionsClient({
    http.Client? httpClient,
    Future<String?> Function()? idTokenProvider,
  }) : hasCustomHttpClient = httpClient != null,
       _httpClient = httpClient ?? http.Client(),
       _idTokenProvider = idTokenProvider;

  bool _isImplicitLocalProbe(Uri uri) =>
      _functionsBaseUrl.isEmpty &&
      _functionsEmulatorHost.isEmpty &&
      _emulatorHost.isEmpty &&
      !hasCustomHttpClient &&
      uri.scheme == 'http';

  List<Uri> candidateEndpointUris(String functionName) {
    if (functionName == 'issueReportUploadUrl' &&
        _uploadFunctionsBaseUrl.isNotEmpty) {
      final base = _uploadFunctionsBaseUrl.replaceFirst(RegExp(r'/+$'), '');
      return [Uri.parse('$base/$functionName')];
    }
    if (_functionsBaseUrl.isNotEmpty) {
      final base = _functionsBaseUrl.endsWith('/')
          ? _functionsBaseUrl.substring(0, _functionsBaseUrl.length - 1)
          : _functionsBaseUrl;
      return [Uri.parse('$base/$functionName')];
    }
    final emulatorHost = _functionsEmulatorHost.isNotEmpty
        ? _functionsEmulatorHost
        : _emulatorHost;
    if (emulatorHost.isNotEmpty) {
      final projectId = Firebase.apps.isNotEmpty
          ? Firebase.app().options.projectId
          : 'demo-roadsense-qa';
      return [
        Uri.parse(
          'http://$emulatorHost:5001/$projectId/us-central1/$functionName',
        ),
      ];
    }
    final projectId = Firebase.apps.isNotEmpty
        ? Firebase.app().options.projectId
        : DefaultFirebaseOptions.currentPlatform.projectId;
    final cloudUri = Uri.parse(
      'https://us-central1-$projectId.cloudfunctions.net/$functionName',
    );
    if (hasCustomHttpClient) {
      return [cloudUri];
    }

    final localUris = <Uri>[];
    void addLocal(String url) {
      final parsed = Uri.parse(url);
      if (!localUris.contains(parsed)) {
        localUris.add(parsed);
      }
    }

    if (kIsWeb) {
      final host = Uri.base.host.trim();
      if (host == 'localhost' || host == '127.0.0.1') {
        addLocal('http://$host:5001/$projectId/us-central1/$functionName');
      }
      addLocal('http://127.0.0.1:5001/$projectId/us-central1/$functionName');
      addLocal('http://localhost:5001/$projectId/us-central1/$functionName');
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      addLocal('http://10.0.2.2:5001/$projectId/us-central1/$functionName');
      addLocal('http://127.0.0.1:5001/$projectId/us-central1/$functionName');
      addLocal('http://localhost:5001/$projectId/us-central1/$functionName');
    } else {
      addLocal('http://127.0.0.1:5001/$projectId/us-central1/$functionName');
      addLocal('http://localhost:5001/$projectId/us-central1/$functionName');
    }

    final isLocalHostWeb =
        kIsWeb &&
        (Uri.base.host == 'localhost' || Uri.base.host == '127.0.0.1');
    if (kDebugMode || isLocalHostWeb) {
      return [...localUris, cloudUri];
    }
    return [cloudUri, ...localUris];
  }

  Future<String> _resolveIdToken() async {
    if (_idTokenProvider != null) {
      final token = await _idTokenProvider();
      if (token == null || token.isEmpty) {
        throw const FirebaseCallableException(
          code: 'unauthenticated',
          reason: 'unauthenticated',
          message: 'Authentication session expired. Please sign in again.',
        );
      }
      return token;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const FirebaseCallableException(
        code: 'unauthenticated',
        reason: 'unauthenticated',
        message: 'Sign in first before calling backend services.',
      );
    }

    final String? idToken;
    try {
      idToken = await user.getIdToken();
    } catch (_) {
      throw const FirebaseCallableException(
        code: 'network',
        reason: 'network',
        message: 'Connection error while refreshing session. Try again.',
        isNetworkError: true,
      );
    }

    if (idToken == null || idToken.isEmpty) {
      throw const FirebaseCallableException(
        code: 'unauthenticated',
        reason: 'unauthenticated',
        message: 'Authentication session expired. Please sign in again.',
      );
    }
    return idToken;
  }

  Future<Map<String, dynamic>> call(
    String name, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 20),
    String fallbackErrorMessage = 'Unable to complete backend request.',
  }) async {
    final idToken = await _resolveIdToken();
    final uris = candidateEndpointUris(name);

    http.Response? response;
    Map<String, dynamic> decoded = const {};

    for (var i = 0; i < uris.length; i++) {
      final uri = uris[i];
      final hasMore = i < uris.length - 1;
      final isProbe = hasMore && _isImplicitLocalProbe(uri);
      final now = DateTime.now();
      final skipUntil = isProbe ? _unreachableProbeUntil[uri.host] : null;
      if (skipUntil != null && now.isBefore(skipUntil)) {
        continue;
      }
      final attemptTimeout = isProbe
          ? const Duration(milliseconds: 1000)
          : timeout;
      try {
        final candidateResponse = await _httpClient
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $idToken',
              },
              body: jsonEncode({'data': data}),
            )
            .timeout(attemptTimeout);

        Map<String, dynamic> candidateDecoded = const {};
        try {
          final raw = jsonDecode(candidateResponse.body);
          if (raw is Map<String, dynamic>) {
            candidateDecoded = raw;
          }
        } catch (_) {}

        if (candidateResponse.statusCode == 404 &&
            candidateDecoded['error'] is! Map &&
            hasMore) {
          continue;
        }

        response = candidateResponse;
        decoded = candidateDecoded;
        break;
      } on TimeoutException {
        if (isProbe) {
          _unreachableProbeUntil[uri.host] = now.add(
            const Duration(seconds: 60),
          );
        }
        if (!hasMore) {
          throw const FirebaseCallableException(
            code: 'network',
            reason: 'network',
            message: 'Request timed out. Check your connection and try again.',
            isNetworkError: true,
          );
        }
      } catch (_) {
        if (isProbe) {
          _unreachableProbeUntil[uri.host] = now.add(
            const Duration(seconds: 60),
          );
        }
        if (!hasMore) {
          throw const FirebaseCallableException(
            code: 'network',
            reason: 'network',
            message:
                'Connection error. Check your internet connection and try again.',
            isNetworkError: true,
          );
        }
      }
    }

    if (response == null) {
      throw const FirebaseCallableException(
        code: 'network',
        reason: 'network',
        message:
            'Connection error. Check your internet connection and try again.',
        isNetworkError: true,
      );
    }

    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        decoded['error'] == null) {
      final result = decoded['result'];
      if (result is Map<String, dynamic>) {
        return result;
      }
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return const {};
    }

    final errObj = decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = errObj['details'] is Map
        ? Map<String, dynamic>.from(errObj['details'] as Map)
        : const <String, dynamic>{};

    final isBareNotFound = response.statusCode == 404 && errObj.isEmpty;
    final status = isBareNotFound
        ? 'not-found'
        : ((errObj['status'] as String?) ?? 'unknown');
    final reason = isBareNotFound
        ? 'not-deployed'
        : ((details['reason'] as String?) ?? status.toLowerCase());
    final message = (errObj['message'] as String?)?.trim().isNotEmpty == true
        ? (errObj['message'] as String).trim()
        : '$fallbackErrorMessage (HTTP ${response.statusCode}).';

    throw FirebaseCallableException(
      code: status,
      reason: reason,
      message: message,
      httpStatus: response.statusCode,
      details: details,
    );
  }
}

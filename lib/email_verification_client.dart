import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'functions_client.dart';

/// Masks an email address for UI display while keeping its domain recognizable.
String maskEmailAddress(String email) {
  final raw = email.trim();
  final atIndex = raw.indexOf('@');
  if (atIndex <= 0) return '***';
  final local = raw.substring(0, atIndex);
  final domain = raw.substring(atIndex + 1).toLowerCase();
  if (domain.isEmpty) return '***';

  final String maskedLocal;
  if (local.length <= 1) {
    maskedLocal = '*';
  } else if (local.length == 2) {
    maskedLocal = '${local[0]}*';
  } else if (local.length <= 4) {
    maskedLocal =
        '${local[0]}${'*' * (local.length - 2)}${local[local.length - 1]}';
  } else {
    final stars = (local.length - 3).clamp(2, 5);
    maskedLocal =
        '${local.substring(0, 2)}${'*' * stars}${local[local.length - 1]}';
  }
  return '$maskedLocal@$domain';
}

/// Structured exception thrown by backend verification endpoints or network calls.
class EmailVerificationException implements Exception {
  final String code;
  final String reason;
  final String message;
  final int? attemptsRemaining;
  final int? cooldownSeconds;
  final int? cooldownUntilMs;
  final int? expiresAtMs;
  final bool isNetworkError;

  const EmailVerificationException({
    required this.code,
    required this.reason,
    required this.message,
    this.attemptsRemaining,
    this.cooldownSeconds,
    this.cooldownUntilMs,
    this.expiresAtMs,
    this.isNetworkError = false,
  });

  @override
  String toString() => message;
}

/// Server-backed state for a pending or verified registration email flow.
class EmailVerificationStatus {
  final bool verified;
  final String maskedEmail;
  final bool hasActiveCode;
  final bool isExpired;
  final int expiresAtMs;
  final int cooldownUntilMs;
  final int attemptsRemaining;
  final bool isLockedOut;
  final bool sendLimitReached;
  final int sendsInWindow;
  final int maxSendsPerWindow;
  final int ttlMinutes;
  final bool usesEmailLinkFallback;
  final String? devPreviewCode;

  const EmailVerificationStatus({
    required this.verified,
    required this.maskedEmail,
    required this.hasActiveCode,
    required this.isExpired,
    required this.expiresAtMs,
    required this.cooldownUntilMs,
    required this.attemptsRemaining,
    required this.isLockedOut,
    required this.sendLimitReached,
    required this.sendsInWindow,
    required this.maxSendsPerWindow,
    required this.ttlMinutes,
    this.usesEmailLinkFallback = false,
    this.devPreviewCode,
  });

  factory EmailVerificationStatus.fromJson(
    Map<String, dynamic> json, {
    String fallbackEmail = '',
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cooldownSec = (json['cooldownSeconds'] as num?)?.toInt();
    final expiresInSec = (json['expiresInSeconds'] as num?)?.toInt();

    final cooldownUntil =
        (json['cooldownUntilMs'] as num?)?.toInt() ??
        (cooldownSec != null && cooldownSec > 0
            ? nowMs + cooldownSec * 1000
            : 0);
    final expiresAt =
        (json['expiresAtMs'] as num?)?.toInt() ??
        (expiresInSec != null && expiresInSec > 0
            ? nowMs + expiresInSec * 1000
            : 0);

    final verified =
        (json['verified'] as bool?) ??
        (json['alreadyVerified'] as bool?) ??
        false;
    final sent = (json['sent'] as bool?) ?? false;
    final rawPreview = (json['devPreviewCode'] as String?)?.trim();

    return EmailVerificationStatus(
      verified: verified,
      maskedEmail: (json['maskedEmail'] as String?)?.trim().isNotEmpty == true
          ? (json['maskedEmail'] as String).trim()
          : maskEmailAddress(fallbackEmail),
      hasActiveCode:
          (json['hasActiveCode'] as bool?) ??
          (sent && !verified && expiresAt > nowMs),
      isExpired: (json['isExpired'] as bool?) ?? false,
      expiresAtMs: expiresAt,
      cooldownUntilMs: cooldownUntil,
      attemptsRemaining: (json['attemptsRemaining'] as num?)?.toInt() ?? 5,
      isLockedOut: (json['isLockedOut'] as bool?) ?? false,
      sendLimitReached: (json['sendLimitReached'] as bool?) ?? false,
      sendsInWindow: (json['sendsInWindow'] as num?)?.toInt() ?? 0,
      maxSendsPerWindow: (json['maxSendsPerWindow'] as num?)?.toInt() ?? 5,
      ttlMinutes: (json['ttlMinutes'] as num?)?.toInt() ?? 10,
      usesEmailLinkFallback: (json['usesEmailLinkFallback'] as bool?) ?? false,
      devPreviewCode: (rawPreview != null && rawPreview.isNotEmpty)
          ? rawPreview
          : null,
    );
  }

  EmailVerificationStatus copyWith({
    bool? verified,
    String? maskedEmail,
    bool? hasActiveCode,
    bool? isExpired,
    int? expiresAtMs,
    int? cooldownUntilMs,
    int? attemptsRemaining,
    bool? isLockedOut,
    bool? sendLimitReached,
    int? sendsInWindow,
    int? maxSendsPerWindow,
    int? ttlMinutes,
    bool? usesEmailLinkFallback,
    String? devPreviewCode,
  }) {
    return EmailVerificationStatus(
      verified: verified ?? this.verified,
      maskedEmail: maskedEmail ?? this.maskedEmail,
      hasActiveCode: hasActiveCode ?? this.hasActiveCode,
      isExpired: isExpired ?? this.isExpired,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
      cooldownUntilMs: cooldownUntilMs ?? this.cooldownUntilMs,
      attemptsRemaining: attemptsRemaining ?? this.attemptsRemaining,
      isLockedOut: isLockedOut ?? this.isLockedOut,
      sendLimitReached: sendLimitReached ?? this.sendLimitReached,
      sendsInWindow: sendsInWindow ?? this.sendsInWindow,
      maxSendsPerWindow: maxSendsPerWindow ?? this.maxSendsPerWindow,
      ttlMinutes: ttlMinutes ?? this.ttlMinutes,
      usesEmailLinkFallback:
          usesEmailLinkFallback ?? this.usesEmailLinkFallback,
      devPreviewCode: devPreviewCode ?? this.devPreviewCode,
    );
  }

  int remainingCooldownSeconds([DateTime? now]) {
    if (cooldownUntilMs <= 0) return 0;
    final ref = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (cooldownUntilMs <= ref) return 0;
    return ((cooldownUntilMs - ref) / 1000).ceil();
  }

  int remainingExpirySeconds([DateTime? now]) {
    if (expiresAtMs <= 0) return 0;
    final ref = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (expiresAtMs <= ref) return 0;
    return ((expiresAtMs - ref) / 1000).ceil();
  }
}

/// Strips non-digits on typing or paste (e.g. `"  004 219  "` -> `"004219"`)
/// while preserving leading zeros and capping length to 6 digits.
class DigitsPasteInputFormatter extends TextInputFormatter {
  final int maxLength;

  const DigitsPasteInputFormatter({this.maxLength = 6});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final clamped = digitsOnly.length > maxLength
        ? digitsOnly.substring(0, maxLength)
        : digitsOnly;
    return TextEditingValue(
      text: clamped,
      selection: TextSelection.collapsed(offset: clamped.length),
    );
  }
}

/// Abstraction for communicating with the backend verification service.
abstract class EmailVerificationBackend {
  Future<EmailVerificationStatus> getStatus();
  Future<EmailVerificationStatus> sendCode();
  Future<bool> verifyCode(String code);
  Future<EmailVerificationStatus> updatePendingEmail(String newEmail);
  Future<void> signOut();
}

class _SparkFallbackSession {
  String email;
  int cooldownUntilMs = 0;
  int expiresAtMs = 0;
  int sendsInWindow = 0;
  bool hasSentEmailLink = false;

  _SparkFallbackSession(this.email);
}

/// Production & Firebase-Emulator backend calling v2 Cloud Functions `onCall`
/// endpoints with the user's Firebase ID token, with automatic Firebase Spark
/// (free-plan) email-link fallback when Cloud Functions are unavailable.
class FirebaseEmailVerificationBackend implements EmailVerificationBackend {
  static final Map<String, _SparkFallbackSession> _sparkSessions = {};

  final FirebaseFunctionsClient _functionsClient;
  bool get _hasCustomHttpClient => _functionsClient.hasCustomHttpClient;

  FirebaseEmailVerificationBackend({http.Client? httpClient})
    : _functionsClient = FirebaseFunctionsClient(httpClient: httpClient);

  User _requireUser() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const EmailVerificationException(
        code: 'unauthenticated',
        reason: 'unauthenticated',
        message: 'Sign in first to verify your email address.',
      );
    }
    return user;
  }

  Future<Map<String, dynamic>> _callFunction(
    String name, {
    Map<String, dynamic> data = const {},
  }) async {
    _requireUser();
    try {
      return await _functionsClient.call(
        name,
        data: data,
        fallbackErrorMessage: 'Unable to complete verification',
      );
    } on FirebaseCallableException catch (e) {
      throw EmailVerificationException(
        code: e.code,
        reason: e.reason,
        message: e.message,
        attemptsRemaining: (e.details['attemptsRemaining'] as num?)?.toInt(),
        cooldownSeconds: (e.details['cooldownSeconds'] as num?)?.toInt(),
        cooldownUntilMs: (e.details['cooldownUntilMs'] as num?)?.toInt(),
        expiresAtMs: (e.details['expiresAtMs'] as num?)?.toInt(),
        isNetworkError: e.isNetworkError,
      );
    }
  }

  bool _shouldUseSparkFallback(EmailVerificationException e) =>
      !_hasCustomHttpClient && (e.isNetworkError || e.reason == 'not-deployed');

  _SparkFallbackSession _sessionForUser(User user) {
    final existing = _sparkSessions[user.uid];
    final currentEmail = user.email ?? '';
    if (existing != null) {
      if (currentEmail.isNotEmpty) {
        existing.email = currentEmail;
      }
      return existing;
    }
    final created = _SparkFallbackSession(currentEmail);
    _sparkSessions[user.uid] = created;
    return created;
  }

  EmailVerificationStatus _verifiedStatus(
    String email, {
    bool usesEmailLinkFallback = false,
  }) {
    return EmailVerificationStatus(
      verified: true,
      maskedEmail: maskEmailAddress(email),
      hasActiveCode: false,
      isExpired: false,
      expiresAtMs: 0,
      cooldownUntilMs: 0,
      attemptsRemaining: 5,
      isLockedOut: false,
      sendLimitReached: false,
      sendsInWindow: 0,
      maxSendsPerWindow: 5,
      ttlMinutes: 10,
      usesEmailLinkFallback: usesEmailLinkFallback,
    );
  }

  Future<bool> _refreshAuthSession() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.getIdToken(true);
    await user.reload();
    final reloaded = FirebaseAuth.instance.currentUser;
    await reloaded?.getIdToken(true);
    return reloaded?.emailVerified == true;
  }

  Future<bool> _checkNativeEmailVerified() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
    } catch (_) {}
    final reloaded = FirebaseAuth.instance.currentUser;
    if (reloaded?.emailVerified == true) {
      try {
        await reloaded?.getIdToken(true);
      } catch (_) {}
      return true;
    }
    return false;
  }

  Future<void> _sendNativeFirebaseVerificationEmail(User user) async {
    try {
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'too-many-requests') {
        return;
      }
      throw EmailVerificationException(
        code: e.code,
        reason: e.code,
        message: e.message ?? 'Could not send verification email right now.',
      );
    }
  }

  Future<EmailVerificationStatus> _sparkFallbackGetStatus(User user) async {
    if (await _checkNativeEmailVerified()) {
      final current = FirebaseAuth.instance.currentUser ?? user;
      return _verifiedStatus(current.email ?? '', usesEmailLinkFallback: true);
    }
    final session = _sessionForUser(user);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final hasActive = session.hasSentEmailLink && session.expiresAtMs > nowMs;
    return EmailVerificationStatus(
      verified: false,
      maskedEmail: maskEmailAddress(session.email),
      hasActiveCode: hasActive,
      isExpired: session.hasSentEmailLink && !hasActive,
      expiresAtMs: session.expiresAtMs,
      cooldownUntilMs: session.cooldownUntilMs,
      attemptsRemaining: 5,
      isLockedOut: false,
      sendLimitReached: session.sendsInWindow >= 5,
      sendsInWindow: session.sendsInWindow,
      maxSendsPerWindow: 5,
      ttlMinutes: 10,
      usesEmailLinkFallback: true,
    );
  }

  Future<EmailVerificationStatus> _sparkFallbackSendCode(User user) async {
    if (await _checkNativeEmailVerified()) {
      final current = FirebaseAuth.instance.currentUser ?? user;
      return _verifiedStatus(current.email ?? '', usesEmailLinkFallback: true);
    }
    final session = _sessionForUser(user);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (session.cooldownUntilMs > nowMs) {
      final cooldownSec = ((session.cooldownUntilMs - nowMs) / 1000).ceil();
      throw EmailVerificationException(
        code: 'resource-exhausted',
        reason: 'cooldown',
        message:
            'Please wait ${cooldownSec}s before requesting another verification email.',
        cooldownSeconds: cooldownSec,
        cooldownUntilMs: session.cooldownUntilMs,
        expiresAtMs: session.expiresAtMs,
      );
    }
    if (session.sendsInWindow >= 5) {
      throw const EmailVerificationException(
        code: 'resource-exhausted',
        reason: 'rate-limited',
        message:
            'Maximum verification emails requested for now. Please try again later.',
      );
    }

    await _sendNativeFirebaseVerificationEmail(user);
    session.hasSentEmailLink = true;
    session.sendsInWindow += 1;
    session.cooldownUntilMs = nowMs + 60000;
    session.expiresAtMs = nowMs + 600000;

    return EmailVerificationStatus(
      verified: false,
      maskedEmail: maskEmailAddress(session.email),
      hasActiveCode: true,
      isExpired: false,
      expiresAtMs: session.expiresAtMs,
      cooldownUntilMs: session.cooldownUntilMs,
      attemptsRemaining: 5,
      isLockedOut: false,
      sendLimitReached: session.sendsInWindow >= 5,
      sendsInWindow: session.sendsInWindow,
      maxSendsPerWindow: 5,
      ttlMinutes: 10,
      usesEmailLinkFallback: true,
    );
  }

  Future<EmailVerificationStatus> _sparkFallbackUpdatePendingEmail(
    User user,
    String trimmedEmail,
  ) async {
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(trimmedEmail)) {
      throw const EmailVerificationException(
        code: 'invalid-argument',
        reason: 'invalid-email',
        message: 'Enter a valid email address.',
      );
    }
    if (trimmedEmail.toLowerCase() == (user.email ?? '').trim().toLowerCase()) {
      throw const EmailVerificationException(
        code: 'invalid-argument',
        reason: 'same-email',
        message: 'Enter a different email address.',
      );
    }

    try {
      await user.verifyBeforeUpdateEmail(trimmedEmail);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        throw const EmailVerificationException(
          code: 'already-exists',
          reason: 'email-in-use',
          message:
              'That email address is already associated with another account.',
        );
      }
      if (e.code == 'invalid-email') {
        throw const EmailVerificationException(
          code: 'invalid-argument',
          reason: 'invalid-email',
          message: 'Enter a valid email address.',
        );
      }
      if (e.code == 'requires-recent-login') {
        throw const EmailVerificationException(
          code: 'requires-recent-login',
          reason: 'reauth-required',
          message: 'Sign out and sign back in to update your email address.',
        );
      }
      if (e.code != 'too-many-requests') {
        throw EmailVerificationException(
          code: e.code,
          reason: e.code,
          message: e.message ?? 'Could not update email address right now.',
        );
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final session = _sessionForUser(user);
    session.email = trimmedEmail;
    session.hasSentEmailLink = true;
    session.sendsInWindow = (session.sendsInWindow + 1).clamp(1, 5);
    session.cooldownUntilMs = nowMs + 60000;
    session.expiresAtMs = nowMs + 600000;

    return EmailVerificationStatus(
      verified: false,
      maskedEmail: maskEmailAddress(trimmedEmail),
      hasActiveCode: true,
      isExpired: false,
      expiresAtMs: session.expiresAtMs,
      cooldownUntilMs: session.cooldownUntilMs,
      attemptsRemaining: 5,
      isLockedOut: false,
      sendLimitReached: session.sendsInWindow >= 5,
      sendsInWindow: session.sendsInWindow,
      maxSendsPerWindow: 5,
      ttlMinutes: 10,
      usesEmailLinkFallback: true,
    );
  }

  @override
  Future<EmailVerificationStatus> getStatus() async {
    final user = _requireUser();
    if (!_hasCustomHttpClient) {
      return _sparkFallbackGetStatus(user);
    }
    try {
      final result = await _callFunction('getVerificationStatus');
      final status = EmailVerificationStatus.fromJson(
        result,
        fallbackEmail: user.email ?? '',
      );
      if (status.verified && !user.emailVerified) {
        await _refreshAuthSession();
      } else if (!status.verified &&
          result['deliveryMode'] == 'emulator_sink') {
        final session = _sessionForUser(user);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (!session.hasSentEmailLink && nowMs >= session.cooldownUntilMs) {
          session.hasSentEmailLink = true;
          session.cooldownUntilMs = nowMs + 60000;
          try {
            await _sendNativeFirebaseVerificationEmail(user);
          } catch (_) {}
        }
      }
      return status;
    } on EmailVerificationException catch (e) {
      if (_shouldUseSparkFallback(e)) {
        return _sparkFallbackGetStatus(user);
      }
      rethrow;
    }
  }

  @override
  Future<EmailVerificationStatus> sendCode() async {
    final user = _requireUser();
    if (!_hasCustomHttpClient) {
      return _sparkFallbackSendCode(user);
    }
    try {
      final result = await _callFunction('sendVerificationCode');
      final status = EmailVerificationStatus.fromJson(
        result,
        fallbackEmail: user.email ?? '',
      );
      if (status.verified && !user.emailVerified) {
        await _refreshAuthSession();
      } else if (!status.verified &&
          result['deliveryMode'] == 'emulator_sink') {
        final session = _sessionForUser(user);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        session.hasSentEmailLink = true;
        session.cooldownUntilMs = nowMs + 60000;
        try {
          await _sendNativeFirebaseVerificationEmail(user);
        } catch (_) {}
      }
      return status;
    } on EmailVerificationException catch (e) {
      if (_shouldUseSparkFallback(e)) {
        return _sparkFallbackSendCode(user);
      }
      rethrow;
    }
  }

  @override
  Future<bool> verifyCode(String code) async {
    if (!_hasCustomHttpClient) {
      if (await _refreshAuthSession()) {
        return true;
      }
      throw const EmailVerificationException(
        code: 'failed-precondition',
        reason: 'link-not-clicked',
        message:
            'Click the verification link sent to your email inbox (check Spam/Junk), then tap Verify.',
      );
    }
    final normalized = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(normalized)) {
      throw const EmailVerificationException(
        code: 'invalid-argument',
        reason: 'invalid-format',
        message: 'Enter the 6-digit code sent to your email.',
      );
    }
    try {
      final result = await _callFunction(
        'verifyEmailCode',
        data: {'code': normalized},
      );
      if (result['verified'] == true) {
        return await _refreshAuthSession();
      }
      return false;
    } on EmailVerificationException catch (e) {
      if (_shouldUseSparkFallback(e)) {
        if (await _refreshAuthSession()) {
          return true;
        }
        throw const EmailVerificationException(
          code: 'failed-precondition',
          reason: 'link-not-clicked',
          message:
              'Click the verification link sent to your email inbox (check Spam/Junk), then tap Verify.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<EmailVerificationStatus> updatePendingEmail(String newEmail) async {
    final user = _requireUser();
    final trimmed = newEmail.trim();
    if (!_hasCustomHttpClient) {
      return _sparkFallbackUpdatePendingEmail(user, trimmed);
    }
    final Map<String, dynamic> result;
    try {
      result = await _callFunction(
        'updatePendingEmail',
        data: {'newEmail': trimmed},
      );
    } on EmailVerificationException catch (e) {
      if (_shouldUseSparkFallback(e)) {
        return _sparkFallbackUpdatePendingEmail(user, trimmed);
      }
      rethrow;
    }
    final customToken = result['customToken'] as String?;
    if (customToken != null && customToken.isNotEmpty) {
      await FirebaseAuth.instance.signInWithCustomToken(customToken);
    }
    try {
      await FirebaseAuth.instance.currentUser?.reload();
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-token-expired' || e.code == 'user-disabled') {
        await FirebaseAuth.instance.signOut();
        throw EmailVerificationException(
          code: 'requires-recent-login',
          reason: 'reauth-required',
          message:
              'Email updated to ${maskEmailAddress(trimmed)}. Sign in with that address to enter the new 6-digit code.',
        );
      }
      rethrow;
    }
    return EmailVerificationStatus.fromJson(result, fallbackEmail: trimmed);
  }

  @override
  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
  }
}

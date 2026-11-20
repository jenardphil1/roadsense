import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;
import 'functions_client.dart';

/// Actionable failure buckets surfaced in My Reports and submission feedback.
enum ReportUploadErrorCategory {
  connectivity,
  missingConfiguration,
  authentication,
  permission,
  missingImage,
  server;

  static ReportUploadErrorCategory? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  String get title {
    switch (this) {
      case ReportUploadErrorCategory.connectivity:
        return 'No connection';
      case ReportUploadErrorCategory.missingConfiguration:
        return 'Upload service unavailable';
      case ReportUploadErrorCategory.authentication:
        return 'Sign-in required';
      case ReportUploadErrorCategory.permission:
        return 'Permission required';
      case ReportUploadErrorCategory.missingImage:
        return 'Photo missing';
      case ReportUploadErrorCategory.server:
        return 'Upload error';
    }
  }

  bool get canRetryByDefault => this != ReportUploadErrorCategory.missingImage;
}

/// Strips SAS query signatures, Azure account keys, and bearer tokens from text
/// before persisting to local disk or displaying in the UI.
String sanitizeUploadErrorMessage(String raw) {
  var cleaned = raw.trim();
  if (cleaned.isEmpty) {
    return 'Unable to finish submitting report.';
  }
  // Redact URL query strings (which could carry SAS tokens).
  cleaned = cleaned.replaceAllMapped(
    RegExp(r'(https?:\/\/[^\s?#]+)\?[^\s]*', caseSensitive: false),
    (m) => '${m.group(1)}?[redacted]',
  );
  // Redact key=value pairs for connection strings and SAS query fragments.
  cleaned = cleaned.replaceAll(
    RegExp(
      r'(AccountKey|SharedAccessSignature|sig)\s*=\s*[^;\s&]+',
      caseSensitive: false,
    ),
    r'$1=[redacted]',
  );
  cleaned = cleaned.replaceAll(
    RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
    'Bearer [redacted]',
  );
  if (cleaned.length > 220) {
    cleaned = '${cleaned.substring(0, 217)}...';
  }
  return cleaned;
}

/// Structured exception with category and credential-free user-facing copy.
class ReportUploadException implements Exception {
  final ReportUploadErrorCategory category;
  final String message;

  ReportUploadException({required this.category, required String message})
    : message = sanitizeUploadErrorMessage(message);

  @override
  String toString() => message;
}

/// Converts low-level network, auth, callable, and storage errors into a safe,
/// categorized [ReportUploadException].
ReportUploadException classifyUploadError(Object error) {
  if (error is ReportUploadException) {
    return error;
  }

  if (error is FirebaseCallableException) {
    final lowerCode = error.code.toLowerCase();
    final lowerReason = error.reason.toLowerCase();
    if (error.isNetworkError || lowerReason == 'network') {
      return ReportUploadException(
        category: ReportUploadErrorCategory.connectivity,
        message:
            'Could not reach upload service. Check your connection and retry.',
      );
    }
    if (lowerReason == 'upload-not-configured' ||
        lowerReason == 'not-deployed' ||
        (lowerCode == 'not-found' && (error.httpStatus == 404)) ||
        (lowerCode == 'failed-precondition' &&
            lowerReason != 'email-not-verified')) {
      return ReportUploadException(
        category: ReportUploadErrorCategory.missingConfiguration,
        message:
            'Image upload backend is not configured or deployed yet. Saved locally on this device.',
      );
    }
    if (lowerCode == 'unauthenticated' ||
        lowerReason == 'unauthenticated' ||
        lowerReason == 'user-not-found') {
      return ReportUploadException(
        category: ReportUploadErrorCategory.authentication,
        message: 'Your session expired. Sign in again to upload this report.',
      );
    }
    if (lowerReason == 'email-not-verified') {
      return ReportUploadException(
        category: ReportUploadErrorCategory.permission,
        message: 'Verify your email address before uploading report photos.',
      );
    }
    if (lowerCode == 'permission-denied' ||
        lowerReason == 'account-disabled' ||
        lowerReason == 'report-owner-mismatch') {
      return ReportUploadException(
        category: ReportUploadErrorCategory.permission,
        message: error.message,
      );
    }
    return ReportUploadException(
      category: ReportUploadErrorCategory.server,
      message: error.message,
    );
  }

  if (error is FirebaseException) {
    final code = error.code.toLowerCase();
    final msgLower = (error.message ?? '').toLowerCase();
    if (code == 'unauthenticated' ||
        code == 'user-token-expired' ||
        code == 'requires-recent-login' ||
        msgLower.contains('authentication is required')) {
      return ReportUploadException(
        category: ReportUploadErrorCategory.authentication,
        message: 'Sign in again to finish submitting this report.',
      );
    }
    if (code == 'permission-denied') {
      return ReportUploadException(
        category: ReportUploadErrorCategory.permission,
        message:
            'Permission denied saving this report. Verify your email or check account access.',
      );
    }
    if (code == 'unavailable' ||
        code == 'deadline-exceeded' ||
        code == 'aborted' ||
        code == 'network-request-failed') {
      return ReportUploadException(
        category: ReportUploadErrorCategory.connectivity,
        message:
            'Network unavailable while saving report. Tap Retry when online.',
      );
    }
    return ReportUploadException(
      category: ReportUploadErrorCategory.server,
      message: error.message ?? 'Server error ($code) while saving report.',
    );
  }

  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return ReportUploadException(
      category: ReportUploadErrorCategory.connectivity,
      message:
          'Network connection failed. Report is kept safely on this device.',
    );
  }

  if (error is FileSystemException) {
    return ReportUploadException(
      category: ReportUploadErrorCategory.missingImage,
      message: 'Captured photo file is missing from this device.',
    );
  }

  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('photo') && lower.contains('missing')) {
    return ReportUploadException(
      category: ReportUploadErrorCategory.missingImage,
      message: 'Captured photo file is missing from this device.',
    );
  }
  if (lower.contains('not configured') || lower.contains('not deployed')) {
    return ReportUploadException(
      category: ReportUploadErrorCategory.missingConfiguration,
      message:
          'Image upload backend is not configured or deployed yet. Saved locally on this device.',
    );
  }
  if (lower.contains('sign in') || lower.contains('signed in')) {
    return ReportUploadException(
      category: ReportUploadErrorCategory.authentication,
      message: 'Sign in again to finish submitting this report.',
    );
  }
  if (lower.contains('verify your email') ||
      lower.contains('owner mismatch') ||
      lower.contains('permission')) {
    return ReportUploadException(
      category: ReportUploadErrorCategory.permission,
      message: raw,
    );
  }

  return ReportUploadException(
    category: ReportUploadErrorCategory.server,
    message: raw,
  );
}

/// Concise post-capture banner copy explaining local queue state without claiming
/// that going online alone fixes auth, permission, or backend configuration errors.
String queueStatusBannerForError(
  ReportUploadErrorCategory? category,
  String? detail,
) {
  switch (category) {
    case ReportUploadErrorCategory.connectivity:
    case null:
      return 'Saved in My Reports. Will upload automatically when online.';
    case ReportUploadErrorCategory.missingConfiguration:
      return 'Saved in My Reports. Upload service is not configured or deployed yet.';
    case ReportUploadErrorCategory.authentication:
      return 'Saved in My Reports. Sign in again to upload.';
    case ReportUploadErrorCategory.permission:
      return 'Saved in My Reports. Action required: ${sanitizeUploadErrorMessage(detail ?? 'Permission denied.')}';
    case ReportUploadErrorCategory.missingImage:
      return 'Saved in My Reports, but the local photo file is missing.';
    case ReportUploadErrorCategory.server:
      return 'Saved in My Reports. Upload failed on the server; tap Retry in My Reports.';
  }
}

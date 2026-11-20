import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint, kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dpwh_standards.dart';
import 'email_verification_client.dart';
import 'functions_client.dart';
import 'upload_error.dart';

/// Geographical Local Government Unit (LGU) location details
class LguLocationInfo {
  final String barangay;
  final String city;
  final String province;
  final String formattedAddress;

  const LguLocationInfo({
    required this.barangay,
    required this.city,
    required this.province,
    this.formattedAddress = '',
  });

  bool get isValid =>
      (barangay.isNotEmpty && !barangay.startsWith('Unassigned')) ||
      (city.isNotEmpty && !city.startsWith('Bulacan District'));

  Map<String, dynamic> toMap() => {
    'barangay': barangay,
    'city': city,
    'province': province,
    'formattedAddress': formattedAddress,
  };
}

String detectImageMimeType(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

/// Uploads report image bytes via an authenticated backend-issued short-lived
/// Azure Blob Service SAS upload URL and returns the unsigned public HTTPS URL.
Future<String> uploadReportImageWithSignedUrl({
  required Uint8List bytes,
  required String reportId,
  required FirebaseFunctionsClient functionsClient,
  http.Client? httpClient,
}) async {
  if (bytes.isEmpty) {
    throw ReportUploadException(
      category: ReportUploadErrorCategory.missingImage,
      message: 'Captured photo data is empty or missing.',
    );
  }
  final contentType = detectImageMimeType(bytes);
  final Map<String, dynamic> ticket;
  try {
    ticket = await functionsClient.call(
      'issueReportUploadUrl',
      data: {
        'reportId': reportId,
        'contentType': contentType,
        'contentLength': bytes.length,
      },
      fallbackErrorMessage: 'Unable to authorize photo upload',
    );
  } catch (e) {
    throw classifyUploadError(e);
  }

  final rawUploadUrl = (ticket['uploadUrl'] as String?)?.trim() ?? '';
  final rawPublicUrl = (ticket['publicUrl'] as String?)?.trim() ?? '';
  final uploadUri = Uri.tryParse(rawUploadUrl);
  final publicUri = Uri.tryParse(rawPublicUrl);
  if (uploadUri == null ||
      uploadUri.scheme != 'https' ||
      publicUri == null ||
      publicUri.scheme != 'https' ||
      publicUri.hasQuery) {
    throw ReportUploadException(
      category: ReportUploadErrorCategory.server,
      message: 'Upload service returned an invalid upload URL.',
    );
  }

  final headers = <String, String>{
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-version': '2022-11-02',
    'Content-Type': contentType,
  };
  final serverHeaders = ticket['requiredHeaders'];
  if (serverHeaders is Map) {
    for (final entry in serverHeaders.entries) {
      final k = entry.key.toString().trim();
      final v = entry.value.toString().trim();
      if (k.isNotEmpty && v.isNotEmpty) {
        headers[k] = v;
      }
    }
  }

  final client = httpClient ?? http.Client();
  final ownsClient = httpClient == null;
  try {
    final res = await client
        .put(uploadUri, headers: headers, body: bytes)
        .timeout(const Duration(seconds: 45));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return rawPublicUrl;
    }
    if (res.statusCode == 401) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.authentication,
        message: 'Upload authorization rejected. Sign in again and retry.',
      );
    }
    if (res.statusCode == 403) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.permission,
        message:
            'Upload authorization expired or denied. Tap Retry to request a new link.',
      );
    }
    throw ReportUploadException(
      category: ReportUploadErrorCategory.server,
      message: 'Photo storage returned HTTP ${res.statusCode}.',
    );
  } on ReportUploadException {
    rethrow;
  } catch (e) {
    throw classifyUploadError(e);
  } finally {
    if (ownsClient) {
      client.close();
    }
  }
}

class CloudService {
  static final CloudService instance = CloudService._init();
  CloudService._init();

  late final FirebaseFunctionsClient _functionsClient =
      FirebaseFunctionsClient();

  // Firebase Auth & Firestore References
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId:
        '32297924997-iplvd6srs74rqufukbe8u6d24eu4ig9h.apps.googleusercontent.com',
  );
  final CollectionReference _potholesCollection = FirebaseFirestore.instance
      .collection('potholes');
  final CollectionReference _usersCollection = FirebaseFirestore.instance
      .collection('users');

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  final ValueNotifier<bool> emailVerifiedNotifier = ValueNotifier<bool>(false);

  final EmailVerificationBackend _verificationBackend =
      FirebaseEmailVerificationBackend();
  EmailVerificationBackend get emailVerificationBackend => _verificationBackend;

  EmailVerificationStatus? lastVerificationStatus;
  String? lastVerificationSendError;

  /// Register a new user account with email/password and send a Firebase email
  /// verification link while allowing the user into the app immediately.
  Future<UserCredential> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    lastVerificationStatus = null;
    lastVerificationSendError = null;
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    emailVerifiedNotifier.value = false;

    if (cred.user != null) {
      await cred.user!.updateDisplayName(fullName);
      await _saveUserProfile(
        uid: cred.user!.uid,
        email: email,
        displayName: fullName,
        photoUrl: '',
        role: 'user',
      );
      try {
        lastVerificationStatus = await _verificationBackend.sendCode();
      } on EmailVerificationException catch (e) {
        lastVerificationSendError = e.message;
      } catch (e) {
        lastVerificationSendError =
            'Could not send the initial verification email right now. Tap Resend link to try again.';
      }
    }
    return cred;
  }

  /// Fetches the current server-side email verification status without sending
  /// a new email (safe across app restarts).
  Future<EmailVerificationStatus> getEmailVerificationStatus() =>
      _verificationBackend.getStatus();

  /// Requests the backend to generate & email a new 6-digit verification code.
  Future<EmailVerificationStatus> sendEmailVerificationCode() async {
    final status = await _verificationBackend.sendCode();
    lastVerificationStatus = status;
    lastVerificationSendError = null;
    return status;
  }

  /// Validates email verification, refreshes the ID token + FirebaseAuth user,
  /// and notifies listeners on success.
  Future<bool> verifyEmailCode(String enteredCode) async {
    lastVerifyError = null;
    final user = _auth.currentUser;
    if (user == null) {
      throw const EmailVerificationException(
        code: 'unauthenticated',
        reason: 'unauthenticated',
        message: 'Sign in first to verify your email address.',
      );
    }
    if (isGoogleAuthUser(user)) {
      emailVerifiedNotifier.value = true;
      return true;
    }
    try {
      final verified = await _verificationBackend.verifyCode(enteredCode);
      if (verified) {
        lastVerificationStatus = null;
        emailVerifiedNotifier.value = true;
      }
      return verified;
    } on EmailVerificationException catch (e) {
      lastVerifyError = e.message;
      rethrow;
    }
  }

  /// Securely updates the email address of a pending unverified account and
  /// sends a fresh verification email to the corrected email.
  Future<EmailVerificationStatus> updatePendingVerificationEmail(
    String newEmail,
  ) async {
    final status = await _verificationBackend.updatePendingEmail(newEmail);
    lastVerificationStatus = status;
    lastVerificationSendError = null;
    return status;
  }

  /// Human-readable reason the last [verifyEmailCode] call failed, if any.
  String? lastVerifyError;

  /// Checks whether the signed-in user's email is verified in Firebase Auth
  /// (never trusting client-writable Firestore flags).
  Future<bool> isEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) {
      emailVerifiedNotifier.value = false;
      return false;
    }
    if (isGoogleAuthUser(user)) {
      emailVerifiedNotifier.value = true;
      return true;
    }

    try {
      await user.reload();
    } catch (_) {}

    final freshUser = _auth.currentUser;
    if (freshUser == null) {
      emailVerifiedNotifier.value = false;
      return false;
    }
    if (freshUser.emailVerified) {
      try {
        await freshUser.getIdToken(true);
      } catch (_) {}
      emailVerifiedNotifier.value = true;
      return true;
    }
    emailVerifiedNotifier.value = false;
    return false;
  }

  /// Sign in with Email & Password
  Future<UserCredential> signIn({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    if (kIsWeb) {
      await _auth.setPersistence(
        rememberMe ? Persistence.LOCAL : Persistence.SESSION,
      );
    }
    final cred = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    final u = cred.user;
    emailVerifiedNotifier.value =
        u != null && (isGoogleAuthUser(u) || u.emailVerified);
    return cred;
  }

  /// Sign in using Google Auth API with multi-platform mobile & web support
  Future<UserCredential?> signInWithGoogle({bool rememberMe = true}) async {
    try {
      UserCredential? cred;
      final googleProvider = GoogleAuthProvider();
      googleProvider.addScope('email');
      googleProvider.addScope('profile');

      if (kIsWeb) {
        await _auth.setPersistence(
          rememberMe ? Persistence.LOCAL : Persistence.SESSION,
        );
        // On web (desktop & mobile browsers):
        try {
          cred = await _auth.signInWithPopup(googleProvider);
        } catch (popupError) {
          print(
            '[Auth] Popup sign in failed/blocked ($popupError). Trying redirect...',
          );
          try {
            await _auth.signInWithRedirect(googleProvider);
            return null;
          } catch (redirectError) {
            print('[Auth] Redirect fallback error: $redirectError');
            rethrow;
          }
        }
      } else {
        // On mobile native (Android / iOS):
        try {
          final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
          if (googleUser == null) return null; // User cancelled flow

          final GoogleSignInAuthentication googleAuth =
              await googleUser.authentication;
          final AuthCredential credential = GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
            idToken: googleAuth.idToken,
          );
          cred = await _auth.signInWithCredential(credential);
        } catch (nativeGoogleError) {
          final errStr = nativeGoogleError.toString();
          print('[Auth] Native Google Sign-In error: $errStr');
          // If native Google Play Services fails due to missing SHA-1 registration (ApiException: 10)
          // or developer setup mismatch, fall back gracefully to browser OAuth provider
          if (errStr.contains('ApiException: 10') ||
              errStr.contains('DEVELOPER_ERROR') ||
              errStr.contains('12500') ||
              errStr.contains('sign_in_failed')) {
            print(
              '[Auth] Falling back to OAuth provider (browser / Custom Tabs)...',
            );
            try {
              cred = await _auth.signInWithProvider(googleProvider);
            } catch (fallbackError) {
              print(
                '[Auth] OAuth provider fallback also failed: $fallbackError',
              );
              rethrow;
            }
          } else {
            rethrow;
          }
        }
      }

      if (cred.user != null) {
        final doc = await _usersCollection.doc(cred.user!.uid).get();
        final String assignedRole = doc.exists
            ? ((doc.data() as Map<String, dynamic>)['role'] as String? ??
                  'user')
            : 'user';

        await _saveUserProfile(
          uid: cred.user!.uid,
          email: cred.user!.email ?? '',
          displayName: cred.user!.displayName ?? 'Google User',
          photoUrl: cred.user!.photoURL ?? '',
          role: assignedRole,
        );
        emailVerifiedNotifier.value = true;
      }
      return cred;
    } catch (e) {
      print('Google Sign-In Error: $e');
      rethrow;
    }
  }

  /// Helper to save user profile details
  Future<void> _saveUserProfile({
    required String uid,
    required String email,
    required String displayName,
    required String photoUrl,
    required String role,
  }) async {
    final nameParts = displayName.split(' ');
    final firstName = nameParts.isNotEmpty ? nameParts.first : '';
    final lastName = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

    final userDoc = _usersCollection.doc(uid);
    final existing = await userDoc.get();
    if (existing.exists) {
      await userDoc.update({'lastLogin': FieldValue.serverTimestamp()});
      return;
    }

    await userDoc.set({
      'uid': uid,
      'email': email,
      'displayName': displayName,
      'firstName': firstName,
      'lastName': lastName,
      'photoUrl': photoUrl,
      'role': role,
      'lastLogin': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Update user profile (First Name, Last Name, Phone Number)
  Future<void> updateUserProfileDetails({
    required String uid,
    required String firstName,
    required String lastName,
    required String phoneNumber,
  }) async {
    final user = _requireSignedIn();
    if (user.uid != uid) {
      _deny('Users may only modify their own profile.');
    }
    final fullName = '$firstName $lastName'.trim();
    if (_auth.currentUser != null && fullName.isNotEmpty) {
      await _auth.currentUser!.updateDisplayName(fullName);
    }
    await _usersCollection.doc(uid).set({
      'firstName': firstName,
      'lastName': lastName,
      'displayName': fullName.isNotEmpty
          ? fullName
          : (_auth.currentUser?.displayName ?? 'Surveyor'),
      'phoneNumber': phoneNumber,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Check if user account was created via Google Auth provider
  bool isGoogleAuthUser(User? user) {
    if (user == null) return false;
    for (var provider in user.providerData) {
      if (provider.providerId == 'google.com') return true;
    }
    return false;
  }

  /// Sign out current user
  Future<void> signOut() async {
    if (!kIsWeb) {
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
    }
    await _auth.signOut();
    emailVerifiedNotifier.value = false;
  }

  /// Get current user role ('super_admin', 'admin', or 'user')
  Future<String> getUserRole(String uid) async {
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) return 'user';
    try {
      final doc = await _usersCollection
          .doc(uid)
          .get()
          .timeout(const Duration(milliseconds: 1500));
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        final role = data['role'] as String? ?? 'user';
        return const {'user', 'admin', 'super_admin'}.contains(role)
            ? role
            : 'user';
      }
    } catch (e) {
      // Fast fallback to 'user' so map screen loads instantly with 0 delay
    }
    return 'user';
  }

  /// Check whether current signed-in user is an admin or super_admin
  Future<bool> isAdmin([String? uid]) async {
    final targetUid = uid ?? _auth.currentUser?.uid;
    if (targetUid == null) return false;
    final role = await getUserRole(targetUid);
    return role == 'admin' || role == 'super_admin';
  }

  Never _deny(String message) => throw FirebaseException(
    plugin: 'cloud_firestore',
    code: 'permission-denied',
    message: message,
  );

  User _requireSignedIn() {
    final user = _auth.currentUser;
    if (user == null) _deny('Authentication is required.');
    return user;
  }

  User _requireVerifiedUser() {
    final user = _requireSignedIn();
    if (!isGoogleAuthUser(user) && !user.emailVerified) {
      _deny('Verify your email address before continuing.');
    }
    return user;
  }

  Future<String> _requireRole(Set<String> allowedRoles) async {
    final user = _requireVerifiedUser();
    final role = await getUserRole(user.uid);
    if (!allowedRoles.contains(role)) {
      _deny('This action requires ${allowedRoles.join(' or ')} access.');
    }
    return role;
  }

  /// Stream of all users (for Super Admin dashboard)
  Stream<QuerySnapshot> streamAllUsers() {
    final user = _auth.currentUser;
    if (user == null) return const Stream<QuerySnapshot>.empty();
    return _usersCollection.snapshots();
  }

  /// Super Admin action: Promote or change a user's role
  Future<void> updateUserRole(String uid, String newRole) async {
    await _requireRole(const {'super_admin'});
    if (!const {'user', 'admin', 'super_admin'}.contains(newRole)) {
      throw ArgumentError.value(newRole, 'newRole', 'Unsupported role');
    }
    if (_auth.currentUser!.uid == uid && newRole != 'super_admin') {
      _deny('A super administrator cannot demote their own account.');
    }
    await _usersCollection.doc(uid).update({'role': newRole});
  }

  /// Uploads a report image via an authenticated backend-issued short-lived SAS
  /// upload URL and returns the unsigned public blob URL, throwing a sanitized
  /// [ReportUploadException] on failure.
  Future<String> uploadReportImage(
    Uint8List bytes, {
    required String reportId,
    FirebaseFunctionsClient? functionsClient,
    http.Client? httpClient,
  }) async {
    final rawUser = _auth.currentUser;
    if (rawUser == null) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.authentication,
        message: 'Sign in first to upload road report photos.',
      );
    }
    if (!isGoogleAuthUser(rawUser) && !rawUser.emailVerified) {
      await isEmailVerified();
    }
    final refreshedUser = _auth.currentUser;
    if (refreshedUser == null) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.authentication,
        message: 'Sign in first to upload road report photos.',
      );
    }
    if (!isGoogleAuthUser(refreshedUser) && !refreshedUser.emailVerified) {
      throw ReportUploadException(
        category: ReportUploadErrorCategory.permission,
        message:
            'Verify your email address before uploading road report photos.',
      );
    }

    return uploadReportImageWithSignedUrl(
      bytes: bytes,
      reportId: reportId,
      functionsClient: functionsClient ?? _functionsClient,
      httpClient: httpClient,
    );
  }

  /// Compatibility wrapper returning null on failure after logging sanitized error details.
  Future<String?> uploadImageBytesToAzure(
    Uint8List bytes, {
    String? reportId,
  }) async {
    try {
      return await uploadReportImage(
        bytes,
        reportId: reportId ?? 'rep_${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (e) {
      final classified = classifyUploadError(e);
      debugPrint(
        'Azure Storage Upload Error (${classified.category.name}): ${classified.message}',
      );
      return null;
    }
  }

  final DocumentReference _systemSettingsDoc = FirebaseFirestore.instance
      .collection('settings')
      .doc('system');

  /// Stream live auto-accept mode setting from Firestore
  Stream<bool> streamAutoAcceptSetting() {
    return _systemSettingsDoc.snapshots().map((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) return false;
      final data = snapshot.data() as Map<String, dynamic>;
      return data['autoAcceptPotholes'] as bool? ?? false;
    });
  }

  /// Check whether auto-accept is currently turned on
  Future<bool> getAutoAcceptSetting() async {
    try {
      final doc = await _systemSettingsDoc.get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        return data['autoAcceptPotholes'] as bool? ?? false;
      }
    } catch (e) {
      print('Error getting auto-accept setting: $e');
    }
    return false;
  }

  /// Toggle or update auto-accept mode setting
  Future<void> setAutoAcceptSetting(bool enabled) async {
    await _requireRole(const {'admin', 'super_admin'});
    await _systemSettingsDoc.set({
      'autoAcceptPotholes': enabled,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': _auth.currentUser?.email ?? 'admin',
    }, SetOptions(merge: true));
  }

  /// Adds a new detected pothole to Firebase Firestore with Reporter Attribution & Severity Metadata!
  Future<DocumentReference> addPotholeToCloud({
    required LatLng location,
    required String imageUrl,
    String? reportId,
    String overallSeverity = 'medium', // 'low', 'medium', 'high'
    int potholeCount = 1,
    List<Map<String, dynamic>>? detections,
    String? primaryDpwhCode,
    String? primaryDefect,
    String? responseTime,
    String? correctiveMeasure,
    String? barangay,
    String? city,
    String? province,
    String? formattedAddress,
    String? note,
  }) async {
    final rawUser = _requireSignedIn();
    if (!isGoogleAuthUser(rawUser) && !rawUser.emailVerified) {
      await isEmailVerified();
    }
    final user = _requireVerifiedUser();
    final reporterUid = user.uid;
    final reporterEmail = user.email ?? '';
    final reporterName = user.displayName ?? 'Surveyor';
    final reporterPhotoUrl = user.photoURL ?? '';
    final primaryClass = primaryDefect != null
        ? DpwhStandards.classForReport({
            'primaryDefect': primaryDefect,
            'primaryDpwhCode': primaryDpwhCode,
          })
        : primaryDpwhCode == null
        ? DpwhStandards.pothole
        : primaryDpwhCode == 'CODE 12'
        ? null
        : DpwhStandards.tryClassify(primaryDpwhCode);
    if (!DpwhStandards.allClasses.contains(primaryClass)) {
      throw ArgumentError(
        'Select one of the four supported defect classes; crack orientation must be specified.',
      );
    }
    if (primaryDpwhCode != null && primaryDpwhCode != primaryClass!.code) {
      throw ArgumentError('Defect class and DPWH code do not match.');
    }
    final canonicalDetections = <Map<String, dynamic>>[];
    for (final detection in detections ?? <Map<String, dynamic>>[]) {
      final cls = DpwhStandards.activeClassForDetection(detection);
      if (cls == null) throw ArgumentError('Unsupported model detection.');
      canonicalDetections.add({
        ...detection,
        'classId': cls.classId,
        'className': cls.name,
        'dpwhCode': cls.code,
      });
    }

    if (!location.latitude.isFinite ||
        !location.longitude.isFinite ||
        location.latitude < -90 ||
        location.latitude > 90 ||
        location.longitude < -180 ||
        location.longitude > 180) {
      throw ArgumentError('Invalid pothole coordinates.');
    }
    if (!const {'low', 'medium', 'high'}.contains(overallSeverity)) {
      throw ArgumentError.value(overallSeverity, 'overallSeverity');
    }
    if (potholeCount < 1 || potholeCount > 100) {
      throw ArgumentError.value(potholeCount, 'potholeCount');
    }
    if (imageUrl.isNotEmpty) {
      final imageUri = Uri.tryParse(imageUrl);
      if (imageUri == null ||
          imageUri.scheme != 'https' ||
          imageUri.host.toLowerCase() !=
              'potholestorage2026.blob.core.windows.net' ||
          !imageUri.path.startsWith('/photos/')) {
        throw ArgumentError.value(
          imageUrl,
          'imageUrl',
          'Trusted HTTPS URL required',
        );
      }
    }

    // New reports are always untrusted. A privileged backend trigger may
    // approve them after checking the server-side auto-accept setting.
    const String initialStatus = 'pending';

    final ref = reportId == null
        ? _potholesCollection.doc()
        : _potholesCollection.doc(reportId);
    if (reportId != null) {
      final existing = await ref.get();
      if (existing.exists) {
        final data = existing.data() as Map<String, dynamic>;
        if (data['reporterUid'] != user.uid) {
          throw StateError('Report owner mismatch.');
        }
        return ref;
      }
    }
    await ref.set({
      'latitude': location.latitude,
      'longitude': location.longitude,
      'imageUrl': imageUrl,
      'status':
          initialStatus, // 'approved' if auto-accept is enabled, else 'pending'
      'overallSeverity': overallSeverity,
      'potholeCount': potholeCount,
      if (canonicalDetections.isNotEmpty) 'modelId': DpwhStandards.modelId,
      'primaryClassId': primaryClass!.classId,
      'primaryDpwhCode': primaryClass.code,
      'primaryDefect': primaryClass.name,
      'responseTime': primaryClass.responseTime,
      'correctiveMeasure': primaryClass.correctiveMeasure,
      'detections': canonicalDetections,
      if (barangay != null && barangay.isNotEmpty) 'barangay': barangay,
      if (city != null && city.isNotEmpty) 'city': city,
      if (province != null && province.isNotEmpty) 'province': province,
      if (formattedAddress != null && formattedAddress.isNotEmpty)
        'formattedAddress': formattedAddress,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'reporterUid': reporterUid,
      'reporterEmail': reporterEmail,
      'reporterName': reporterName,
      'reporterPhotoUrl': reporterPhotoUrl,
      'timestamp': FieldValue.serverTimestamp(),
    });
    return ref;
  }

  static final Map<String, LguLocationInfo> _lguCache = {};

  /// Reverse geocodes a GPS coordinate into Barangay, City/Municipality, and Province.
  /// Uses Nominatim OpenStreetMap with structured field extraction for the Philippines.
  Future<LguLocationInfo> reverseGeocodeLgu(LatLng point) async {
    final key =
        '${point.latitude.toStringAsFixed(4)},${point.longitude.toStringAsFixed(4)}';
    if (_lguCache.containsKey(key)) {
      return _lguCache[key]!;
    }

    try {
      final url = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': point.latitude.toString(),
        'lon': point.longitude.toString(),
        'format': 'json',
        'zoom': '18',
        'addressdetails': '1',
      });
      final res = await http
          .get(
            url,
            headers: {
              'User-Agent': 'RoadSense-LGU-Audit/1.0 (roadsense.local)',
            },
          )
          .timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final addr = (data['address'] as Map<String, dynamic>?) ?? {};

        // In the Philippines:
        // Suburb, village, quarter, neighbourhood, or city_district maps to Barangay
        String brgy =
            (addr['suburb'] ??
                    addr['village'] ??
                    addr['quarter'] ??
                    addr['neighbourhood'] ??
                    addr['city_district'] ??
                    '')
                .toString()
                .trim();

        if (brgy.toLowerCase().startsWith('brgy.') ||
            brgy.toLowerCase().startsWith('brgy ')) {
          brgy = 'Barangay ${brgy.substring(5).trim()}';
        } else if (brgy.isNotEmpty &&
            !brgy.toLowerCase().startsWith('barangay')) {
          brgy = 'Barangay $brgy';
        }

        // City / Municipality:
        String city =
            (addr['city'] ??
                    addr['town'] ??
                    addr['municipality'] ??
                    addr['county'] ??
                    '')
                .toString()
                .trim();

        // Province:
        String province = (addr['state'] ?? addr['province'] ?? 'Bulacan')
            .toString()
            .trim();

        final formatted = (data['display_name'] ?? '').toString();

        final info = LguLocationInfo(
          barangay: brgy.isNotEmpty ? brgy : 'Unspecified Barangay',
          city: city.isNotEmpty ? city : 'Bulacan District',
          province: province.isNotEmpty ? province : 'Bulacan',
          formattedAddress: formatted,
        );

        if (_lguCache.length > 500) _lguCache.clear();
        _lguCache[key] = info;
        return info;
      }
    } catch (_) {}

    final fallback = LguLocationInfo(
      barangay: 'Unassigned Barangay',
      city: 'Bulacan District',
      province: 'Bulacan',
      formattedAddress:
          '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
    );
    _lguCache[key] = fallback;
    return fallback;
  }

  /// Updates or backfills the geographic LGU details of a specific pothole
  Future<void> updatePotholeLguLocation(
    String docId, {
    required String barangay,
    required String city,
    String? province,
    String? formattedAddress,
  }) async {
    await _potholesCollection.doc(docId).set({
      'barangay': barangay,
      'city': city,
      if (province != null && province.isNotEmpty) 'province': province,
      if (formattedAddress != null && formattedAddress.isNotEmpty)
        'formattedAddress': formattedAddress,
    }, SetOptions(merge: true));
  }

  /// Listens to live updates of ONLY 'approved' potholes for navigation map
  Stream<QuerySnapshot> streamApprovedPotholes() {
    return _potholesCollection
        .where('status', isEqualTo: 'approved')
        .snapshots();
  }

  /// Returns true when a Firestore report payload is approved, unresolved,
  /// publicly accessible, and falls inside `[minLon, maxLon]`.
  static bool isEligibleCorridorReportData(
    Map<String, dynamic> data, {
    required double minLon,
    required double maxLon,
  }) {
    final String status = (data['status'] as String? ?? '')
        .trim()
        .toLowerCase();
    final bool isResolved =
        data['resolved'] == true ||
        data['isResolved'] == true ||
        status == 'resolved' ||
        status == 'fixed' ||
        status == 'closed';
    final bool isAccessible =
        data['isAccessible'] != false && data['accessible'] != false;
    if (status != 'approved' || isResolved || !isAccessible) return false;
    final dynamic rawLon = data['longitude'];
    final double? lng = rawLon is num
        ? rawLon.toDouble()
        : double.tryParse(rawLon?.toString() ?? '');
    if (lng == null || !lng.isFinite) return false;
    final double lowLon = minLon <= maxLon ? minLon : maxLon;
    final double highLon = minLon <= maxLon ? maxLon : minLon;
    return lng >= lowLon && lng <= highLon;
  }

  /// Fetches pages sequentially with cursor continuation so a latitude band
  /// containing more than [pageSize] unapproved/resolved/off-corridor records
  /// never truncates valid approved reports along a route corridor.
  static Future<List<T>> paginateCorridorPages<T>({
    required Future<List<T>> Function(T? cursor) fetchPage,
    required Map<String, dynamic> Function(T item) dataOf,
    required double minLon,
    required double maxLon,
    int pageSize = 400,
    int maxPages = 25,
  }) async {
    final int safePageSize = pageSize.clamp(1, 1000);
    final int safeMaxPages = maxPages.clamp(1, 200);
    final List<T> collected = <T>[];
    T? cursor;

    for (int page = 0; page < safeMaxPages; page++) {
      final List<T> docs = await fetchPage(cursor);
      if (docs.isEmpty) break;
      for (final doc in docs) {
        if (isEligibleCorridorReportData(
          dataOf(doc),
          minLon: minLon,
          maxLon: maxLon,
        )) {
          collected.add(doc);
        }
      }
      if (docs.length < safePageSize) break;
      cursor = docs.last;
    }
    return List<T>.unmodifiable(collected);
  }

  /// Queries approved, unresolved, accessible reports within a route corridor
  /// bounding box using Firestore's single-field latitude range index plus
  /// bounded cursor pagination over latitude slices.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  fetchApprovedReportsInCorridor({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
    int limit = 400,
    int maxPages = 25,
  }) async {
    final double lowLat = minLat <= maxLat ? minLat : maxLat;
    final double highLat = minLat <= maxLat ? maxLat : minLat;
    final int pageSize = limit.clamp(1, 500);

    return paginateCorridorPages<QueryDocumentSnapshot<Map<String, dynamic>>>(
      pageSize: pageSize,
      maxPages: maxPages,
      fetchPage: (cursor) async {
        Query query = _potholesCollection
            .where('latitude', isGreaterThanOrEqualTo: lowLat)
            .where('latitude', isLessThanOrEqualTo: highLat)
            .orderBy('latitude')
            .limit(pageSize);
        if (cursor != null) {
          query = query.startAfterDocument(cursor);
        }
        final snapshot = await query.get();
        return snapshot.docs
            .map((d) => d as QueryDocumentSnapshot<Map<String, dynamic>>)
            .toList(growable: false);
      },
      dataOf: (doc) => doc.data(),
      minLon: minLon,
      maxLon: maxLon,
    );
  }

  /// Listens to ALL potholes (for Admin Dashboard and Map streams)
  Stream<QuerySnapshot> streamAllPotholes() {
    return _potholesCollection.snapshots();
  }

  /// Stream potholes submitted by a specific user (for User History tab)
  Stream<QuerySnapshot> streamUserPotholes(String uid) {
    return _potholesCollection.where('reporterUid', isEqualTo: uid).snapshots();
  }

  /// Admin Action: Update status of a pothole ('approved', 'rejected', 'pending', or 'deleted')
  Future<void> updatePotholeStatus(
    String docId,
    String newStatus, {
    String? rejectionReason,
  }) async {
    await _requireRole(const {'admin', 'super_admin'});
    if (!const {
      'approved',
      'rejected',
      'pending',
      'deleted',
    }.contains(newStatus)) {
      throw ArgumentError.value(newStatus, 'newStatus', 'Unsupported status');
    }
    final updates = <String, dynamic>{
      'status': newStatus,
      'moderatedAt': FieldValue.serverTimestamp(),
      'moderatedBy': _auth.currentUser!.uid,
    };
    if (newStatus == 'rejected') {
      final cleanReason = (rejectionReason ?? '').trim();
      if (cleanReason.isNotEmpty) {
        updates['rejectionReason'] = cleanReason;
      }
    } else {
      updates['rejectionReason'] = FieldValue.delete();
    }
    await _potholesCollection.doc(docId).update(updates);
  }

  /// Action: Edit an existing pothole report (severity, count, coordinates, notes)
  Future<void> editPothole(
    String docId, {
    String? overallSeverity,
    int? potholeCount,
    double? latitude,
    double? longitude,
    String? note,
    String? primaryDpwhCode,
    String? primaryDefect,
    String? responseTime,
    String? correctiveMeasure,
  }) async {
    final user = _requireVerifiedUser();
    final docSnap = await _potholesCollection.doc(docId).get();
    if (!docSnap.exists) throw Exception('Report does not exist.');

    final data = docSnap.data() as Map<String, dynamic>? ?? {};
    final isReporter = data['reporterUid'] == user.uid;
    final bool isAdminUser = await isAdmin();
    if (!isReporter && !isAdminUser) {
      throw Exception('Access denied. You can only edit your own reports.');
    }
    if (!isAdminUser && data['status'] != 'pending') {
      throw StateError('Only pending reports can be edited by their reporter.');
    }
    if (overallSeverity != null &&
        !const {'low', 'medium', 'high'}.contains(overallSeverity)) {
      throw ArgumentError.value(overallSeverity, 'overallSeverity');
    }
    if (potholeCount != null && (potholeCount < 1 || potholeCount > 100)) {
      throw ArgumentError.value(potholeCount, 'potholeCount');
    }
    if (latitude != null &&
        (!latitude.isFinite || latitude < -90 || latitude > 90)) {
      throw ArgumentError.value(latitude, 'latitude');
    }
    if (longitude != null &&
        (!longitude.isFinite || longitude < -180 || longitude > 180)) {
      throw ArgumentError.value(longitude, 'longitude');
    }

    final updates = <String, dynamic>{
      'lastEditedAt': FieldValue.serverTimestamp(),
      'lastEditedBy': user.email ?? user.uid,
    };
    if (overallSeverity != null) updates['overallSeverity'] = overallSeverity;
    if (potholeCount != null) updates['potholeCount'] = potholeCount;
    if (latitude != null) updates['latitude'] = latitude;
    if (longitude != null) updates['longitude'] = longitude;
    if (note != null) updates['note'] = note;
    if (primaryDpwhCode != null) updates['primaryDpwhCode'] = primaryDpwhCode;
    if (primaryDefect != null) updates['primaryDefect'] = primaryDefect;
    if (responseTime != null) updates['responseTime'] = responseTime;
    if (correctiveMeasure != null) {
      updates['correctiveMeasure'] = correctiveMeasure;
    }

    if (primaryDefect != null || primaryDpwhCode != null) {
      final cls = DpwhStandards.tryClassify(
        primaryDefect ?? data['primaryDefect'] as String?,
      );
      if (!DpwhStandards.allClasses.contains(cls) ||
          (primaryDpwhCode != null && primaryDpwhCode != cls!.code)) {
        throw ArgumentError(
          'Select a supported defect class with its matching DPWH code.',
        );
      }
      updates.addAll({
        'primaryClassId': cls!.classId,
        'primaryDefect': cls.name,
        'primaryDpwhCode': cls.code,
        'responseTime': cls.responseTime,
        'correctiveMeasure': cls.correctiveMeasure,
      });
    }

    await _potholesCollection.doc(docId).update(updates);
  }

  /// Crowdsourced consensus verification: drivers report if a hazard is still there or fixed
  Future<void> submitHazardFeedback(String docId, bool stillThere) async {
    final user = _auth.currentUser;
    final docRef = _potholesCollection.doc(docId);
    final updates = <String, dynamic>{
      stillThere ? 'upvotes' : 'downvotes': FieldValue.increment(1),
      'lastFeedbackAt': FieldValue.serverTimestamp(),
    };
    if (user != null) {
      updates['feedbackUsers'] = FieldValue.arrayUnion([user.uid]);
    }
    await docRef.set(updates, SetOptions(merge: true));
  }

  /// Admin Action: Bulk approve multiple pending potholes (chunked safely under Firestore batch limits)
  Future<int> bulkApprovePotholes(List<String> docIds) async {
    await _requireRole(const {'admin', 'super_admin'});
    if (docIds.isEmpty) return 0;
    const chunkSize = 450;
    for (var i = 0; i < docIds.length; i += chunkSize) {
      final batch = FirebaseFirestore.instance.batch();
      final chunk = docIds.sublist(
        i,
        (i + chunkSize) > docIds.length ? docIds.length : i + chunkSize,
      );
      for (final id in chunk) {
        batch.update(_potholesCollection.doc(id), {
          'status': 'approved',
          'moderatedAt': FieldValue.serverTimestamp(),
          'moderatedBy': _auth.currentUser!.uid,
          'rejectionReason': FieldValue.delete(),
        });
      }
      await batch.commit();
    }
    return docIds.length;
  }

  /// Admin Action: Bulk move reports to Trash (preserving prior status per entry)
  Future<int> bulkSoftDeletePotholes(
    List<({String docId, String previousStatus})> targets,
  ) async {
    await _requireRole(const {'admin', 'super_admin'});
    if (targets.isEmpty) return 0;
    const chunkSize = 450;
    final actor = _auth.currentUser?.email ?? _auth.currentUser?.uid ?? 'admin';
    for (var i = 0; i < targets.length; i += chunkSize) {
      final batch = FirebaseFirestore.instance.batch();
      final chunk = targets.sublist(
        i,
        (i + chunkSize) > targets.length ? targets.length : i + chunkSize,
      );
      for (final item in chunk) {
        batch.update(_potholesCollection.doc(item.docId), {
          'status': 'deleted',
          'previousStatus': item.previousStatus,
          'deletedAt': FieldValue.serverTimestamp(),
          'deletedBy': actor,
        });
      }
      await batch.commit();
    }
    return targets.length;
  }

  /// Admin Action: Soft-delete a pothole (moves it to the Trash Bin)
  Future<void> softDeletePothole(
    String docId, {
    String previousStatus = 'approved',
  }) async {
    await _requireRole(const {'admin', 'super_admin'});
    await _potholesCollection.doc(docId).update({
      'status': 'deleted',
      'previousStatus': previousStatus,
      'deletedAt': FieldValue.serverTimestamp(),
      'deletedBy':
          _auth.currentUser?.email ?? _auth.currentUser?.uid ?? 'admin',
    });
  }

  /// Admin Action: Restore a pothole from the Trash Bin
  Future<void> restorePothole(String docId, {String? targetStatus}) async {
    await _requireRole(const {'admin', 'super_admin'});
    String statusToRestore = targetStatus ?? 'approved';
    if (targetStatus == null) {
      final doc = await _potholesCollection.doc(docId).get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        statusToRestore = data['previousStatus'] as String? ?? 'approved';
      }
    }
    await _potholesCollection.doc(docId).update({
      'status': statusToRestore,
      'restoredAt': FieldValue.serverTimestamp(),
      'restoredBy':
          _auth.currentUser?.email ?? _auth.currentUser?.uid ?? 'admin',
    });
  }

  /// Admin Action: Permanently delete a pothole record from Firestore
  Future<void> permanentDeletePothole(String docId) async {
    await _requireRole(const {'admin', 'super_admin'});
    await _potholesCollection.doc(docId).delete();
  }

  /// Admin Action: Batch purge/empty all trashed potholes permanently
  Future<void> emptyTrashPotholes(List<String> docIds) async {
    await _requireRole(const {'admin', 'super_admin'});
    final batch = FirebaseFirestore.instance.batch();
    for (final id in docIds) {
      batch.delete(_potholesCollection.doc(id));
    }
    await batch.commit();
  }

  /// Action: Soft-delete a pending pothole submitted by user (or any pothole by admin) to Trash Bin
  Future<void> userSoftDeletePothole(String docId) async {
    final user = _requireVerifiedUser();
    final docSnap = await _potholesCollection.doc(docId).get();
    if (!docSnap.exists) return;
    final data = docSnap.data() as Map<String, dynamic>? ?? {};
    final isReporter = data['reporterUid'] == user.uid;
    final status = data['status'] as String? ?? 'pending';

    final bool isAdminUser = await isAdmin();
    if (!isReporter && !isAdminUser) {
      throw Exception('Access denied. You can only delete your own reports.');
    }

    if (!isAdminUser && status == 'approved') {
      throw Exception(
        'Approved reports are verified on the map and can only be removed by administrators.',
      );
    }

    await _potholesCollection.doc(docId).update({
      'status': 'deleted',
      'previousStatus': status,
      'deletedAt': FieldValue.serverTimestamp(),
      'deletedBy': user.email ?? user.uid,
    });
  }

  /// Action: Restore a pothole from the Trash Bin back to active status
  Future<void> userRestorePothole(String docId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be signed in.');
    }
    final docSnap = await _potholesCollection.doc(docId).get();
    if (!docSnap.exists) return;
    final data = docSnap.data() as Map<String, dynamic>? ?? {};
    final isReporter = data['reporterUid'] == user.uid;
    final bool isAdminUser = await isAdmin();

    if (!isReporter && !isAdminUser) {
      throw Exception('Access denied.');
    }

    final prevStatus = data['previousStatus'] as String? ?? 'pending';
    await _potholesCollection.doc(docId).update({
      'status': prevStatus,
      'restoredAt': FieldValue.serverTimestamp(),
      'restoredBy': user.email ?? user.uid,
    });
  }

  /// Action: Permanently delete a pothole record from Firestore (Pending/Trash only for users, any for admin)
  Future<void> permanentDeleteUserPothole(String docId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be signed in to delete a report.');
    }
    final docSnap = await _potholesCollection.doc(docId).get();
    if (!docSnap.exists) return;
    final data = docSnap.data() as Map<String, dynamic>? ?? {};
    final isReporter = data['reporterUid'] == user.uid;
    final status = data['status'] as String? ?? 'pending';
    final bool isAdminUser = await isAdmin();

    if (!isReporter && !isAdminUser) {
      throw Exception('Access denied.');
    }

    if (!isAdminUser && status == 'approved') {
      throw Exception(
        'Approved reports are verified on the map and can only be removed by administrators.',
      );
    }

    await _potholesCollection.doc(docId).delete();
  }

  /// Action: Batch purge/empty all trashed potholes belonging to the user (or all if admin)
  Future<int> userEmptyTrash(List<String> docIds) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User must be signed in.');
    if (docIds.isEmpty) return 0;

    final bool isAdminUser = await isAdmin();
    final batch = FirebaseFirestore.instance.batch();
    int count = 0;

    for (final id in docIds) {
      final docSnap = await _potholesCollection.doc(id).get();
      if (docSnap.exists) {
        final data = docSnap.data() as Map<String, dynamic>? ?? {};
        final isReporter = data['reporterUid'] == user.uid;
        final status = data['status'] as String? ?? '';
        final prevStatus = data['previousStatus'] as String? ?? '';

        if (isAdminUser ||
            (isReporter && status == 'deleted' && prevStatus != 'approved')) {
          batch.delete(_potholesCollection.doc(id));
          count++;
        }
      }
    }
    if (count > 0) {
      await batch.commit();
    }
    return count;
  }

  /// Action: Delete a pothole record from Firestore (Author or Admin)
  Future<void> deletePothole(String docId) async {
    await userSoftDeletePothole(docId);
  }

  /// Super Admin Action: Delete ALL Firestore user docs except protected emails.
  /// Firebase Auth accounts are NOT deleted here — do that in Firebase Console.
  /// Returns the count of deleted documents.
  Future<int> resetNonAdminUsers({
    Set<String> protectedEmails = const {
      'jenardphil001@gmail.com',
      'jenardphil111@gmail.com',
    },
  }) async {
    await _requireRole(const {'super_admin'});

    final snap = await _usersCollection.get();
    final toDelete = snap.docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final email = (data['email'] as String? ?? '').toLowerCase().trim();
      return !protectedEmails.contains(email);
    }).toList();

    if (toDelete.isEmpty) return 0;

    // Batch in groups of 500 (Firestore limit per commit)
    var batch = FirebaseFirestore.instance.batch();
    int count = 0;
    for (final doc in toDelete) {
      batch.delete(doc.reference);
      count++;
      if (count % 500 == 0) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
      }
    }
    if (count % 500 != 0) await batch.commit();

    return toDelete.length;
  }
}

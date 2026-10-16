import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:azblob/azblob.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

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

class CloudService {
  static final CloudService instance = CloudService._init();
  CloudService._init();

  static const String _defaultConnectionString =
      'DefaultEndpointsProtocol=https;AccountName=potholestorage2026;AccountKey=jbph8cZNi2ZPIGhWPP6ovBTZhdSQVFzNFNEMXiK68NJAmLO1Q4W+rPjG+QsekmTzG8QGBIxLsZGU+ASt6OdutQ==;EndpointSuffix=core.windows.net';

  static const String _connectionString = String.fromEnvironment(
    'AZURE_STORAGE_CONNECTION_STRING',
    defaultValue: _defaultConnectionString,
  );
  static const String _containerName = 'photos';

  late final AzureStorage _azureStorage = AzureStorage.parse(_connectionString);

  // Firebase Auth & Firestore References
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId:
        '32297924997-iplvd6srs74rqufukbe8u6d24eu4ig9h.apps.googleusercontent.com',
  );
  final CollectionReference _potholesCollection = FirebaseFirestore.instance
      .collection('potholes');
  final CollectionReference _usersCollection = FirebaseFirestore.instance
      .collection('users');

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Register a new user account with email/password
  Future<UserCredential> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

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
        await generateVerificationCode(cred.user!.uid);
      } catch (_) {}
      try {
        await cred.user!.sendEmailVerification();
        _lastVerificationEmailSent = DateTime.now();
      } catch (e) {
        print('Initial signUp sendEmailVerification error: $e');
      }
    }
    return cred;
  }

  DateTime? _lastVerificationEmailSent;

  /// Requests a fresh verification email with rate-limit protection and
  /// ensures a 6-digit verification code is generated in Firestore.
  /// Returns a user-friendly status message.
  Future<String> sendCustomEmailVerificationCode() async {
    final user = _auth.currentUser;
    if (user == null) return 'No user is currently signed in.';

    // Generate or ensure a 6-digit code exists in Firestore for dual-mode verification
    try {
      await generateVerificationCode(user.uid);
    } catch (e) {
      print('generateVerificationCode error: $e');
    }

    // Rate-limit guard: don't call Firebase Auth again if sent within 45 seconds
    if (_lastVerificationEmailSent != null) {
      final diff = DateTime.now().difference(_lastVerificationEmailSent!).inSeconds;
      if (diff < 45) {
        return 'A verification email was already sent recently. Please check your inbox and Spam/Junk folder (${45 - diff}s cooldown).';
      }
    }

    try {
      await user.sendEmailVerification();
      _lastVerificationEmailSent = DateTime.now();
      return 'Verification email sent! Check your inbox and Spam folder.';
    } on FirebaseAuthException catch (e) {
      print('Firebase sendEmailVerification error: ${e.code} - ${e.message}');
      if (e.code == 'too-many-requests') {
        return 'Firebase rate limit: An email was recently requested. Please check your spam folder or wait a moment before trying again.';
      }
      return e.message ?? 'Failed to send verification email (${e.code}).';
    } catch (e) {
      print('Generic sendEmailVerification error: $e');
      return 'Could not send verification email: $e';
    }
  }

  /// Checks if the current Firebase Auth user has verified via the email link
  /// (i.e. user.emailVerified == true). Marks Firestore as verified too.
  Future<bool> checkNativeEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
      final freshUser = _auth.currentUser;
      if (freshUser != null && freshUser.emailVerified) {
        try {
          await _usersCollection.doc(user.uid).set({
            'isEmailVerified': true,
            'isVerified': true,
            'emailVerifiedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (e) {
          print('Could not mirror isEmailVerified to Firestore: $e');
        }
        return true;
      }
    } catch (e) {
      print('checkNativeEmailVerified reload error: $e');
    }
    return false;
  }

  /// Verifies via either input 6-digit code or Firebase Auth's native email link.
  Future<bool> verifyEmailCode(String enteredCode) async {
    final user = _auth.currentUser;
    if (user == null) return false;
    if (isGoogleAuthUser(user)) return true;

    final trimmed = enteredCode.trim();

    // 1. If 6-digit code was entered, verify against stored code in Firestore
    if (trimmed.length == 6) {
      final codeOk = await verifyUserWithCode(uid: user.uid, inputCode: trimmed);
      if (codeOk) return true;
    }

    // 2. Otherwise check if user verified via email link
    return await checkNativeEmailVerified();
  }

  /// Human-readable reason the last [verifyEmailCode] call failed, if any.
  String? lastVerifyError;

  /// Checks if current user's email is verified (either via Firestore code, admin role, or Firebase Auth)
  Future<bool> isEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    if (isGoogleAuthUser(user)) return true;

    // Check if user is admin / super_admin or already marked verified in Firestore
    try {
      final doc = await _usersCollection.doc(user.uid).get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        if (data['isEmailVerified'] == true || data['isVerified'] == true) {
          return true;
        }
        final role = data['role'] as String?;
        if (role == 'admin' || role == 'super_admin') {
          return true; // Administrators are exempted from email verification lockouts
        }
      }
    } catch (e) {
      print('isEmailVerified Firestore check error: $e');
    }

    // Check Firebase Auth native flag
    try {
      await user.reload();
      final freshUser = _auth.currentUser;
      if (freshUser != null && freshUser.emailVerified) {
        try {
          await _usersCollection.doc(user.uid).set({
            'isEmailVerified': true,
            'isVerified': true,
            'emailVerifiedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
        return true;
      }
    } catch (e) {
      print('isEmailVerified Auth reload error: $e');
    }

    return false;
  }

  /// Send email verification link directly to current user's email inbox
  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user != null && !user.emailVerified) {
      await user.sendEmailVerification();
    }
  }

  /// Retrieves the active 6-digit verification code stored for the user
  Future<String?> getActiveVerificationCode(String uid) async {
    _requireCurrentUser(uid);
    try {
      final doc = await _usersCollection.doc(uid).get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        return data['verificationCode']?.toString();
      }
    } catch (_) {}
    return null;
  }

  /// Sign in with Email & Password
  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    return await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  /// Sign in using Google Auth API with multi-platform mobile & web support
  Future<UserCredential?> signInWithGoogle() async {
    try {
      UserCredential? cred;
      final googleProvider = GoogleAuthProvider();
      googleProvider.addScope('email');
      googleProvider.addScope('profile');

      if (kIsWeb) {
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
            print('[Auth] Falling back to OAuth provider (browser / Custom Tabs)...');
            try {
              cred = await _auth.signInWithProvider(googleProvider);
            } catch (fallbackError) {
              print('[Auth] OAuth provider fallback also failed: $fallbackError');
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
            ? ((doc.data() as Map<String, dynamic>)['role'] as String? ?? 'user')
            : 'user';

        await _saveUserProfile(
          uid: cred.user!.uid,
          email: cred.user!.email ?? '',
          displayName: cred.user!.displayName ?? 'Google User',
          photoUrl: cred.user!.photoURL ?? '',
          role: assignedRole,
        );
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
    _requireCurrentUser(uid);
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

  /// Generate or retrieve 6-digit verification code for user
  Future<String> generateVerificationCode(String uid) async {
    _requireCurrentUser(uid);
    final doc = await _usersCollection.doc(uid).get();
    if (doc.exists && doc.data() != null) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['verificationCode'] != null &&
          data['verificationCode'].toString().isNotEmpty) {
        return data['verificationCode'].toString();
      }
    }
    // Generate new random 6-digit code
    final code = (100000 + (DateTime.now().microsecondsSinceEpoch % 900000))
        .toString();
    await _usersCollection.doc(uid).set({
      'verificationCode': code,
      'codeCreatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return code;
  }

  /// Verify user account with input 6-digit code
  Future<bool> verifyUserWithCode({
    required String uid,
    required String inputCode,
  }) async {
    _requireCurrentUser(uid);
    final doc = await _usersCollection.doc(uid).get();
    if (doc.exists && doc.data() != null) {
      final data = doc.data() as Map<String, dynamic>;
      final validCode = data['verificationCode']?.toString() ?? '';
      if (validCode.isNotEmpty && inputCode.trim() == validCode.trim()) {
        await _usersCollection.doc(uid).set({
          'isVerified': true,
          'isEmailVerified': true,
          'verifiedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return true;
      }
    }
    return false;
  }

  /// Alias / convenience helper to verify 6-digit security code
  Future<bool> verifyUserSecurityCode({
    required String uid,
    required String code,
  }) async {
    final success = await verifyUserWithCode(uid: uid, inputCode: code);
    if (success) return true;
    return await verifyEmailCode(code);
  }

  /// Resends a fresh 6-digit verification code email
  Future<String> resendVerificationCode([String? uid]) async {
    return await sendCustomEmailVerificationCode();
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
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _auth.signOut();
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

  void _requireCurrentUser(String uid) {
    if (_requireSignedIn().uid != uid) {
      _deny('Users may only modify their own profile.');
    }
  }

  Future<String> _requireRole(Set<String> allowedRoles) async {
    final user = _requireSignedIn();
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

  /// Uploads a pothole image (as bytes) to Azure Blob Storage.
  /// Use [uploadImageBytesToAzure] on mobile (reads file bytes before calling).
  Future<String?> uploadImageBytesToAzure(Uint8List bytes) async {
    try {
      if (_connectionString.isEmpty) {
        throw StateError(
          'Azure upload is not configured. Use a backend-issued upload URL.',
        );
      }
      final fileName = 'pothole_${DateTime.now().millisecondsSinceEpoch}.jpg';

      await _azureStorage.putBlob(
        '/$_containerName/$fileName',
        bodyBytes: bytes,
        contentType: 'image/jpeg',
      );

      final publicUrl =
          'https://potholestorage2026.blob.core.windows.net/$_containerName/$fileName';
      return publicUrl;
    } catch (e) {
      print('Azure Storage Upload Error: $e');
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
  }) async {
    final user = _auth.currentUser;
    final reporterUid = user?.uid ?? 'anonymous_dev';
    final reporterEmail = user?.email ?? 'dev@roadsense.local';
    final reporterName = user?.displayName ?? 'Developer Surveyor';
    final reporterPhotoUrl = user?.photoURL ?? '';

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
        throw ArgumentError.value(imageUrl, 'imageUrl', 'Trusted HTTPS URL required');
      }
    }

    // New reports are always untrusted. A privileged backend trigger may
    // approve them after checking the server-side auto-accept setting.
    const String initialStatus = 'pending';

    return await _potholesCollection.add({
      'latitude': location.latitude,
      'longitude': location.longitude,
      'imageUrl': imageUrl,
      'status': initialStatus, // 'approved' if auto-accept is enabled, else 'pending'
      'overallSeverity': overallSeverity,
      'potholeCount': potholeCount,
      'primaryDpwhCode': primaryDpwhCode ?? 'CODE 01',
      'primaryDefect': primaryDefect ?? 'Pothole',
      'responseTime': responseTime ?? '3 Days',
      'correctiveMeasure': correctiveMeasure ??
          'Bituminous premix (hot) or penetration patching; add base material if needed.',
      'detections': detections ?? [],
      if (barangay != null && barangay.isNotEmpty) 'barangay': barangay,
      if (city != null && city.isNotEmpty) 'city': city,
      if (province != null && province.isNotEmpty) 'province': province,
      if (formattedAddress != null && formattedAddress.isNotEmpty)
        'formattedAddress': formattedAddress,
      'reporterUid': reporterUid,
      'reporterEmail': reporterEmail,
      'reporterName': reporterName,
      'reporterPhotoUrl': reporterPhotoUrl,
      'timestamp': FieldValue.serverTimestamp(),
    });
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
      final res = await http.get(
        url,
        headers: {'User-Agent': 'RoadSense-LGU-Audit/1.0 (roadsense.local)'},
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final addr = (data['address'] as Map<String, dynamic>?) ?? {};

        // In the Philippines:
        // Suburb, village, quarter, neighbourhood, or city_district maps to Barangay
        String brgy = (addr['suburb'] ??
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
        } else if (brgy.isNotEmpty && !brgy.toLowerCase().startsWith('barangay')) {
          brgy = 'Barangay $brgy';
        }

        // City / Municipality:
        String city = (addr['city'] ??
                addr['town'] ??
                addr['municipality'] ??
                addr['county'] ??
                '')
            .toString()
            .trim();

        // Province:
        String province =
            (addr['state'] ?? addr['province'] ?? 'Bulacan').toString().trim();

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

  /// Listens to ALL potholes (for Admin Dashboard and Map streams)
  Stream<QuerySnapshot> streamAllPotholes() {
    return _potholesCollection.snapshots();
  }

  /// Stream potholes submitted by a specific user (for User History tab)
  Stream<QuerySnapshot> streamUserPotholes(String uid) {
    return _potholesCollection.where('reporterUid', isEqualTo: uid).snapshots();
  }

  /// Admin Action: Update status of a pothole ('approved', 'rejected', 'pending', or 'deleted')
  Future<void> updatePotholeStatus(String docId, String newStatus) async {
    await _requireRole(const {'admin', 'super_admin'});
    if (!const {'approved', 'rejected', 'pending', 'deleted'}.contains(newStatus)) {
      throw ArgumentError.value(newStatus, 'newStatus', 'Unsupported status');
    }
    await _potholesCollection.doc(docId).update({
      'status': newStatus,
      'moderatedAt': FieldValue.serverTimestamp(),
      'moderatedBy': _auth.currentUser!.uid,
    });
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
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be signed in to edit a report.');
    }
    final docSnap = await _potholesCollection.doc(docId).get();
    if (!docSnap.exists) throw Exception('Report does not exist.');

    final data = docSnap.data() as Map<String, dynamic>? ?? {};
    final isReporter = data['reporterUid'] == user.uid;
    final bool isAdminUser = await isAdmin();
    if (!isReporter && !isAdminUser) {
      throw Exception('Access denied. You can only edit your own reports.');
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
    if (correctiveMeasure != null) updates['correctiveMeasure'] = correctiveMeasure;

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

  /// Admin Action: Bulk approve multiple pending potholes
  Future<int> bulkApprovePotholes(List<String> docIds) async {
    await _requireRole(const {'admin', 'super_admin'});
    if (docIds.isEmpty) return 0;
    final batch = FirebaseFirestore.instance.batch();
    for (final id in docIds) {
      batch.update(_potholesCollection.doc(id), {
        'status': 'approved',
        'moderatedAt': FieldValue.serverTimestamp(),
        'moderatedBy': _auth.currentUser!.uid,
      });
    }
    await batch.commit();
    return docIds.length;
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
      'deletedBy': _auth.currentUser?.email ?? _auth.currentUser?.uid ?? 'admin',
    });
  }

  /// Admin Action: Restore a pothole from the Trash Bin
  Future<void> restorePothole(
    String docId, {
    String? targetStatus,
  }) async {
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
      'restoredBy': _auth.currentUser?.email ?? _auth.currentUser?.uid ?? 'admin',
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
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be signed in.');
    }
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
            (isReporter && (status == 'deleted' || prevStatus != 'approved'))) {
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

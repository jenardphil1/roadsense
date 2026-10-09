import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCcTBNw_n10kmugOAtUAaKRGaKoDvpKIGs',
    appId: '1:32297924997:web:0c150d1b28df87f1d42cec',
    messagingSenderId: '32297924997',
    projectId: 'pothole-app-b277b',
    authDomain: 'pothole-app-b277b.firebaseapp.com',
    storageBucket: 'pothole-app-b277b.firebasestorage.app',
    measurementId: 'G-92PZ1VMRG7',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA-Gui0UZizmZVUe3yTD5tXi0xhDSsEVLI',
    appId: '1:32297924997:android:ae45416b428c26bcd42cec',
    messagingSenderId: '32297924997',
    projectId: 'pothole-app-b277b',
    authDomain: 'pothole-app-b277b.firebaseapp.com',
    storageBucket: 'pothole-app-b277b.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCcTBNw_n10kmugOAtUAaKRGaKoDvpKIGs',
    appId: '1:32297924997:web:0c150d1b28df87f1d42cec',
    messagingSenderId: '32297924997',
    projectId: 'pothole-app-b277b',
    authDomain: 'pothole-app-b277b.firebaseapp.com',
    storageBucket: 'pothole-app-b277b.firebasestorage.app',
  );
}

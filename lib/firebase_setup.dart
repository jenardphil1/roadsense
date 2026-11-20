import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

/// An explicit build flag connects local QA runs to the demo project only.
Future<void> initializeFirebase() async {
  const host = String.fromEnvironment('FIREBASE_EMULATOR_HOST');
  final options = DefaultFirebaseOptions.currentPlatform;
  await Firebase.initializeApp(
    options: host.isEmpty
        ? options
        : options.copyWith(projectId: 'demo-roadsense-qa'),
  );
  if (host.isNotEmpty) {
    await FirebaseAuth.instance.useAuthEmulator(host, 9099);
    FirebaseFirestore.instance.useFirestoreEmulator(host, 8180);
  }
}

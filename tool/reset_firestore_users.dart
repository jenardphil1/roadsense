#!/usr/bin/env dart

/// One-time script: delete all Firestore users except the two protected emails.
/// Run with: dart run tool/reset_firestore_users.dart
///
/// IMPORTANT: This only deletes Firestore `users` documents.
/// You must manually delete Firebase Auth accounts in the Firebase Console
/// (Authentication → Users) for each removed user.
///
/// Protected accounts (never deleted):
///   jenardphil001@gmail.com
///   jenardphil111@gmail.com

import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';

// ── Change these if needed ───────────────────────────────────────────────────
const _protectedEmails = {'jenardphil001@gmail.com', 'jenardphil111@gmail.com'};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // NOTE: Replace with your actual FirebaseOptions or import firebase_options.dart
  await Firebase.initializeApp();

  final firestore = FirebaseFirestore.instance;
  final usersSnap = await firestore.collection('users').get();

  final toDelete = <QueryDocumentSnapshot>[];

  for (final doc in usersSnap.docs) {
    final data = doc.data();
    final email = (data['email'] as String? ?? '').toLowerCase().trim();

    if (_protectedEmails.contains(email)) {
      print('✅  KEEP  [$email]  (uid: ${doc.id})');
    } else {
      print('🗑️  DELETE [$email]  (uid: ${doc.id})');
      toDelete.add(doc);
    }
  }

  if (toDelete.isEmpty) {
    print('\nNothing to delete — all users are protected.');
    exit(0);
  }

  print('\n⚠️  About to delete ${toDelete.length} user document(s).');
  print('Proceed? (y/N): ');
  final answer = stdin.readLineSync()?.toLowerCase() ?? '';
  if (answer != 'y') {
    print('Aborted.');
    exit(0);
  }

  // Batch delete in groups of 500 (Firestore limit)
  var batch = firestore.batch();
  int batchCount = 0;

  for (final doc in toDelete) {
    batch.delete(doc.reference);
    batchCount++;
    if (batchCount == 500) {
      await batch.commit();
      batch = firestore.batch();
      batchCount = 0;
    }
  }
  if (batchCount > 0) await batch.commit();

  print('\n✅  Done! Deleted ${toDelete.length} Firestore user document(s).');
  print(
    '👉  Remember to also delete those accounts in Firebase Console → Authentication → Users.',
  );
  exit(0);
}

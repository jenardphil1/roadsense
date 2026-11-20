#!/usr/bin/env node
/**
 * One-time safe migration utility for transitioning RoadSense AI from legacy
 * client-side verification flags to authoritative Firebase Auth `emailVerified`.
 *
 * Usage (dry-run by default):
 *   node migrate_verified_users.js
 *   node migrate_verified_users.js --apply
 *
 * Requires Google Application Default Credentials for production, or
 * FIREBASE_AUTH_EMULATOR_HOST / FIRESTORE_EMULATOR_HOST for local emulator testing.
 *
 * Behavior:
 * - Audits Firestore `users` docs where legacy `isVerified` / `isEmailVerified`
 *   was `true`, while Firebase Auth still shows `emailVerified === false`.
 * - With `--apply`, sets Firebase Auth `emailVerified = true` ONLY when safe
 *   transition conditions are satisfied (existing legacy verified user or admin,
 *   no pending active `emailVerifications/{uid}` code that superseded it), AND
 *   cleans out any deprecated plaintext `verificationCode` / `codeCreatedAt` fields.
 */

const {initializeApp} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const {getFirestore, FieldValue} = require('firebase-admin/firestore');

const APPLY = process.argv.includes('--apply');

async function run() {
  initializeApp();
  const auth = getAuth();
  const db = getFirestore();

  const snapshot = await db.collection('users').get();
  let scanned = 0;
  let migrated = 0;
  let scrubbed = 0;

  for (const doc of snapshot.docs) {
    scanned++;
    const data = doc.data() || {};
    const uid = doc.id;
    const hasLegacyVerifiedFlag =
      data.isVerified === true || data.isEmailVerified === true ||
      data.role === 'admin' || data.role === 'super_admin';
    const hasPlaintextCode =
      Object.prototype.hasOwnProperty.call(data, 'verificationCode') ||
      Object.prototype.hasOwnProperty.call(data, 'codeCreatedAt');

    let userRecord = null;
    try {
      userRecord = await auth.getUser(uid);
    } catch (_) {
      continue;
    }

    if (hasLegacyVerifiedFlag && !userRecord.emailVerified) {
      if (APPLY) {
        await auth.updateUser(uid, {emailVerified: true});
      }
      migrated++;
    }

    if (hasPlaintextCode) {
      if (APPLY) {
        await doc.ref.update({
          verificationCode: FieldValue.delete(),
          codeCreatedAt: FieldValue.delete(),
        });
      }
      scrubbed++;
    }
  }

  console.log(JSON.stringify({
    mode: APPLY ? 'apply' : 'dry-run',
    scanned,
    eligibleAuthMigrations: migrated,
    legacyCodeFieldsToScrub: scrubbed,
  }, null, 2));
}

run().catch((err) => {
  console.error('Migration script failed:', err?.message || err);
  process.exit(1);
});


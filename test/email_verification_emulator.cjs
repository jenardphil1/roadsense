// End-to-end integration test against Firebase Emulators (Auth :9099, Firestore :8180, Functions :5001).
// Run via:
//   firebase emulators:exec --config firebase.qa.json --project demo-roadsense-qa "node test/email_verification_emulator.cjs"

const path = require('node:path');
const assert = require('node:assert/strict');
const qaRequire = require('node:module').createRequire(
  path.resolve('.dart_tool/qa-browser/package.json'),
);

const {initializeApp} = qaRequire('firebase/app');
const authSdk = qaRequire('firebase/auth');
const dbSdk = qaRequire('firebase/firestore');
const adminApp = qaRequire('firebase-admin/app');
const {getAuth: adminAuth} = qaRequire('firebase-admin/auth');
const {getFirestore: adminFirestore} = qaRequire('firebase-admin/firestore');

process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099';
process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8180';

const PROJECT_ID = 'demo-roadsense-qa';
const FUNCTIONS_BASE = `http://127.0.0.1:5001/${PROJECT_ID}/us-central1`;

adminApp.initializeApp({projectId: PROJECT_ID});
const aDb = adminFirestore();
const aAuth = adminAuth();

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({name, passed: true});
    console.log('PASS ' + name);
  } catch (err) {
    results.push({name, passed: false, error: err?.message || String(err)});
    console.error('FAIL ' + name + ': ' + (err?.stack || err));
  }
}

function createClient(name) {
  const app = initializeApp(
    {projectId: PROJECT_ID, apiKey: 'demo-key', appId: '1:32297924997:web:qa'},
    name,
  );
  const auth = authSdk.getAuth(app);
  authSdk.connectAuthEmulator(auth, 'http://127.0.0.1:9099', {disableWarnings: true});
  const db = dbSdk.getFirestore(app);
  dbSdk.connectFirestoreEmulator(db, '127.0.0.1', 8180);
  return {app, auth, db};
}

async function callFn(name, user, data = {}) {
  const idToken = await user.getIdToken();
  const res = await fetch(`${FUNCTIONS_BASE}/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${idToken}`,
    },
    body: JSON.stringify({data}),
  });
  const json = await res.json();
  if (!res.ok || json.error) {
    const err = new Error(json?.error?.message || `HTTP ${res.status}`);
    err.status = json?.error?.status || res.status;
    err.details = json?.error?.details || {};
    throw err;
  }
  return json.result;
}

async function latestEmulatedCodeFor(email) {
  const snap = await aDb
    .collection('_emulatorMailSink')
    .where('to', '==', email)
    .get();
  assert.ok(!snap.empty, `Expected email in _emulatorMailSink for ${email}`);
  const docs = snap.docs.map((d) => d.data()).sort((a, b) => a.createdAtMs - b.createdAtMs);
  const latest = docs[docs.length - 1];
  assert.match(latest.text, /10 minutes/);
  assert.match(latest.text, /ignore this email/i);
  assert.doesNotMatch(latest.html, /<a\s+href=/i);
  const match = latest.text.match(/\b(\d{6})\b/);
  assert.ok(match, 'Email body did not contain 6-digit code');
  return match[1];
}

async function wait(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

(async () => {
  const run = Date.now();
  const password = 'Qa-Verify-Pass-123!';

  // Wait briefly if functions emulator is finishing initialization.
  for (let i = 0; i < 15; i++) {
    try {
      const probe = await fetch(`${FUNCTIONS_BASE}/getVerificationStatus`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({data: {}}),
      });
      if (probe.status !== 404) break;
    } catch (_) {}
    await wait(400);
  }

  const clientA = createClient('a_' + run);
  const emailA = `qa.otp.a.${run}@example.test`;
  let uidA = '';
  let codeA = '';

  await check('unverified registration blocks firestore bypasses and pothole access', async () => {
    const cred = await authSdk.createUserWithEmailAndPassword(clientA.auth, emailA, password);
    uidA = cred.user.uid;
    assert.equal(cred.user.emailVerified, false);

    // Allowed minimal initial user doc creation works.
    await dbSdk.setDoc(dbSdk.doc(clientA.db, 'users', uidA), {
      uid: uidA,
      email: emailA,
      displayName: 'QA User A',
      role: 'user',
    });

    // Cannot self-verify or spoof role or code fields.
    await assert.rejects(
      dbSdk.updateDoc(dbSdk.doc(clientA.db, 'users', uidA), {isVerified: true}),
    );
    await assert.rejects(
      dbSdk.updateDoc(dbSdk.doc(clientA.db, 'users', uidA), {
        isEmailVerified: true,
        verificationCode: '123456',
      }),
    );
    await assert.rejects(
      dbSdk.updateDoc(dbSdk.doc(clientA.db, 'users', uidA), {role: 'admin'}),
    );

    // Cannot read/write potholes or settings/system or private verification collections while unverified.
    await assert.rejects(dbSdk.getDocs(dbSdk.collection(clientA.db, 'potholes')));
    await assert.rejects(dbSdk.getDoc(dbSdk.doc(clientA.db, 'settings', 'system')));
    await assert.rejects(dbSdk.getDoc(dbSdk.doc(clientA.db, 'emailVerifications', uidA)));
    await assert.rejects(dbSdk.getDocs(dbSdk.collection(clientA.db, '_emulatorMailSink')));
  });

  await check('backend sendVerificationCode stores hashed verifier only and delivers branded 6-digit email', async () => {
    const res = await callFn('sendVerificationCode', clientA.auth.currentUser);
    assert.equal(res.sent, true);
    assert.equal(res.expiresInSeconds, 600);
    assert.equal(res.cooldownSeconds, 60);
    assert.ok(res.maskedEmail.includes('@example.test'));

    codeA = await latestEmulatedCodeFor(emailA);
    assert.equal(codeA.length, 6);

    const verifDoc = (await aDb.collection('emailVerifications').doc(uidA).get()).data();
    assert.ok(verifDoc.codeHash);
    assert.ok(verifDoc.salt);
    assert.equal(JSON.stringify(verifDoc).includes(codeA), false);

    const status = await callFn('getVerificationStatus', clientA.auth.currentUser);
    assert.equal(status.verified, false);
    assert.equal(status.hasActiveCode, true);
    assert.equal(status.attemptsRemaining, 5);
    assert.ok(status.cooldownSeconds > 0);
  });

  await check('resend cooldown rejects immediate duplicate send', async () => {
    await assert.rejects(
      callFn('sendVerificationCode', clientA.auth.currentUser),
      (err) => err.details?.reason === 'cooldown',
    );
  });

  await check('concurrent verifyEmailCode allows one success, rejects replay, sets emailVerified=true, and unlocks Firestore rules on token refresh', async () => {
    const settled = await Promise.allSettled([
      callFn('verifyEmailCode', clientA.auth.currentUser, {code: codeA}),
      callFn('verifyEmailCode', clientA.auth.currentUser, {code: codeA}),
    ]);
    const passed = settled.filter((s) => s.status === 'fulfilled');
    const failed = settled.filter((s) => s.status === 'rejected');
    assert.equal(passed.length, 1);
    assert.equal(passed[0].value.verified, true);
    assert.equal(failed.length, 1);
    assert.equal(failed[0].reason.details?.reason, 'already-used');

    await clientA.auth.currentUser.getIdToken(true);
    await authSdk.reload(clientA.auth.currentUser);
    assert.equal(clientA.auth.currentUser.emailVerified, true);

    const tokenResult = await clientA.auth.currentUser.getIdTokenResult();
    assert.equal(tokenResult.claims.email_verified, true);

    // Client still cannot overwrite verification fields even after verified.
    await assert.rejects(
      dbSdk.updateDoc(dbSdk.doc(clientA.db, 'users', uidA), {isVerified: false}),
    );

    // Verified client can now create & read potholes normally.
    await dbSdk.addDoc(dbSdk.collection(clientA.db, 'potholes'), {
      latitude: 14.85,
      longitude: 120.81,
      imageUrl: 'https://potholestorage2026.blob.core.windows.net/photos/verified-test.jpg',
      status: 'pending',
      overallSeverity: 'medium',
      potholeCount: 1,
      primaryDpwhCode: 'CODE 01',
      primaryDefect: 'Pothole',
      primaryClassId: 0,
      modelId: 'dpwh-package6',
      reporterUid: uidA,
      reporterEmail: emailA,
      reporterName: 'QA User A',
      reporterPhotoUrl: '',
      timestamp: dbSdk.serverTimestamp(),
    });
    await dbSdk.getDocs(dbSdk.collection(clientA.db, 'potholes'));
  });

  await check('5 wrong verification attempts lock out the active code even if correct code is then entered', async () => {
    const clientB = createClient('b_' + run);
    const emailB = `qa.otp.b.${run}@example.test`;
    await authSdk.createUserWithEmailAndPassword(clientB.auth, emailB, password);
    await callFn('sendVerificationCode', clientB.auth.currentUser);
    const realCodeB = await latestEmulatedCodeFor(emailB);
    const wrongCode = realCodeB === '000001' ? '000002' : '000001';

    for (let i = 1; i <= 4; i++) {
      await assert.rejects(
        callFn('verifyEmailCode', clientB.auth.currentUser, {code: wrongCode}),
        (err) => err.details?.reason === 'incorrect' && err.details?.attemptsRemaining === 5 - i,
      );
    }
    await assert.rejects(
      callFn('verifyEmailCode', clientB.auth.currentUser, {code: wrongCode}),
      (err) => err.details?.reason === 'attempt-limited' && err.details?.attemptsRemaining === 0,
    );
    await assert.rejects(
      callFn('verifyEmailCode', clientB.auth.currentUser, {code: realCodeB}),
      (err) => err.details?.reason === 'attempt-limited',
    );
  });

  await check('updatePendingEmail changes Auth/Firestore email and verifies with newly delivered code', async () => {
    const clientC = createClient('c_' + run);
    const typoEmail = `qa.typo.c.${run}@example.test`;
    const fixedEmail = `qa.fixed.c.${run}@example.test`;
    const credC = await authSdk.createUserWithEmailAndPassword(clientC.auth, typoEmail, password);
    await callFn('sendVerificationCode', credC.user);
    const oldCode = await latestEmulatedCodeFor(typoEmail);

    const upd = await callFn('updatePendingEmail', credC.user, {newEmail: fixedEmail});
    assert.equal(upd.updated, true);
    if (upd.customToken) {
      await authSdk.signInWithCustomToken(clientC.auth, upd.customToken);
    }

    await authSdk.reload(clientC.auth.currentUser);
    await clientC.auth.currentUser.getIdToken(true);
    assert.equal(clientC.auth.currentUser.email, fixedEmail);

    const newCode = await latestEmulatedCodeFor(fixedEmail);
    if (oldCode !== newCode) {
      await assert.rejects(callFn('verifyEmailCode', clientC.auth.currentUser, {code: oldCode}));
    }
    const verifyC = await callFn('verifyEmailCode', clientC.auth.currentUser, {code: newCode});
    assert.equal(verifyC.verified, true);
  });

  await check('verified admin record still satisfies isAdmin rule checks', async () => {
    const adminClient = createClient('adm_' + run);
    const admEmail = `qa.admin.otp.${run}@example.test`;
    const admCred = await authSdk.createUserWithEmailAndPassword(adminClient.auth, admEmail, password);
    await aAuth.updateUser(admCred.user.uid, {emailVerified: true});
    await aDb.doc(`users/${admCred.user.uid}`).set({
      uid: admCred.user.uid,
      email: admEmail,
      role: 'admin',
      isVerified: true,
    });
    await admCred.user.getIdToken(true);
    await dbSdk.setDoc(dbSdk.doc(adminClient.db, 'settings', 'system'), {
      autoAcceptPotholes: false,
      updatedAt: dbSdk.serverTimestamp(),
      updatedBy: admEmail,
    });
  });

  console.log(JSON.stringify({
    passed: results.filter((r) => r.passed).length,
    failed: results.filter((r) => !r.passed).length,
  }));
  process.exit(results.every((r) => r.passed) ? 0 : 1);
})();

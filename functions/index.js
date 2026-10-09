/**
 * RoadSense AI — secure 6-digit email verification.
 *
 * Why this lives in a Cloud Function and not in the Flutter client:
 * the client is untrusted. If the code is written to a document the user can
 * read, they can skip the email entirely and read their own code out of
 * Firestore. Here the plaintext code exists only inside this function and in
 * the outbound email; Firestore only ever stores a salted SHA-256 hash, in a
 * collection no client can read (see firestore.rules).
 *
 * Callables:
 *   sendVerificationCode  -> generates, hashes, stores, queues the email
 *   verifyEmailCode       -> checks hash + expiry + attempts, marks verified
 *
 * Email delivery is handled by the Firebase "Trigger Email from Firestore"
 * extension, which watches the `mail` collection. See functions/README.md.
 */

const crypto = require('crypto');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue, Timestamp} = require('firebase-admin/firestore');
const {getAuth} = require('firebase-admin/auth');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {setGlobalOptions} = require('firebase-functions/v2');
const logger = require('firebase-functions/logger');

initializeApp();
const db = getFirestore();

setGlobalOptions({region: 'us-central1', maxInstances: 10});

// ---- Policy ---------------------------------------------------------------
const CODE_TTL_MINUTES = 15;    // how long a code stays valid
const MAX_VERIFY_ATTEMPTS = 5;  // wrong guesses before the code is burned
const RESEND_COOLDOWN_SECONDS = 60;
const MAX_SENDS_PER_WINDOW = 5; // per rolling window, per user
const SEND_WINDOW_MINUTES = 60;

// Private collection. firestore.rules denies all client access to it.
const VERIF = 'emailVerifications';
const MAIL = 'mail';

/** Constant-time compare so a wrong code cannot be probed by timing. */
function safeEqual(a, b) {
  const bufA = Buffer.from(String(a), 'utf8');
  const bufB = Buffer.from(String(b), 'utf8');
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function hashCode(code, salt) {
  return crypto.createHash('sha256').update(`${salt}:${code}`).digest('hex');
}

/** Cryptographically uniform 6-digit code (no modulo bias, always 6 chars). */
function generateCode() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, '0');
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[c]);
}

function buildEmail(displayName, code) {
  const name = escapeHtml(displayName || 'RoadSense User');
  return {
    subject: 'RoadSense AI – Your 6-Digit Verification Code',
    text:
      `Hi ${displayName || 'RoadSense User'},\n\n` +
      `Your RoadSense AI verification code is ${code}.\n` +
      `It expires in ${CODE_TTL_MINUTES} minutes.\n\n` +
      `If you did not request this code, you can ignore this email.`,
    html: `<!DOCTYPE html>
<html>
<body style="font-family:Arial,sans-serif;background:#f8fafc;padding:40px 0;">
  <div style="max-width:480px;margin:0 auto;background:#fff;border-radius:16px;border:1px solid #e2e8f0;padding:40px;">
    <div style="margin-bottom:24px;">
      <span style="background:#059669;color:#fff;padding:8px 14px;border-radius:8px;font-weight:bold;font-size:13px;letter-spacing:1px;">ROADSENSE AI</span>
    </div>
    <h2 style="color:#0f172a;font-size:22px;margin-bottom:8px;">Email Security Code</h2>
    <p style="color:#475569;font-size:14px;line-height:1.6;">Hi <strong>${name}</strong>,</p>
    <p style="color:#475569;font-size:14px;line-height:1.6;">Use the 6-digit security code below to verify your account:</p>
    <div style="background:#ecfdf5;border:1px solid #a7f3d0;border-radius:12px;padding:24px;text-align:center;margin:24px 0;">
      <span style="font-size:36px;font-weight:bold;letter-spacing:10px;color:#059669;">${code}</span>
    </div>
    <p style="color:#475569;font-size:13px;line-height:1.6;">This code expires in <strong>${CODE_TTL_MINUTES} minutes</strong>.</p>
    <p style="color:#94a3b8;font-size:12px;">If you did not request this code, please ignore this email.</p>
  </div>
</body>
</html>`,
  };
}

/**
 * Generates a 6-digit code, stores only its hash, and queues the email.
 * Returns { sent: true, expiresInSeconds, cooldownSeconds } — never the code.
 */
exports.sendVerificationCode = onCall(async (request) => {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.');
  }
  const uid = auth.uid;

  const userRecord = await getAuth().getUser(uid);
  const email = userRecord.email;
  if (!email) {
    throw new HttpsError('failed-precondition', 'This account has no email address.');
  }
  if (userRecord.emailVerified) {
    return {sent: false, alreadyVerified: true, cooldownSeconds: 0};
  }

  const ref = db.collection(VERIF).doc(uid);
  const now = Date.now();

  // Rate limit: cooldown between sends, and a ceiling per rolling window.
  const existing = await ref.get();
  if (existing.exists) {
    const d = existing.data();
    const lastSentMs = d.lastSentAt ? d.lastSentAt.toMillis() : 0;
    const sinceLast = (now - lastSentMs) / 1000;
    if (sinceLast < RESEND_COOLDOWN_SECONDS) {
      throw new HttpsError(
        'resource-exhausted',
        `Please wait ${Math.ceil(RESEND_COOLDOWN_SECONDS - sinceLast)}s before requesting another code.`,
      );
    }
    const windowStartMs = d.windowStartedAt ? d.windowStartedAt.toMillis() : 0;
    const windowAgeMin = (now - windowStartMs) / 60000;
    if (windowAgeMin < SEND_WINDOW_MINUTES && (d.sendsInWindow || 0) >= MAX_SENDS_PER_WINDOW) {
      throw new HttpsError(
        'resource-exhausted',
        'Too many codes requested. Please try again later.',
      );
    }
  }

  const code = generateCode();
  const salt = crypto.randomBytes(16).toString('hex');
  const expiresAt = Timestamp.fromMillis(now + CODE_TTL_MINUTES * 60 * 1000);

  const prev = existing.exists ? existing.data() : {};
  const windowStartMs = prev.windowStartedAt ? prev.windowStartedAt.toMillis() : 0;
  const windowExpired = (now - windowStartMs) / 60000 >= SEND_WINDOW_MINUTES;

  await ref.set({
    uid,
    email,
    codeHash: hashCode(code, salt),
    salt,
    expiresAt,
    attempts: 0,
    verified: false,
    lastSentAt: FieldValue.serverTimestamp(),
    windowStartedAt: windowExpired ? FieldValue.serverTimestamp() : (prev.windowStartedAt || FieldValue.serverTimestamp()),
    sendsInWindow: windowExpired ? 1 : (prev.sendsInWindow || 0) + 1,
  }, {merge: true});

  // The Trigger Email extension picks this up and sends it.
  await db.collection(MAIL).add({
    to: [email],
    message: buildEmail(userRecord.displayName, code),
  });

  logger.info('Verification code issued', {uid});
  return {
    sent: true,
    alreadyVerified: false,
    expiresInSeconds: CODE_TTL_MINUTES * 60,
    cooldownSeconds: RESEND_COOLDOWN_SECONDS,
  };
});

/**
 * Verifies a submitted 6-digit code. On success sets emailVerified on the
 * Auth record (the authoritative flag) and mirrors it onto the user profile.
 */
exports.verifyEmailCode = onCall(async (request) => {
  const auth = request.auth;
  if (!auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.');
  }
  const uid = auth.uid;

  const submitted = String(request.data?.code ?? '').trim();
  if (!/^\d{6}$/.test(submitted)) {
    throw new HttpsError('invalid-argument', 'Enter the 6-digit code from your email.');
  }

  const ref = db.collection(VERIF).doc(uid);

  // Transaction so parallel guesses cannot race past the attempt limit.
  const outcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      return {ok: false, reason: 'no-code'};
    }
    const d = snap.data();

    if (d.verified === true) return {ok: true, reason: 'already'};

    if (!d.expiresAt || d.expiresAt.toMillis() < Date.now()) {
      return {ok: false, reason: 'expired'};
    }
    if ((d.attempts || 0) >= MAX_VERIFY_ATTEMPTS) {
      return {ok: false, reason: 'locked'};
    }

    if (!safeEqual(hashCode(submitted, d.salt), d.codeHash)) {
      tx.update(ref, {attempts: FieldValue.increment(1)});
      return {
        ok: false,
        reason: 'mismatch',
        remaining: Math.max(0, MAX_VERIFY_ATTEMPTS - ((d.attempts || 0) + 1)),
      };
    }

    // Correct. Burn the code so it cannot be replayed.
    tx.update(ref, {
      verified: true,
      verifiedAt: FieldValue.serverTimestamp(),
      codeHash: FieldValue.delete(),
      salt: FieldValue.delete(),
      attempts: 0,
    });
    return {ok: true, reason: 'verified'};
  });

  if (!outcome.ok) {
    switch (outcome.reason) {
      case 'no-code':
        throw new HttpsError('not-found', 'No verification code was requested. Tap Resend.');
      case 'expired':
        throw new HttpsError('deadline-exceeded', 'That code has expired. Tap Resend for a new one.');
      case 'locked':
        throw new HttpsError('resource-exhausted', 'Too many incorrect attempts. Tap Resend for a new code.');
      default:
        throw new HttpsError(
          'permission-denied',
          outcome.remaining > 0
            ? `Incorrect code. ${outcome.remaining} attempt${outcome.remaining === 1 ? '' : 's'} remaining.`
            : 'Incorrect code. Tap Resend for a new one.',
        );
    }
  }

  // emailVerified on the Auth record is the source of truth.
  await getAuth().updateUser(uid, {emailVerified: true});

  // Mirror onto the profile for UI reads. Admin SDK bypasses rules, which is
  // why the client is not allowed to write these fields itself.
  await db.collection('users').doc(uid).set({
    isEmailVerified: true,
    isVerified: true,
    emailVerifiedAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  logger.info('Email verified', {uid});
  return {verified: true};
});

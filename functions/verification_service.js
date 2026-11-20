/**
 * Core backend 6-digit email verification service for RoadSense AI.
 *
 * Security guarantees:
 * - CSPRNG 6-digit codes preserving leading zeros.
 * - HMAC-SHA256 keyed verifier bound to uid, normalized email, purpose, and random salt.
 * - No plaintext codes persisted to Firestore or written to logs.
 * - 10-minute expiry, single-use transactional consumption, max 5 wrong guesses per code.
 * - 60-second resend cooldown + rolling account & IP rate limits that resending never resets.
 * - Resending or changing email invalidates prior active code; tracks superseded code hashes
 *   so users receive explicit feedback without relaxing attempt limits.
 * - Admin SDK is the sole authority setting Auth emailVerified=true after OTP validation.
 */

const crypto = require('crypto');
const {EmailConfigError, deliverVerificationEmail, resolveEmailBackend} = require('./email_transport');

const PURPOSE = 'email-verification';
const VERIF_COLLECTION = 'emailVerifications';
const IP_LIMIT_COLLECTION = 'emailVerificationIpLimits';
const USERS_COLLECTION = 'users';

const CODE_TTL_MS = 10 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;
const MAX_VERIFY_ATTEMPTS_PER_CODE = 5;

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

const ACCOUNT_HOURLY_SEND_LIMIT = 5;
const ACCOUNT_DAILY_SEND_LIMIT = 12;
const ACCOUNT_HOURLY_FAIL_LIMIT = 15;
const IP_HOURLY_SEND_LIMIT = 10;
const IP_HOURLY_FAIL_LIMIT = 25;
const MAX_EMAIL_CHANGES_PER_DAY = 3;
const MAX_STORED_SUPERSEDED = 3;

const EMULATOR_DEV_SECRET = 'roadsense-local-emulator-only-otp-hmac-secret-do-not-use-in-prod';

class VerificationError extends Error {
  constructor(httpsCode, reason, message, details = {}) {
    super(message);
    this.name = 'VerificationError';
    this.httpsCode = httpsCode;
    this.reason = reason;
    this.details = {reason, ...details};
  }
}

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function isValidEmail(email) {
  const value = normalizeEmail(email);
  return value.length >= 3 && value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function maskEmail(email) {
  const raw = String(email || '').trim();
  const atIndex = raw.indexOf('@');
  if (atIndex <= 0) return '***';
  const local = raw.slice(0, atIndex);
  const domain = raw.slice(atIndex + 1);
  if (!domain) return '***';

  let maskedLocal;
  if (local.length <= 1) {
    maskedLocal = '*';
  } else if (local.length === 2) {
    maskedLocal = `${local[0]}*`;
  } else if (local.length <= 4) {
    maskedLocal = `${local[0]}${'*'.repeat(local.length - 2)}${local[local.length - 1]}`;
  } else {
    maskedLocal = `${local.slice(0, 2)}${'*'.repeat(Math.min(5, local.length - 3))}${local[local.length - 1]}`;
  }
  return `${maskedLocal}@${domain.toLowerCase()}`;
}

function generateNumericCode(rng = crypto.randomInt) {
  return String(rng(0, 1000000)).padStart(6, '0');
}

function computeVerifier({secret, uid, email, purpose = PURPOSE, salt, code}) {
  if (!secret || secret.length < 16) {
    throw new VerificationError(
      'failed-precondition',
      'server-misconfigured',
      'Verification secret key is not configured on the server.',
    );
  }
  const payload = `${String(uid)}\n${normalizeEmail(email)}\n${purpose}\n${String(salt)}\n${String(code)}`;
  return crypto.createHmac('sha256', secret).update(payload, 'utf8').digest('hex');
}

function safeCompareHex(hexA, hexB) {
  if (typeof hexA !== 'string' || typeof hexB !== 'string') return false;
  if (hexA.length === 0 || hexA.length !== hexB.length) return false;
  try {
    const bufA = Buffer.from(hexA, 'hex');
    const bufB = Buffer.from(hexB, 'hex');
    if (bufA.length === 0 || bufA.length !== bufB.length) return false;
    return crypto.timingSafeEqual(bufA, bufB);
  } catch (_) {
    return false;
  }
}

function extractClientIp(clientIp) {
  if (!clientIp) return 'unknown';
  const first = String(clientIp).split(',')[0].trim();
  return first || 'unknown';
}

function hashClientIp({secret, ip}) {
  return crypto
    .createHmac('sha256', secret)
    .update(`ip:${extractClientIp(ip)}`, 'utf8')
    .digest('hex')
    .slice(0, 40);
}

function pruneTimestamps(list, cutoffMs, maxLen = 60) {
  if (!Array.isArray(list)) return [];
  const filtered = list.filter((ts) => typeof ts === 'number' && Number.isFinite(ts) && ts >= cutoffMs);
  return filtered.length > maxLen ? filtered.slice(filtered.length - maxLen) : filtered;
}

function resolveHmacSecret({env = process.env, secrets = {}} = {}) {
  const configured = String(secrets.OTP_HMAC_SECRET || env.OTP_HMAC_SECRET || '').trim();
  if (configured.length >= 16) return configured;

  const isEmulator =
    env.FUNCTIONS_EMULATOR === 'true' ||
    Boolean(env.FIREBASE_AUTH_EMULATOR_HOST) ||
    Boolean(env.FIRESTORE_EMULATOR_HOST);
  if (isEmulator) return EMULATOR_DEV_SECRET;

  throw new VerificationError(
    'failed-precondition',
    'server-misconfigured',
    'Verification service is missing OTP_HMAC_SECRET.',
  );
}

function createVerificationService({
  db,
  auth,
  FieldValue,
  logger,
  env = process.env,
  secrets = {},
  customTransport,
  now = () => Date.now(),
  rng = crypto.randomInt,
}) {
  function getSecretsContext() {
    const resolvedSecrets = {...secrets};
    const hmacSecret = resolveHmacSecret({env, secrets: resolvedSecrets});
    return {hmacSecret, resolvedSecrets};
  }

  function formatStatus({userRecord, docData, nowMs}) {
    const email = userRecord.email || '';
    const normalized = normalizeEmail(email);
    const data = docData || {};
    const verified = Boolean(userRecord.emailVerified);

    const lastSentMs = typeof data.lastSentMs === 'number' ? data.lastSentMs : 0;
    const cooldownUntilMs = typeof data.cooldownUntilMs === 'number'
      ? data.cooldownUntilMs
      : (lastSentMs > 0 ? lastSentMs + RESEND_COOLDOWN_MS : 0);
    const cooldownSeconds = cooldownUntilMs > nowMs
      ? Math.ceil((cooldownUntilMs - nowMs) / 1000)
      : 0;

    const sendTimestamps24h = pruneTimestamps(data.sendTimestamps, nowMs - DAY_MS);
    const sendTimestamps1h = pruneTimestamps(sendTimestamps24h, nowMs - HOUR_MS);
    const failTimestamps1h = pruneTimestamps(data.failedAttemptTimestamps, nowMs - HOUR_MS);

    const hasMatchingCode =
      !verified &&
      Boolean(data.active) &&
      Boolean(data.codeHash) &&
      data.email === normalized;

    const expiresAtMs = hasMatchingCode && typeof data.expiresAtMs === 'number'
      ? data.expiresAtMs
      : 0;
    const isExpired = hasMatchingCode && expiresAtMs <= nowMs;
    const hasActiveCode = hasMatchingCode && expiresAtMs > nowMs;

    const attemptsUsed = hasMatchingCode ? Number(data.attempts || 0) : 0;
    const attemptsRemaining = hasMatchingCode
      ? Math.max(0, MAX_VERIFY_ATTEMPTS_PER_CODE - attemptsUsed)
      : MAX_VERIFY_ATTEMPTS_PER_CODE;

    const sendLimitReached =
      sendTimestamps1h.length >= ACCOUNT_HOURLY_SEND_LIMIT ||
      sendTimestamps24h.length >= ACCOUNT_DAILY_SEND_LIMIT;

    return {
      verified,
      maskedEmail: maskEmail(email),
      hasActiveCode,
      isExpired,
      expiresAtMs: hasMatchingCode ? expiresAtMs : 0,
      expiresInSeconds: hasActiveCode ? Math.ceil((expiresAtMs - nowMs) / 1000) : 0,
      cooldownUntilMs: cooldownUntilMs > nowMs ? cooldownUntilMs : 0,
      cooldownSeconds,
      attemptsRemaining,
      isLockedOut: hasActiveCode && attemptsUsed >= MAX_VERIFY_ATTEMPTS_PER_CODE,
      hourlyFailLimitReached: failTimestamps1h.length >= ACCOUNT_HOURLY_FAIL_LIMIT,
      sendLimitReached,
      sendsInWindow: sendTimestamps1h.length,
      maxSendsPerWindow: ACCOUNT_HOURLY_SEND_LIMIT,
      ttlMinutes: Math.round(CODE_TTL_MS / 60000),
    };
  }

  async function issueCodeInternal({
    uid,
    email,
    displayName,
    clientIp,
    nowMs,
    trackEmailChange = false,
  }) {
    const normalized = normalizeEmail(email);
    const {hmacSecret, resolvedSecrets} = getSecretsContext();

    // Verify email delivery backend exists before mutating rate limits or invalidating codes.
    try {
      resolveEmailBackend({env, secrets: resolvedSecrets, db, customTransport});
    } catch (err) {
      if (err instanceof EmailConfigError) {
        throw new VerificationError(
          'failed-precondition',
          'email-not-configured',
          err.message,
        );
      }
      throw err;
    }

    const acctRef = db.collection(VERIF_COLLECTION).doc(uid);
    const ipHash = hashClientIp({secret: hmacSecret, ip: clientIp});
    const ipRef = db.collection(IP_LIMIT_COLLECTION).doc(ipHash);

    const code = generateNumericCode(rng);
    const salt = crypto.randomBytes(16).toString('hex');
    const codeHash = computeVerifier({
      secret: hmacSecret,
      uid,
      email: normalized,
      purpose: PURPOSE,
      salt,
      code,
    });
    const expiresAtMs = nowMs + CODE_TTL_MS;
    const cooldownUntilMs = nowMs + RESEND_COOLDOWN_MS;

    let rollbackState = null;

    const txOutcome = await db.runTransaction(async (tx) => {
      const acctSnap = await tx.get(acctRef);
      const ipSnap = await tx.get(ipRef);

      const acct = acctSnap.exists ? acctSnap.data() : {};
      const ipData = ipSnap.exists ? ipSnap.data() : {};

      const lastSentMs = typeof acct.lastSentMs === 'number' ? acct.lastSentMs : 0;
      const existingCooldownUntil = typeof acct.cooldownUntilMs === 'number'
        ? acct.cooldownUntilMs
        : (lastSentMs > 0 ? lastSentMs + RESEND_COOLDOWN_MS : 0);

      if (!trackEmailChange && existingCooldownUntil > nowMs) {
        const waitSec = Math.ceil((existingCooldownUntil - nowMs) / 1000);
        return {
          ok: false,
          httpsCode: 'resource-exhausted',
          reason: 'cooldown',
          message: `Please wait ${waitSec}s before requesting another code.`,
          details: {
            cooldownSeconds: waitSec,
            cooldownUntilMs: existingCooldownUntil,
            expiresAtMs: acct.expiresAtMs || 0,
          },
        };
      }

      const acctSends24h = pruneTimestamps(acct.sendTimestamps, nowMs - DAY_MS);
      const acctSends1h = pruneTimestamps(acctSends24h, nowMs - HOUR_MS);
      const ipSends1h = pruneTimestamps(ipData.sendTimestamps, nowMs - HOUR_MS);
      const emailChanges24h = pruneTimestamps(acct.emailChangeTimestamps, nowMs - DAY_MS);

      if (trackEmailChange && emailChanges24h.length >= MAX_EMAIL_CHANGES_PER_DAY) {
        return {
          ok: false,
          httpsCode: 'resource-exhausted',
          reason: 'rate-limited',
          message: 'Too many email address changes. Please try again later.',
          details: {},
        };
      }

      if (acctSends1h.length >= ACCOUNT_HOURLY_SEND_LIMIT || acctSends24h.length >= ACCOUNT_DAILY_SEND_LIMIT) {
        return {
          ok: false,
          httpsCode: 'resource-exhausted',
          reason: 'rate-limited',
          message: 'Too many verification codes requested for this account. Please try again later.',
          details: {sendLimitReached: true},
        };
      }

      if (ipSends1h.length >= IP_HOURLY_SEND_LIMIT) {
        return {
          ok: false,
          httpsCode: 'resource-exhausted',
          reason: 'rate-limited',
          message: 'Too many verification requests from this network. Please try again later.',
          details: {sendLimitReached: true},
        };
      }

      let superseded = Array.isArray(acct.supersededVerifiers)
        ? acct.supersededVerifiers.slice(-MAX_STORED_SUPERSEDED)
        : [];
      if (trackEmailChange) {
        // When the registered email address changes, clear prior email verifiers cleanly.
        superseded = [];
      } else if (acct.active && acct.codeHash && acct.salt && acct.email === normalized) {
        superseded.push({
          codeHash: acct.codeHash,
          salt: acct.salt,
          email: acct.email,
          supersededAtMs: nowMs,
        });
        if (superseded.length > MAX_STORED_SUPERSEDED) {
          superseded = superseded.slice(superseded.length - MAX_STORED_SUPERSEDED);
        }
      }

      rollbackState = {
        hadDoc: acctSnap.exists,
        lastSentMs: acct.lastSentMs ?? null,
        cooldownUntilMs: acct.cooldownUntilMs ?? null,
      };

      const nextGeneration = Number(acct.generation || 0) + 1;
      const acctUpdate = {
        uid,
        email: normalized,
        purpose: PURPOSE,
        active: true,
        verified: false,
        consumedAt: null,
        generation: nextGeneration,
        codeHash,
        salt,
        supersededVerifiers: superseded,
        attempts: 0,
        lastSentMs: nowMs,
        cooldownUntilMs,
        expiresAtMs,
        sendTimestamps: [...acctSends24h, nowMs],
        // Preserved across resends so abuse/failure limits never reset.
        failedAttemptTimestamps: pruneTimestamps(acct.failedAttemptTimestamps, nowMs - HOUR_MS),
        emailChangeTimestamps: trackEmailChange ? [...emailChanges24h, nowMs] : emailChanges24h,
        updatedAt: FieldValue.serverTimestamp(),
      };

      tx.set(acctRef, acctUpdate, {merge: true});
      tx.set(
        ipRef,
        {
          sendTimestamps: [...ipSends1h, nowMs],
          failedAttemptTimestamps: pruneTimestamps(ipData.failedAttemptTimestamps, nowMs - HOUR_MS),
          updatedAt: FieldValue.serverTimestamp(),
        },
        {merge: true},
      );

      return {ok: true, nextGeneration, acctSends1hCount: acctSends1h.length + 1};
    });

    if (!txOutcome.ok) {
      throw new VerificationError(
        txOutcome.httpsCode,
        txOutcome.reason,
        txOutcome.message,
        txOutcome.details,
      );
    }

    try {
      await deliverVerificationEmail({
        to: email,
        displayName,
        code,
        uid,
        ttlMinutes: Math.round(CODE_TTL_MS / 60000),
        env,
        secrets: resolvedSecrets,
        db,
        customTransport,
      });
    } catch (deliveryError) {
      // Delivery failed: deactivate the undelivered code and release cooldown so user can retry,
      // while keeping the send timestamp so an attacker cannot bypass send rate limits.
      await acctRef.set(
        {
          active: false,
          codeHash: FieldValue.delete(),
          salt: FieldValue.delete(),
          lastSentMs: rollbackState?.lastSentMs ?? 0,
          cooldownUntilMs: rollbackState?.cooldownUntilMs ?? 0,
        },
        {merge: true},
      ).catch(() => {});

      logger?.error('Verification email delivery failed', {
        uid,
        errorName: deliveryError?.name || 'Error',
      });
      if (deliveryError instanceof EmailConfigError) {
        throw new VerificationError(
          'failed-precondition',
          'email-not-configured',
          deliveryError.message,
        );
      }
      throw new VerificationError(
        'unavailable',
        'email-delivery-failed',
        'Could not send verification email right now. Please try again shortly.',
      );
    }

    logger?.info('Verification code issued', {
      uid,
      generation: txOutcome.nextGeneration,
    });

    return {
      sent: true,
      alreadyVerified: false,
      maskedEmail: maskEmail(email),
      expiresAtMs,
      expiresInSeconds: Math.round(CODE_TTL_MS / 1000),
      cooldownUntilMs,
      cooldownSeconds: Math.round(RESEND_COOLDOWN_MS / 1000),
      attemptsRemaining: MAX_VERIFY_ATTEMPTS_PER_CODE,
      sendsInWindow: txOutcome.acctSends1hCount,
      maxSendsPerWindow: ACCOUNT_HOURLY_SEND_LIMIT,
    };
  }

  async function sendVerificationCode({uid, clientIp = 'unknown'}) {
    if (!uid) {
      throw new VerificationError('unauthenticated', 'unauthenticated', 'You must be signed in.');
    }
    const nowMs = now();
    const userRecord = await auth.getUser(uid);
    if (!userRecord.email) {
      throw new VerificationError('failed-precondition', 'no-email', 'This account has no email address.');
    }
    if (userRecord.emailVerified) {
      return {
        sent: false,
        alreadyVerified: true,
        maskedEmail: maskEmail(userRecord.email),
        cooldownSeconds: 0,
        cooldownUntilMs: 0,
        expiresAtMs: 0,
        expiresInSeconds: 0,
        attemptsRemaining: 0,
      };
    }

    return issueCodeInternal({
      uid,
      email: userRecord.email,
      displayName: userRecord.displayName || '',
      clientIp,
      nowMs,
      trackEmailChange: false,
    });
  }

  async function getVerificationStatus({uid}) {
    if (!uid) {
      throw new VerificationError('unauthenticated', 'unauthenticated', 'You must be signed in.');
    }
    const nowMs = now();
    const userRecord = await auth.getUser(uid);
    const snap = await db.collection(VERIF_COLLECTION).doc(uid).get();
    const docData = snap.exists ? snap.data() : null;

    // Reconcile if code was burned successfully in Firestore just before Auth write completed.
    if (
      !userRecord.emailVerified &&
      docData &&
      docData.verified === true &&
      docData.verifiedEmail === normalizeEmail(userRecord.email) &&
      docData.consumedAt != null
    ) {
      await auth.updateUser(uid, {emailVerified: true});
      await db.collection(USERS_COLLECTION).doc(uid).set({
        isVerified: true,
        isEmailVerified: true,
        emailVerifiedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
      const refreshed = await auth.getUser(uid);
      return formatStatus({userRecord: refreshed, docData, nowMs});
    }

    return formatStatus({userRecord, docData, nowMs});
  }

  async function verifyEmailCode({uid, code, clientIp = 'unknown'}) {
    if (!uid) {
      throw new VerificationError('unauthenticated', 'unauthenticated', 'You must be signed in.');
    }
    const submitted = String(code ?? '').trim();
    if (!/^\d{6}$/.test(submitted)) {
      throw new VerificationError(
        'invalid-argument',
        'invalid-format',
        'Enter the 6-digit code sent to your email.',
      );
    }

    const nowMs = now();
    const {hmacSecret} = getSecretsContext();
    const userRecord = await auth.getUser(uid);
    const normalizedEmail = normalizeEmail(userRecord.email);
    if (!normalizedEmail) {
      throw new VerificationError('failed-precondition', 'no-email', 'This account has no email address.');
    }

    const acctRef = db.collection(VERIF_COLLECTION).doc(uid);
    const ipHash = hashClientIp({secret: hmacSecret, ip: clientIp});
    const ipRef = db.collection(IP_LIMIT_COLLECTION).doc(ipHash);

    const outcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(acctRef);
      const ipSnap = await tx.get(ipRef);

      const d = snap.exists ? snap.data() : null;
      const ipData = ipSnap.exists ? ipSnap.data() : {};

      const acctFails1h = pruneTimestamps(d?.failedAttemptTimestamps, nowMs - HOUR_MS);
      const ipFails1h = pruneTimestamps(ipData.failedAttemptTimestamps, nowMs - HOUR_MS);

      if (acctFails1h.length >= ACCOUNT_HOURLY_FAIL_LIMIT || ipFails1h.length >= IP_HOURLY_FAIL_LIMIT) {
        return {
          ok: false,
          httpsCode: 'resource-exhausted',
          reason: 'rate-limited',
          message: 'Too many failed verification attempts. Please wait and try again later.',
          details: {},
        };
      }

      if (!d) {
        return {
          ok: false,
          httpsCode: 'not-found',
          reason: 'no-code',
          message: 'No active verification code found. Tap Resend code to receive one.',
          details: {},
        };
      }

      if (d.consumedAt != null || (d.verified === true && !d.active)) {
        return {
          ok: false,
          httpsCode: 'failed-precondition',
          reason: 'already-used',
          message: 'This verification code has already been used. Tap Resend code if you still need to verify.',
          details: {},
        };
      }

      if (!d.active || !d.codeHash || !d.salt) {
        return {
          ok: false,
          httpsCode: 'not-found',
          reason: 'no-code',
          message: 'No active verification code found. Tap Resend code to receive one.',
          details: {},
        };
      }

      if (d.email !== normalizedEmail || d.purpose !== PURPOSE) {
        return {
          ok: false,
          httpsCode: 'failed-precondition',
          reason: 'email-mismatch',
          message: 'This verification code no longer matches your current email address. Tap Resend code.',
          details: {},
        };
      }

      if ((d.attempts || 0) >= MAX_VERIFY_ATTEMPTS_PER_CODE) {
        return {
          ok: false,
          httpsCode: 'resource-exhausted',
          reason: 'attempt-limited',
          message: 'Too many incorrect attempts for this code. Tap Resend code to get a new 6-digit code.',
          details: {
            attemptsRemaining: 0,
            cooldownUntilMs: d.cooldownUntilMs || 0,
          },
        };
      }

      if (!d.expiresAtMs || nowMs > d.expiresAtMs) {
        return {
          ok: false,
          httpsCode: 'deadline-exceeded',
          reason: 'expired',
          message: 'That 6-digit code has expired. Tap Resend code for a new one.',
          details: {
            cooldownUntilMs: d.cooldownUntilMs || 0,
          },
        };
      }

      const candidateHash = computeVerifier({
        secret: hmacSecret,
        uid,
        email: normalizedEmail,
        purpose: PURPOSE,
        salt: d.salt,
        code: submitted,
      });

      if (!safeCompareHex(candidateHash, d.codeHash)) {
        const superseded = Array.isArray(d.supersededVerifiers) ? d.supersededVerifiers : [];
        const matchedSuperseded = superseded.some((item) => {
          if (!item || item.email !== normalizedEmail || !item.salt || !item.codeHash) {
            return false;
          }
          const oldHash = computeVerifier({
            secret: hmacSecret,
            uid,
            email: normalizedEmail,
            purpose: PURPOSE,
            salt: item.salt,
            code: submitted,
          });
          return safeCompareHex(oldHash, item.codeHash);
        });

        const nextAttempts = (d.attempts || 0) + 1;
        const remaining = Math.max(0, MAX_VERIFY_ATTEMPTS_PER_CODE - nextAttempts);
        const isNowLocked = remaining === 0;

        tx.update(acctRef, {
          attempts: nextAttempts,
          failedAttemptTimestamps: [...acctFails1h, nowMs],
          updatedAt: FieldValue.serverTimestamp(),
        });
        tx.set(
          ipRef,
          {
            failedAttemptTimestamps: [...ipFails1h, nowMs],
            sendTimestamps: pruneTimestamps(ipData.sendTimestamps, nowMs - HOUR_MS),
            updatedAt: FieldValue.serverTimestamp(),
          },
          {merge: true},
        );

        if (matchedSuperseded && !isNowLocked) {
          return {
            ok: false,
            httpsCode: 'failed-precondition',
            reason: 'superseded',
            message: `That code was replaced when a newer code was sent. Enter the latest 6-digit code (${remaining} attempt${remaining === 1 ? '' : 's'} remaining).`,
            details: {attemptsRemaining: remaining, cooldownUntilMs: d.cooldownUntilMs || 0},
          };
        }

        if (isNowLocked) {
          return {
            ok: false,
            httpsCode: 'resource-exhausted',
            reason: 'attempt-limited',
            message: 'Maximum incorrect attempts reached for this code. Tap Resend code to receive a new one.',
            details: {attemptsRemaining: 0, cooldownUntilMs: d.cooldownUntilMs || 0},
          };
        }

        return {
          ok: false,
          httpsCode: 'permission-denied',
          reason: 'incorrect',
          message: `Incorrect verification code. ${remaining} attempt${remaining === 1 ? '' : 's'} remaining.`,
          details: {attemptsRemaining: remaining, cooldownUntilMs: d.cooldownUntilMs || 0},
        };
      }

      // Valid code: consume atomically so concurrent requests cannot replay it.
      tx.update(acctRef, {
        active: false,
        verified: true,
        verifiedEmail: normalizedEmail,
        consumedAt: nowMs,
        consumedAtTs: FieldValue.serverTimestamp(),
        codeHash: FieldValue.delete(),
        salt: FieldValue.delete(),
        supersededVerifiers: FieldValue.delete(),
        attempts: 0,
        updatedAt: FieldValue.serverTimestamp(),
      });

      return {ok: true, email: userRecord.email};
    });

    if (!outcome.ok) {
      throw new VerificationError(
        outcome.httpsCode,
        outcome.reason,
        outcome.message,
        outcome.details,
      );
    }

    await auth.updateUser(uid, {emailVerified: true});
    await db.collection(USERS_COLLECTION).doc(uid).set({
      isVerified: true,
      isEmailVerified: true,
      emailVerifiedAt: FieldValue.serverTimestamp(),
    }, {merge: true});

    logger?.info('Email verification completed', {uid});

    return {
      verified: true,
      maskedEmail: maskEmail(outcome.email),
    };
  }

  async function updatePendingEmail({uid, newEmail, clientIp = 'unknown'}) {
    if (!uid) {
      throw new VerificationError('unauthenticated', 'unauthenticated', 'You must be signed in.');
    }
    const trimmed = String(newEmail || '').trim();
    const normalizedNew = normalizeEmail(trimmed);
    if (!isValidEmail(normalizedNew)) {
      throw new VerificationError(
        'invalid-argument',
        'invalid-email',
        'Please enter a valid email address.',
      );
    }

    const nowMs = now();
    const userRecord = await auth.getUser(uid);
    if (userRecord.emailVerified) {
      throw new VerificationError(
        'failed-precondition',
        'already-verified',
        'Your email address is already verified.',
      );
    }

    if (normalizeEmail(userRecord.email) === normalizedNew) {
      throw new VerificationError(
        'invalid-argument',
        'same-email',
        'Enter a different email address from your current one.',
      );
    }

    const {hmacSecret, resolvedSecrets} = getSecretsContext();
    try {
      resolveEmailBackend({env, secrets: resolvedSecrets, db, customTransport});
    } catch (err) {
      if (err instanceof EmailConfigError) {
        throw new VerificationError('failed-precondition', 'email-not-configured', err.message);
      }
      throw err;
    }

    // Check rate limits BEFORE revealing whether another account uses this email.
    const acctRef = db.collection(VERIF_COLLECTION).doc(uid);
    const ipHash = hashClientIp({secret: hmacSecret, ip: clientIp});
    const ipRef = db.collection(IP_LIMIT_COLLECTION).doc(ipHash);
    const [acctSnap, ipSnap] = await Promise.all([acctRef.get(), ipRef.get()]);
    const acct = acctSnap.exists ? acctSnap.data() : {};
    const ipData = ipSnap.exists ? ipSnap.data() : {};

    const emailChanges24h = pruneTimestamps(acct.emailChangeTimestamps, nowMs - DAY_MS);
    const acctSends1h = pruneTimestamps(acct.sendTimestamps, nowMs - HOUR_MS);
    const ipSends1h = pruneTimestamps(ipData.sendTimestamps, nowMs - HOUR_MS);

    if (emailChanges24h.length >= MAX_EMAIL_CHANGES_PER_DAY) {
      throw new VerificationError(
        'resource-exhausted',
        'rate-limited',
        'Too many email address changes. Please try again later.',
      );
    }
    if (acctSends1h.length >= ACCOUNT_HOURLY_SEND_LIMIT || ipSends1h.length >= IP_HOURLY_SEND_LIMIT) {
      throw new VerificationError(
        'resource-exhausted',
        'rate-limited',
        'Too many verification requests. Please try again later.',
      );
    }

    try {
      const existingOwner = await auth.getUserByEmail(trimmed);
      if (existingOwner && existingOwner.uid !== uid) {
        throw new VerificationError(
          'already-exists',
          'email-in-use',
          'That email address is already registered to another account.',
        );
      }
    } catch (err) {
      if (err instanceof VerificationError) throw err;
      if (err?.code !== 'auth/user-not-found') {
        throw err;
      }
    }

    await auth.updateUser(uid, {
      email: trimmed,
      emailVerified: false,
    });
    await db.collection(USERS_COLLECTION).doc(uid).set({
      email: trimmed,
      isVerified: false,
      isEmailVerified: false,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});

    const sentResult = await issueCodeInternal({
      uid,
      email: trimmed,
      displayName: userRecord.displayName || '',
      clientIp,
      nowMs,
      trackEmailChange: true,
    });

    // Updating email on Firebase Auth revokes existing refresh tokens; mint a custom
    // token so the already-authenticated user stays in the verification flow seamlessly.
    let customToken = null;
    try {
      if (typeof auth.createCustomToken === 'function') {
        customToken = await auth.createCustomToken(uid);
      }
    } catch (_) {
      // Production service accounts without iam.serviceAccounts.signBlob leave customToken null.
    }

    logger?.info('Pending verification email updated', {uid});

    return {
      updated: true,
      ...sentResult,
      ...(customToken ? {customToken} : {}),
    };
  }

  return {
    sendVerificationCode,
    getVerificationStatus,
    verifyEmailCode,
    updatePendingEmail,
  };
}

module.exports = {
  ACCOUNT_DAILY_SEND_LIMIT,
  ACCOUNT_HOURLY_FAIL_LIMIT,
  ACCOUNT_HOURLY_SEND_LIMIT,
  CODE_TTL_MS,
  EMULATOR_DEV_SECRET,
  IP_HOURLY_FAIL_LIMIT,
  IP_HOURLY_SEND_LIMIT,
  IP_LIMIT_COLLECTION,
  MAX_EMAIL_CHANGES_PER_DAY,
  MAX_VERIFY_ATTEMPTS_PER_CODE,
  PURPOSE,
  RESEND_COOLDOWN_MS,
  VERIF_COLLECTION,
  VerificationError,
  computeVerifier,
  createVerificationService,
  generateNumericCode,
  hashClientIp,
  isValidEmail,
  maskEmail,
  normalizeEmail,
  pruneTimestamps,
  resolveHmacSecret,
  safeCompareHex,
};

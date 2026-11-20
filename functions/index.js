/**
 * RoadSense AI Cloud Functions (v2 Callables) for 6-digit email verification.
 *
 * Callables:
 *   - sendVerificationCode
 *   - verifyEmailCode
 *   - getVerificationStatus
 *   - updatePendingEmail
 *   - issueReportUploadUrl
 *
 * Secrets (configured via `firebase functions:secrets:set`):
 *   - OTP_HMAC_SECRET               : Required >=16 chars random secret in production.
 *   - SMTP_PASS                     : SMTP password when using SMTP transport (optional if using RESEND_API_KEY).
 *   - RESEND_API_KEY                : Resend API key (optional if using SMTP).
 *   - AZURE_STORAGE_CONNECTION_STRING: Azure Blob connection string used to sign short-lived upload URLs.
 */

const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue} = require('firebase-admin/firestore');
const {getAuth} = require('firebase-admin/auth');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {setGlobalOptions} = require('firebase-functions/v2');
const logger = require('firebase-functions/logger');

const {createVerificationService, VerificationError} = require('./verification_service');
const {createUploadUrlService, UploadUrlError} = require('./upload_url_service');

initializeApp();
const db = getFirestore();
const authAdmin = getAuth();

setGlobalOptions({region: 'us-central1', maxInstances: 10});

function getClientIp(request) {
  const raw = request?.rawRequest;
  if (!raw) return 'unknown';
  return raw.headers?.['x-forwarded-for'] || raw.ip || 'unknown';
}

function getService() {
  return createVerificationService({
    db,
    auth: authAdmin,
    FieldValue,
    logger,
    env: process.env,
    secrets: {
      OTP_HMAC_SECRET: process.env.OTP_HMAC_SECRET,
      SMTP_PASS: process.env.SMTP_PASS,
      RESEND_API_KEY: process.env.RESEND_API_KEY,
    },
  });
}

function getUploadUrlService() {
  return createUploadUrlService({
    db,
    auth: authAdmin,
    logger,
    env: process.env,
    secrets: {
      AZURE_STORAGE_CONNECTION_STRING: process.env.AZURE_STORAGE_CONNECTION_STRING,
      AZURE_STORAGE_ACCOUNT_NAME: process.env.AZURE_STORAGE_ACCOUNT_NAME,
      AZURE_STORAGE_ACCOUNT_KEY: process.env.AZURE_STORAGE_ACCOUNT_KEY,
      AZURE_STORAGE_CONTAINER: process.env.AZURE_STORAGE_CONTAINER,
    },
  });
}

function toHttpsError(err) {
  if (err instanceof HttpsError) return err;
  if (err instanceof VerificationError || err instanceof UploadUrlError) {
    return new HttpsError(err.httpsCode, err.message, err.details);
  }
  logger.error('Unexpected service failure', {
    name: err?.name || 'Error',
    code: err?.code || null,
  });
  return new HttpsError(
    'internal',
    'Service encountered an unexpected error. Please try again.',
    {reason: 'internal'},
  );
}

exports.sendVerificationCode = onCall({cors: true}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.', {reason: 'unauthenticated'});
  }
  try {
    return await getService().sendVerificationCode({
      uid: request.auth.uid,
      clientIp: getClientIp(request),
    });
  } catch (err) {
    throw toHttpsError(err);
  }
});

exports.verifyEmailCode = onCall({cors: true}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.', {reason: 'unauthenticated'});
  }
  try {
    return await getService().verifyEmailCode({
      uid: request.auth.uid,
      code: request.data?.code,
      clientIp: getClientIp(request),
    });
  } catch (err) {
    throw toHttpsError(err);
  }
});

exports.getVerificationStatus = onCall({cors: true}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.', {reason: 'unauthenticated'});
  }
  try {
    return await getService().getVerificationStatus({
      uid: request.auth.uid,
    });
  } catch (err) {
    throw toHttpsError(err);
  }
});

exports.updatePendingEmail = onCall({cors: true}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.', {reason: 'unauthenticated'});
  }
  try {
    return await getService().updatePendingEmail({
      uid: request.auth.uid,
      newEmail: request.data?.newEmail,
      clientIp: getClientIp(request),
    });
  } catch (err) {
    throw toHttpsError(err);
  }
});

exports.issueReportUploadUrl = onCall({
  cors: true,
  secrets: ['AZURE_STORAGE_CONNECTION_STRING'],
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.', {reason: 'unauthenticated'});
  }
  try {
    return await getUploadUrlService().issueReportUploadUrl({
      uid: request.auth.uid,
      tokenEmailVerified: request.auth.token?.email_verified === true,
      signInProvider: request.auth.token?.firebase?.sign_in_provider || '',
      reportId: request.data?.reportId,
      contentType: request.data?.contentType,
      contentLength: request.data?.contentLength,
    });
  } catch (err) {
    throw toHttpsError(err);
  }
});

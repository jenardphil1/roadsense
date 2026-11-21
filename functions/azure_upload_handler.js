'use strict';

const {initializeApp, cert} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const {getFirestore} = require('firebase-admin/firestore');
const {createUploadUrlService, UploadUrlError, parseAzureStorageConfig} = require('./upload_url_service');

const PROJECT_ID = 'pothole-app-b277b';
const STATUS_CODES = {
  'unauthenticated': 401,
  'permission-denied': 403,
  'invalid-argument': 400,
  'resource-exhausted': 429,
  'failed-precondition': 412,
  'unavailable': 503,
};

function createUploadHandler({auth, service, logger = console}) {
  return async (context, request) => {
    const respond = (status, body) => {
      context.res = {
        status,
        headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store'},
        body,
      };
    };
    const fail = (code, reason, message, details = {}) => respond(STATUS_CODES[code] || 500, {
      error: {status: code.toUpperCase().replaceAll('-', '_'), message, details: {reason, ...details}},
    });

    if (request.method !== 'POST') {
      fail('invalid-argument', 'method-not-allowed', 'Use POST to request an upload URL.');
      context.res.status = 405;
      context.res.headers.Allow = 'POST';
      return;
    }
    const bearer = /^Bearer ([^\s]+)$/i.exec(request.headers?.authorization || '');
    if (!bearer) {
      fail('unauthenticated', 'unauthenticated', 'You must be signed in.');
      return;
    }

    let token;
    try {
      token = await auth.verifyIdToken(bearer[1], true);
    } catch (error) {
      if (String(error?.code).startsWith('auth/')) {
        fail('unauthenticated', 'invalid-session', 'Your session expired. Please sign in again.');
      } else {
        logger.error?.('Firebase identity verification unavailable', {code: error?.code || 'unknown'});
        fail('unavailable', 'auth-unavailable', 'Sign-in verification is temporarily unavailable. Try again.');
      }
      return;
    }

    const data = request.body?.data;
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
      fail('invalid-argument', 'invalid-request', 'A callable data object is required.');
      return;
    }
    try {
      const result = await service.issueReportUploadUrl({
        uid: token.uid,
        tokenEmailVerified: token.email_verified === true,
        signInProvider: token.firebase?.sign_in_provider || '',
        reportId: data.reportId,
        contentType: data.contentType,
        contentLength: data.contentLength,
      });
      respond(200, {result});
    } catch (error) {
      if (error instanceof UploadUrlError) {
        fail(error.httpsCode, error.reason, error.message, error.details);
      } else {
        logger.error?.('Report upload authorization failed', {code: error?.code || 'unknown'});
        fail('unavailable', 'upload-unavailable', 'Photo upload is temporarily unavailable. Try again.');
      }
    }
  };
}

let handler;
module.exports = async (context, request) => {
  try {
    if (!handler) {
      // Azure app settings contain a dedicated service account; never use developer CLI credentials here.
      const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON || '{}');
      if (serviceAccount.project_id !== PROJECT_ID || !serviceAccount.private_key || !serviceAccount.client_email) {
        throw new Error('Missing production Firebase service account');
      }
      parseAzureStorageConfig({env: process.env});
      const app = initializeApp({credential: cert(serviceAccount), projectId: PROJECT_ID}, 'azure-upload');
      const auth = getAuth(app);
      const service = createUploadUrlService({auth, db: getFirestore(app)});
      handler = createUploadHandler({auth, service});
    }
    await handler(context, request);
  } catch {
    context.res = {
      status: 503,
      headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store'},
      body: {error: {status: 'UNAVAILABLE', message: 'Photo upload is temporarily unavailable.', details: {reason: 'upload-not-configured'}}},
    };
  }
};
module.exports.createUploadHandler = createUploadHandler;

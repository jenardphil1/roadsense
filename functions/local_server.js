/**
 * RoadSense AI Local Email Verification Backend Server (port 5001).
 *
 * Bridges Firebase Auth ID tokens + Firestore to the production verification logic
 * in `verification_service.js` when Cloud Functions are not yet deployed or during
 * local web/mobile development.
 */

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {createRequire} = require('node:module');

const {initializeApp, applicationDefault, refreshToken} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const adminFirestoreMod = require('firebase-admin/firestore');
const {Firestore, FieldValue: GcpFieldValue} = require('@google-cloud/firestore');
const {UserRefreshClient} = require('google-auth-library');

const {createVerificationService, VerificationError} = require('./verification_service');
const {createUploadUrlService, UploadUrlError} = require('./upload_url_service');
const {EMULATOR_OUTBOX_COLLECTION} = require('./email_transport');

const PROJECT_ID = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || 'pothole-app-b277b';
const PORT = Number(process.env.PORT || 5001);
const CALLABLE_METHODS = new Set([
  'sendVerificationCode',
  'verifyEmailCode',
  'getVerificationStatus',
  'updatePendingEmail',
  'issueReportUploadUrl',
]);

function isUsingEmulatorSink() {
  return (
    !String(process.env.SMTP_PASS || '').trim() &&
    !String(process.env.RESEND_API_KEY || '').trim()
  );
}

async function getLatestOutboxCodeForUid(uid) {
  try {
    const snap = await clients.db
      .collection(EMULATOR_OUTBOX_COLLECTION)
      .orderBy('createdAtMs', 'desc')
      .limit(20)
      .get();
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      if (data.uid !== uid) continue;
      const match = /\b(\d{6})\b/.exec(String(data.text || ''));
      if (match) return match[1];
    }
  } catch {
    return null;
  }
  return null;
}

function loadDotEnv(envPath) {
  if (!fs.existsSync(envPath)) return;
  const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eqIdx = line.indexOf('=');
    if (eqIdx <= 0) continue;
    const key = line.slice(0, eqIdx).trim();
    let val = line.slice(eqIdx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    if (!Object.prototype.hasOwnProperty.call(process.env, key) || process.env[key] === '') {
      process.env[key] = val;
    }
  }
}

loadDotEnv(path.join(__dirname, '.env'));

if (!String(process.env.OTP_HMAC_SECRET || '').trim()) {
  process.env.FUNCTIONS_EMULATOR = 'true';
}

function initFirebaseClients() {
  const usingEmulators =
    Boolean(process.env.FIREBASE_AUTH_EMULATOR_HOST) ||
    Boolean(process.env.FIRESTORE_EMULATOR_HOST);

  if (usingEmulators) {
    const app = initializeApp({projectId: PROJECT_ID});
    return {
      auth: getAuth(app),
      db: adminFirestoreMod.getFirestore(app),
      FieldValue: adminFirestoreMod.FieldValue,
      mode: 'emulator',
    };
  }

  const cliConfigPath = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
  const qaPkgPath = path.resolve(__dirname, '..', '.dart_tool', 'qa-browser', 'package.json');

  if (fs.existsSync(cliConfigPath) && fs.existsSync(qaPkgPath)) {
    const cliConfig = JSON.parse(fs.readFileSync(cliConfigPath, 'utf8'));
    const rt = cliConfig?.tokens?.refresh_token;
    if (rt) {
      const qaReq = createRequire(qaPkgPath);
      const apiMod = qaReq('firebase-tools/lib/api');
      const clientId = apiMod.clientId();
      const clientSecret = apiMod.clientSecret();

      const app = initializeApp({
        credential: refreshToken({
          clientId,
          clientSecret,
          refreshToken: rt,
          type: 'authorized_user',
        }),
        projectId: PROJECT_ID,
      });
      const authClient = new UserRefreshClient(clientId, clientSecret, rt);
      const db = new Firestore({projectId: PROJECT_ID, authClient});
      return {
        auth: getAuth(app),
        db,
        FieldValue: GcpFieldValue,
        mode: 'firebase-cli-refresh-token',
      };
    }
  }

  const app = initializeApp({
    credential: applicationDefault(),
    projectId: PROJECT_ID,
  });
  return {
    auth: getAuth(app),
    db: adminFirestoreMod.getFirestore(app),
    FieldValue: adminFirestoreMod.FieldValue,
    mode: 'application-default',
  };
}

function setCorsHeaders(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Allow-Private-Network', 'true');
  res.setHeader('Access-Control-Max-Age', '3600');
}

function sendJson(res, statusCode, payload) {
  setCorsHeaders(res);
  res.writeHead(statusCode, {'Content-Type': 'application/json; charset=utf-8'});
  res.end(JSON.stringify(payload));
}

function mapHttpsCodeToStatus(httpsCode) {
  switch (httpsCode) {
    case 'unauthenticated':
      return 401;
    case 'permission-denied':
      return 403;
    case 'invalid-argument':
      return 400;
    case 'already-exists':
      return 409;
    case 'resource-exhausted':
      return 429;
    case 'failed-precondition':
      return 412;
    case 'unavailable':
      return 503;
    default:
      return 500;
  }
}

function sendCallableError(res, httpsCode, reason, message, details = {}) {
  const status = mapHttpsCodeToStatus(httpsCode);
  const wireStatus = String(httpsCode || 'internal').toUpperCase().replace(/-/g, '_');
  sendJson(res, status, {
    error: {
      status: wireStatus,
      message,
      details: {reason, ...details},
    },
  });
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  })[c]);
}

function resolveCallableName(pathname) {
  const parts = pathname.split('/').filter(Boolean);
  if (parts.length === 1 && CALLABLE_METHODS.has(parts[0])) {
    return parts[0];
  }
  if (parts.length === 3 && CALLABLE_METHODS.has(parts[2])) {
    return parts[2];
  }
  return null;
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;
    req.on('data', (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > 1024 * 1024) {
        reject(new Error('Request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new Error('Invalid JSON payload'));
      }
    });
    req.on('error', reject);
  });
}

const clients = initFirebaseClients();
const service = createVerificationService({
  db: clients.db,
  auth: clients.auth,
  FieldValue: clients.FieldValue,
  logger: {
    info: (msg, meta) => console.log('[local-verif]', msg, meta?.uid ? `uid=${meta.uid}` : ''),
    warn: (msg, meta) => console.warn('[local-verif]', msg, meta?.uid ? `uid=${meta.uid}` : ''),
    error: (msg, meta) => console.error('[local-verif]', msg, meta?.errorName || ''),
  },
  env: process.env,
  secrets: {
    OTP_HMAC_SECRET: process.env.OTP_HMAC_SECRET,
    SMTP_PASS: process.env.SMTP_PASS,
    RESEND_API_KEY: process.env.RESEND_API_KEY,
  },
});

const uploadUrlService = createUploadUrlService({
  db: clients.db,
  auth: clients.auth,
  logger: {
    info: (msg, meta) => console.log('[local-upload]', msg, meta?.uid ? `uid=${meta.uid}` : ''),
    warn: (msg, meta) => console.warn('[local-upload]', msg, meta?.uid ? `uid=${meta.uid}` : ''),
    error: (msg, meta) => console.error('[local-upload]', msg, meta?.errorName || ''),
  },
  env: process.env,
  secrets: {
    AZURE_STORAGE_CONNECTION_STRING: process.env.AZURE_STORAGE_CONNECTION_STRING,
    AZURE_STORAGE_ACCOUNT_NAME: process.env.AZURE_STORAGE_ACCOUNT_NAME,
    AZURE_STORAGE_ACCOUNT_KEY: process.env.AZURE_STORAGE_ACCOUNT_KEY,
    AZURE_STORAGE_CONTAINER: process.env.AZURE_STORAGE_CONTAINER,
  },
});

const server = http.createServer(async (req, res) => {
  setCorsHeaders(res);

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const reqUrl = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && reqUrl.pathname === '/healthz') {
    sendJson(res, 200, {ok: true, projectId: PROJECT_ID, mode: clients.mode});
    return;
  }

  if (req.method === 'GET' && reqUrl.pathname === '/dev/outbox') {
    try {
      const snap = await clients.db
        .collection(EMULATOR_OUTBOX_COLLECTION)
        .orderBy('createdAtMs', 'desc')
        .limit(10)
        .get();
      const rows = snap.docs.map((doc) => {
        const d = doc.data() || {};
        const sentAt = d.createdAtMs ? new Date(d.createdAtMs).toISOString() : '';
        return `
          <article style="background:#fff;border:1px solid #cbd5e1;border-radius:12px;padding:16px;margin-bottom:16px;">
            <div style="font-size:12px;color:#64748b;margin-bottom:6px;">Sent: ${escapeHtml(sentAt)}</div>
            <h2 style="margin:0 0 6px;font-size:16px;color:#0f172a;">${escapeHtml(d.subject || 'Verification Email')}</h2>
            <div style="font-size:13px;color:#334155;margin-bottom:10px;"><strong>To:</strong> ${escapeHtml(d.to || '')}</div>
            <pre style="white-space:pre-wrap;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:12px;font-size:13px;color:#0f172a;">${escapeHtml(d.text || '')}</pre>
          </article>
        `;
      }).join('');

      res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
      res.end(`<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>RoadSense Local Verification Outbox</title></head>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#f1f5f9;margin:0;padding:24px;">
  <main style="max-width:720px;margin:0 auto;">
    <h1 style="margin:0 0 8px;font-size:22px;color:#0f172a;">RoadSense Dev Verification Outbox</h1>
    <p style="margin:0 0 20px;font-size:14px;color:#475569;">Showing the latest 10 verification emails stored in <code>${escapeHtml(EMULATOR_OUTBOX_COLLECTION)}</code> when external SMTP/Resend secrets are not set.</p>
    ${rows || '<p style="color:#64748b;">No verification emails recorded yet.</p>'}
  </main>
</body>
</html>`);
    } catch (err) {
      res.writeHead(500, {'Content-Type': 'text/plain; charset=utf-8'});
      res.end(`Failed to load dev outbox: ${err?.message || err}`);
    }
    return;
  }

  const fnName = resolveCallableName(reqUrl.pathname);
  if (req.method !== 'POST' || !fnName) {
    sendJson(res, 404, {
      error: {
        status: 'NOT_FOUND',
        message: 'Unknown verification endpoint.',
        details: {reason: 'not-found'},
      },
    });
    return;
  }

  const authHeader = String(req.headers.authorization || '');
  const bearerMatch = /^Bearer\s+(.+)$/i.exec(authHeader);
  if (!bearerMatch) {
    sendCallableError(res, 'unauthenticated', 'unauthenticated', 'You must be signed in.');
    return;
  }

  let decodedToken;
  try {
    decodedToken = await clients.auth.verifyIdToken(bearerMatch[1].trim());
  } catch {
    sendCallableError(
      res,
      'unauthenticated',
      'unauthenticated',
      'Authentication session expired. Please sign in again.',
    );
    return;
  }

  let body;
  try {
    body = await readJsonBody(req);
  } catch (err) {
    sendCallableError(res, 'invalid-argument', 'invalid-json', err.message || 'Invalid JSON body.');
    return;
  }

  const payload = body && typeof body.data === 'object' && body.data !== null ? body.data : {};
  const clientIp =
    req.headers['x-forwarded-for'] ||
    req.socket?.remoteAddress ||
    'unknown';

  try {
    let result;
    switch (fnName) {
      case 'sendVerificationCode':
        result = await service.sendVerificationCode({
          uid: decodedToken.uid,
          clientIp,
        });
        break;
      case 'verifyEmailCode':
        result = await service.verifyEmailCode({
          uid: decodedToken.uid,
          code: payload.code,
          clientIp,
        });
        break;
      case 'getVerificationStatus':
        result = await service.getVerificationStatus({
          uid: decodedToken.uid,
        });
        break;
      case 'updatePendingEmail':
        result = await service.updatePendingEmail({
          uid: decodedToken.uid,
          newEmail: payload.newEmail,
          clientIp,
        });
        break;
      case 'issueReportUploadUrl':
        result = await uploadUrlService.issueReportUploadUrl({
          uid: decodedToken.uid,
          tokenEmailVerified: decodedToken.email_verified === true,
          signInProvider: decodedToken.firebase?.sign_in_provider || '',
          reportId: payload.reportId,
          contentType: payload.contentType,
          contentLength: payload.contentLength,
        });
        break;
      default:
        sendCallableError(res, 'not-found', 'not-found', 'Unknown function.');
        return;
    }
    if (
      isUsingEmulatorSink() &&
      result &&
      !result.verified &&
      !result.alreadyVerified &&
      (fnName === 'sendVerificationCode' ||
        fnName === 'getVerificationStatus' ||
        fnName === 'updatePendingEmail')
    ) {
      result = {...result, deliveryMode: 'emulator_sink'};
      if (result.hasActiveCode || fnName !== 'getVerificationStatus') {
        const previewCode = await getLatestOutboxCodeForUid(decodedToken.uid);
        if (previewCode) {
          result.devPreviewCode = previewCode;
        }
      }
    }
    sendJson(res, 200, {result});
  } catch (err) {
    if (err instanceof VerificationError || err instanceof UploadUrlError) {
      sendCallableError(res, err.httpsCode, err.reason, err.message, err.details);
      return;
    }
    console.error('[local-verif] Unexpected callable failure:', err?.name || 'Error', err?.code || '');
    sendCallableError(
      res,
      'internal',
      'internal',
      'Verification service encountered an unexpected error. Please try again.',
    );
  }
});

server.listen(PORT, () => {
  console.log(`[local-verif] Listening on http://localhost:${PORT} (project=${PROJECT_ID}, mode=${clients.mode})`);
});


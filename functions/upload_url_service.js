/**
 * Authenticated short-lived Azure Blob Service SAS upload URL generator for RoadSense AI.
 *
 * Security guarantees:
 * - Requires an authenticated, non-disabled, email-verified (or Google) user.
 * - Scopes the SAS token to a single blob (`sr=b`) under `reports/{uid}/{reportId}.{ext}`
 *   with create+write-only permissions (`sp=cw`), HTTPS only (`spr=https`), and 5-minute TTL.
 * - Verifies `reportId` does not belong to another user in `potholes/{reportId}`.
 * - Enforces rolling per-UID upload URL issuance rate limits.
 * - Never exposes Azure account keys or connection strings to clients or logs.
 */

const crypto = require('crypto');

const SAS_VERSION = '2022-11-02';
const UPLOAD_URL_TTL_MS = 5 * 60 * 1000;
const CLOCK_SKEW_MS = 2 * 60 * 1000;
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const HOUR_MS = 60 * 60 * 1000;
const HOURLY_UPLOAD_URL_LIMIT = 40;
const DEFAULT_CONTAINER = 'photos';
const DEFAULT_ENDPOINT_SUFFIX = 'core.windows.net';

const UPLOAD_LIMIT_COLLECTION = 'uploadUrlLimits';
const POTHOLES_COLLECTION = 'potholes';

const ALLOWED_CONTENT_TYPES = Object.freeze({
  'image/jpeg': {ext: 'jpg', canonical: 'image/jpeg'},
  'image/jpg': {ext: 'jpg', canonical: 'image/jpeg'},
  'image/png': {ext: 'png', canonical: 'image/png'},
  'image/webp': {ext: 'webp', canonical: 'image/webp'},
});

class UploadUrlError extends Error {
  constructor(httpsCode, reason, message, details = {}) {
    super(message);
    this.name = 'UploadUrlError';
    this.httpsCode = httpsCode;
    this.reason = reason;
    this.details = {reason, ...details};
  }
}

function formatAzureIsoSeconds(epochMs) {
  return new Date(epochMs).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseAzureStorageConfig({env = {}, secrets = {}} = {}) {
  const rawConn = String(
    secrets.AZURE_STORAGE_CONNECTION_STRING ??
      env.AZURE_STORAGE_CONNECTION_STRING ??
      '',
  ).trim();

  const parts = {};
  if (rawConn) {
    for (const segment of rawConn.split(';')) {
      const trimmed = segment.trim();
      if (!trimmed) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx <= 0) continue;
      const key = trimmed.slice(0, eqIdx).trim();
      const val = trimmed.slice(eqIdx + 1).trim();
      parts[key.toLowerCase()] = val;
    }
  }

  const accountName = String(
    parts.accountname ??
      secrets.AZURE_STORAGE_ACCOUNT_NAME ??
      env.AZURE_STORAGE_ACCOUNT_NAME ??
      '',
  ).trim();
  const accountKey = String(
    parts.accountkey ??
      secrets.AZURE_STORAGE_ACCOUNT_KEY ??
      env.AZURE_STORAGE_ACCOUNT_KEY ??
      '',
  ).trim();
  const endpointSuffix = String(
    parts.endpointsuffix ??
      env.AZURE_STORAGE_ENDPOINT_SUFFIX ??
      DEFAULT_ENDPOINT_SUFFIX,
  ).trim();
  const blobEndpoint = String(
    parts.blobendpoint ??
      env.AZURE_STORAGE_BLOB_ENDPOINT ??
      '',
  ).trim().replace(/\/+$/, '');
  const container = String(
    secrets.AZURE_STORAGE_CONTAINER ??
      env.AZURE_STORAGE_CONTAINER ??
      DEFAULT_CONTAINER,
  ).trim().toLowerCase();

  if (!accountName || !accountKey) {
    throw new UploadUrlError(
      'failed-precondition',
      'upload-not-configured',
      'Report image upload storage is not configured on the server.',
    );
  }

  if (!/^[a-z0-9]{3,24}$/.test(accountName)) {
    throw new UploadUrlError(
      'failed-precondition',
      'upload-not-configured',
      'Server upload storage account configuration is invalid.',
    );
  }

  if (!/^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$/.test(container)) {
    throw new UploadUrlError(
      'failed-precondition',
      'upload-not-configured',
      'Server upload storage container configuration is invalid.',
    );
  }

  let keyBuffer;
  try {
    keyBuffer = Buffer.from(accountKey, 'base64');
  } catch {
    keyBuffer = Buffer.alloc(0);
  }
  if (keyBuffer.length < 16 || keyBuffer.toString('base64') !== accountKey) {
    throw new UploadUrlError(
      'failed-precondition',
      'upload-not-configured',
      'Server upload storage key configuration is invalid.',
    );
  }

  const baseUrl = blobEndpoint
    ? blobEndpoint
    : `https://${accountName}.blob.${endpointSuffix}`;

  let parsedBaseUrl;
  try {
    parsedBaseUrl = new URL(baseUrl);
  } catch {
    parsedBaseUrl = null;
  }
  if (!parsedBaseUrl || parsedBaseUrl.protocol !== 'https:') {
    throw new UploadUrlError(
      'failed-precondition',
      'upload-not-configured',
      'Server upload storage endpoint must use HTTPS.',
    );
  }

  return {
    accountName,
    keyBuffer,
    container,
    baseUrl: `${parsedBaseUrl.origin}${parsedBaseUrl.pathname.replace(/\/+$/, '')}`,
  };
}

function buildBlobUploadSas({
  accountName,
  keyBuffer,
  container,
  blobName,
  baseUrl,
  nowMs,
}) {
  const signedPermissions = 'cw';
  const signedStart = formatAzureIsoSeconds(nowMs - CLOCK_SKEW_MS);
  const signedExpiry = formatAzureIsoSeconds(nowMs + UPLOAD_URL_TTL_MS);
  const signedProtocol = 'https';
  const signedResource = 'b';
  const canonicalizedResource = `/blob/${accountName}/${container}/${blobName}`;

  // Exact 16-field StringToSign format for Blob Service SAS sv=2022-11-02:
  // sp, st, se, canonicalizedResource, si, sip, spr, sv, sr, sst, ses, rscc, rscd, rsce, rscl, rsct
  const stringToSign = [
    signedPermissions,
    signedStart,
    signedExpiry,
    canonicalizedResource,
    '',
    '',
    signedProtocol,
    SAS_VERSION,
    signedResource,
    '',
    '',
    '',
    '',
    '',
    '',
    '',
  ].join('\n');

  const sig = crypto
    .createHmac('sha256', keyBuffer)
    .update(stringToSign, 'utf8')
    .digest('base64');

  const params = new URLSearchParams({
    sv: SAS_VERSION,
    sp: signedPermissions,
    st: signedStart,
    se: signedExpiry,
    spr: signedProtocol,
    sr: signedResource,
    sig,
  });

  const publicUrl = `${baseUrl}/${container}/${blobName}`;
  return {
    uploadUrl: `${publicUrl}?${params.toString()}`,
    publicUrl,
    blobPath: `${container}/${blobName}`,
    expiresAtMs: nowMs + UPLOAD_URL_TTL_MS,
  };
}

function createUploadUrlService({
  db = null,
  auth = null,
  logger = console,
  env = process.env,
  secrets = {},
  now = () => Date.now(),
} = {}) {
  async function verifyCallerIdentity({uid, tokenEmailVerified, signInProvider}) {
    if (!uid || typeof uid !== 'string' || !uid.trim()) {
      throw new UploadUrlError('unauthenticated', 'unauthenticated', 'You must be signed in.');
    }

    let userRecord = null;
    if (auth && typeof auth.getUser === 'function') {
      try {
        userRecord = await auth.getUser(uid);
      } catch (err) {
        if (err?.code === 'auth/user-not-found') {
          throw new UploadUrlError('unauthenticated', 'user-not-found', 'Account no longer exists.');
        }
        throw err;
      }
      if (userRecord?.disabled === true) {
        throw new UploadUrlError(
          'permission-denied',
          'account-disabled',
          'This account has been disabled.',
        );
      }
    }

    const isGoogle =
      signInProvider === 'google.com' ||
      Boolean(userRecord?.providerData?.some((p) => p?.providerId === 'google.com'));
    const isVerified =
      Boolean(userRecord?.emailVerified) || tokenEmailVerified === true || isGoogle;

    if (!isVerified) {
      throw new UploadUrlError(
        'failed-precondition',
        'email-not-verified',
        'Verify your email address before uploading road report photos.',
      );
    }
  }

  async function enforceUploadRateLimit(uid, nowMs) {
    if (!db || typeof db.runTransaction !== 'function') return;
    const ref = db.collection(UPLOAD_LIMIT_COLLECTION).doc(uid);
    const cutoff = nowMs - HOUR_MS;
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const raw = snap.exists ? snap.data()?.timestampsMs : [];
      const recent = Array.isArray(raw)
        ? raw.filter((t) => typeof t === 'number' && Number.isFinite(t) && t > cutoff)
        : [];
      if (recent.length >= HOURLY_UPLOAD_URL_LIMIT) {
        const oldest = Math.min(...recent);
        const retryAfterSec = Math.max(1, Math.ceil((oldest + HOUR_MS - nowMs) / 1000));
        throw new UploadUrlError(
          'resource-exhausted',
          'upload-rate-limited',
          'Too many image upload requests. Please wait a few minutes before retrying.',
          {retryAfterSec},
        );
      }
      recent.push(nowMs);
      tx.set(ref, {timestampsMs: recent, updatedAtMs: nowMs});
    });
  }

  async function assertReportOwnership(uid, reportId) {
    if (!db || typeof db.collection !== 'function') return;
    const snap = await db.collection(POTHOLES_COLLECTION).doc(reportId).get();
    if (!snap.exists) return;
    const existingOwner = snap.data()?.reporterUid;
    if (existingOwner && existingOwner !== uid) {
      throw new UploadUrlError(
        'permission-denied',
        'report-owner-mismatch',
        'You do not have permission to attach an image to this report.',
      );
    }
  }

  async function issueReportUploadUrl({
    uid,
    tokenEmailVerified = false,
    signInProvider = '',
    reportId,
    contentType = 'image/jpeg',
    contentLength,
  }) {
    await verifyCallerIdentity({uid, tokenEmailVerified, signInProvider});

    const normalizedReportId = String(reportId || '').trim();
    if (!/^[a-zA-Z0-9_-]{8,64}$/.test(normalizedReportId)) {
      throw new UploadUrlError(
        'invalid-argument',
        'invalid-report-id',
        'A valid report ID is required to upload report media.',
      );
    }

    const rawMime = String(contentType || 'image/jpeg')
      .split(';')[0]
      .trim()
      .toLowerCase();
    const mimeSpec = ALLOWED_CONTENT_TYPES[rawMime];
    if (!mimeSpec) {
      throw new UploadUrlError(
        'invalid-argument',
        'invalid-content-type',
        'Only JPEG, PNG, or WebP report photos are allowed.',
      );
    }

    if (contentLength !== undefined && contentLength !== null) {
      const lengthNum = Number(contentLength);
      if (!Number.isInteger(lengthNum) || lengthNum <= 0) {
        throw new UploadUrlError(
          'invalid-argument',
          'invalid-content-length',
          'Image size must be a positive integer.',
        );
      }
      if (lengthNum > MAX_UPLOAD_BYTES) {
        throw new UploadUrlError(
          'invalid-argument',
          'file-too-large',
          'Report photo exceeds the 10 MB upload limit.',
          {maxBytes: MAX_UPLOAD_BYTES},
        );
      }
    }

    // Fail before reserving rate-limit budget if server storage config is missing.
    const storageConfig = parseAzureStorageConfig({env, secrets});

    await assertReportOwnership(uid, normalizedReportId);
    const nowMs = now();
    await enforceUploadRateLimit(uid, nowMs);

    const blobName = `reports/${uid}/${normalizedReportId}.${mimeSpec.ext}`;
    const sas = buildBlobUploadSas({
      ...storageConfig,
      blobName,
      nowMs,
    });

    logger.info?.('Issued report upload URL', {
      uid,
      reportId: normalizedReportId,
      blobPath: sas.blobPath,
      expiresAtMs: sas.expiresAtMs,
    });

    return {
      uploadUrl: sas.uploadUrl,
      publicUrl: sas.publicUrl,
      blobPath: sas.blobPath,
      expiresAtMs: sas.expiresAtMs,
      maxBytes: MAX_UPLOAD_BYTES,
      requiredHeaders: {
        'x-ms-blob-type': 'BlockBlob',
        'x-ms-version': SAS_VERSION,
        'Content-Type': mimeSpec.canonical,
      },
    };
  }

  return {
    issueReportUploadUrl,
  };
}

module.exports = {
  ALLOWED_CONTENT_TYPES,
  CLOCK_SKEW_MS,
  DEFAULT_CONTAINER,
  DEFAULT_ENDPOINT_SUFFIX,
  HOURLY_UPLOAD_URL_LIMIT,
  MAX_UPLOAD_BYTES,
  SAS_VERSION,
  UPLOAD_URL_TTL_MS,
  UploadUrlError,
  buildBlobUploadSas,
  createUploadUrlService,
  formatAzureIsoSeconds,
  parseAzureStorageConfig,
};

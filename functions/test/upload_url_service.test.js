const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const {
  HOURLY_UPLOAD_URL_LIMIT,
  MAX_UPLOAD_BYTES,
  SAS_VERSION,
  UPLOAD_URL_TTL_MS,
  createUploadUrlService,
  parseAzureStorageConfig,
} = require('../upload_url_service');

const TEST_ACCOUNT = 'testacct2026';
test('deployed upload callable binds its server storage secret', () => {
  const {issueReportUploadUrl} = require('../index');
  assert.deepEqual(issueReportUploadUrl.__endpoint.secretEnvironmentVariables,
    [{key: 'AZURE_STORAGE_CONNECTION_STRING'}]);
});
const TEST_KEY = Buffer.from('0123456789abcdef0123456789abcdef').toString('base64');
const TEST_CONN =
  `DefaultEndpointsProtocol=https;AccountName=${TEST_ACCOUNT};AccountKey=${TEST_KEY};EndpointSuffix=core.windows.net`;

function createFakeStore(initial = {}) {
  const data = new Map(Object.entries(initial));
  let lock = Promise.resolve();

  function docRef(col, id) {
    const k = `${col}/${id}`;
    return {
      path: k,
      async get() {
        const exists = data.has(k);
        return {
          exists,
          data: () => (exists ? structuredClone(data.get(k)) : undefined),
        };
      },
      async set(val) {
        data.set(k, structuredClone(val));
      },
    };
  }

  return {
    collection(col) {
      return {doc: (id) => docRef(col, id)};
    },
    async runTransaction(fn) {
      const next = lock.then(async () => {
        const tx = {
          async get(ref) {
            return ref.get();
          },
          set(ref, val) {
            data.set(ref.path, structuredClone(val));
          },
        };
        return fn(tx);
      });
      lock = next.catch(() => {});
      return next;
    },
  };
}

function createFakeAuth(users = {}) {
  return {
    async getUser(uid) {
      const u = users[uid];
      if (!u) {
        const err = new Error('User not found');
        err.code = 'auth/user-not-found';
        throw err;
      }
      return u;
    },
  };
}

test('parseAzureStorageConfig rejects missing or invalid configuration', () => {
  assert.throws(
    () => parseAzureStorageConfig({env: {}, secrets: {}}),
    (err) => err.reason === 'upload-not-configured',
  );
  assert.throws(
    () =>
      parseAzureStorageConfig({
        secrets: {AZURE_STORAGE_CONNECTION_STRING: 'AccountName=bad;AccountKey=notbase64!'},
      }),
    (err) => err.reason === 'upload-not-configured',
  );
  const parsed = parseAzureStorageConfig({
    secrets: {AZURE_STORAGE_CONNECTION_STRING: TEST_CONN},
  });
  assert.equal(parsed.accountName, TEST_ACCOUNT);
  assert.equal(parsed.container, 'photos');
  assert.equal(parsed.baseUrl, `https://${TEST_ACCOUNT}.blob.core.windows.net`);
});

test('issueReportUploadUrl rejects unauthenticated, disabled, or unverified users', async () => {
  const service = createUploadUrlService({
    db: createFakeStore(),
    auth: createFakeAuth({
      disabledUser: {uid: 'disabledUser', emailVerified: true, disabled: true},
      unverifiedUser: {uid: 'unverifiedUser', emailVerified: false, providerData: []},
    }),
    secrets: {AZURE_STORAGE_CONNECTION_STRING: TEST_CONN},
    logger: {info() {}, warn() {}, error() {}},
  });

  await assert.rejects(
    () => service.issueReportUploadUrl({uid: '', reportId: 'report_12345'}),
    (err) => err.reason === 'unauthenticated',
  );
  await assert.rejects(
    () => service.issueReportUploadUrl({uid: 'missingUser', reportId: 'report_12345'}),
    (err) => err.reason === 'user-not-found',
  );
  await assert.rejects(
    () => service.issueReportUploadUrl({uid: 'disabledUser', reportId: 'report_12345'}),
    (err) => err.reason === 'account-disabled',
  );
  await assert.rejects(
    () => service.issueReportUploadUrl({uid: 'unverifiedUser', reportId: 'report_12345'}),
    (err) => err.reason === 'email-not-verified',
  );
});

test('issueReportUploadUrl allows Google provider users without emailVerified boolean', async () => {
  const service = createUploadUrlService({
    db: createFakeStore(),
    auth: createFakeAuth({
      googleUser: {
        uid: 'googleUser',
        emailVerified: false,
        providerData: [{providerId: 'google.com'}],
      },
    }),
    secrets: {AZURE_STORAGE_CONNECTION_STRING: TEST_CONN},
    now: () => 1_750_000_000_000,
    logger: {info() {}, warn() {}, error() {}},
  });

  const out = await service.issueReportUploadUrl({
    uid: 'googleUser',
    reportId: 'report_google_1',
    contentType: 'image/jpeg',
    contentLength: 2048,
  });

  assert.equal(
    out.publicUrl,
    `https://${TEST_ACCOUNT}.blob.core.windows.net/photos/reports/googleUser/report_google_1.jpg`,
  );
});

test('issueReportUploadUrl validates reportId, contentType, contentLength, and ownership', async () => {
  const db = createFakeStore({
    'potholes/other_report_1': {reporterUid: 'otherUser'},
    'potholes/own_report_1': {reporterUid: 'user1'},
  });
  const service = createUploadUrlService({
    db,
    auth: createFakeAuth({
      user1: {uid: 'user1', emailVerified: true},
    }),
    secrets: {AZURE_STORAGE_CONNECTION_STRING: TEST_CONN},
    logger: {info() {}, warn() {}, error() {}},
  });

  await assert.rejects(
    () => service.issueReportUploadUrl({uid: 'user1', reportId: '../etc/passwd'}),
    (err) => err.reason === 'invalid-report-id',
  );
  await assert.rejects(
    () =>
      service.issueReportUploadUrl({
        uid: 'user1',
        reportId: 'valid_report_1',
        contentType: 'application/pdf',
      }),
    (err) => err.reason === 'invalid-content-type',
  );
  await assert.rejects(
    () =>
      service.issueReportUploadUrl({
        uid: 'user1',
        reportId: 'valid_report_1',
        contentType: 'image/png',
        contentLength: MAX_UPLOAD_BYTES + 1,
      }),
    (err) => err.reason === 'file-too-large',
  );
  await assert.rejects(
    () =>
      service.issueReportUploadUrl({
        uid: 'user1',
        reportId: 'other_report_1',
        contentType: 'image/jpeg',
        contentLength: 1024,
      }),
    (err) => err.reason === 'report-owner-mismatch',
  );

  // Retrying own existing reportId stays permitted.
  const retryOut = await service.issueReportUploadUrl({
    uid: 'user1',
    reportId: 'own_report_1',
    contentType: 'image/png',
    contentLength: 1024,
  });
  assert.match(retryOut.blobPath, /^photos\/reports\/user1\/own_report_1\.png$/);
});

test('issueReportUploadUrl emits valid single-blob short-lived SAS signature without leaking secrets', async () => {
  const logs = [];
  const fixedNow = 1_750_000_000_000;
  const service = createUploadUrlService({
    db: createFakeStore(),
    auth: createFakeAuth({user1: {uid: 'user1', emailVerified: true}}),
    secrets: {AZURE_STORAGE_CONNECTION_STRING: TEST_CONN},
    now: () => fixedNow,
    logger: {
      info: (msg, meta) => logs.push({msg, meta}),
      warn() {},
      error() {},
    },
  });

  const result = await service.issueReportUploadUrl({
    uid: 'user1',
    reportId: 'rep_12345678',
    contentType: 'image/jpeg',
    contentLength: 4096,
  });

  assert.equal(result.expiresAtMs, fixedNow + UPLOAD_URL_TTL_MS);
  assert.deepEqual(result.requiredHeaders, {
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-version': SAS_VERSION,
    'Content-Type': 'image/jpeg',
  });

  const url = new URL(result.uploadUrl);
  assert.equal(url.protocol, 'https:');
  assert.equal(url.origin + url.pathname, result.publicUrl);
  assert.equal(url.searchParams.get('sv'), SAS_VERSION);
  assert.equal(url.searchParams.get('sp'), 'cw');
  assert.equal(url.searchParams.get('sr'), 'b');
  assert.equal(url.searchParams.get('spr'), 'https');

  // Independently verify HMAC-SHA256 SAS signature matches Azure Storage spec.
  const expectedStringToSign = [
    'cw',
    url.searchParams.get('st'),
    url.searchParams.get('se'),
    `/blob/${TEST_ACCOUNT}/photos/reports/user1/rep_12345678.jpg`,
    '',
    '',
    'https',
    SAS_VERSION,
    'b',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
  ].join('\n');
  const expectedSig = crypto
    .createHmac('sha256', Buffer.from(TEST_KEY, 'base64'))
    .update(expectedStringToSign, 'utf8')
    .digest('base64');
  assert.equal(url.searchParams.get('sig'), expectedSig);

  // Verify logs contain neither account key nor signed URL.
  const serializedLogs = JSON.stringify(logs);
  assert.equal(serializedLogs.includes(TEST_KEY), false);
  assert.equal(serializedLogs.includes(result.uploadUrl), false);
});

test('issueReportUploadUrl enforces hourly rate limit per uid', async () => {
  const service = createUploadUrlService({
    db: createFakeStore(),
    auth: createFakeAuth({user1: {uid: 'user1', emailVerified: true}}),
    secrets: {AZURE_STORAGE_CONNECTION_STRING: TEST_CONN},
    now: () => 1_750_000_000_000,
    logger: {info() {}, warn() {}, error() {}},
  });

  for (let i = 0; i < HOURLY_UPLOAD_URL_LIMIT; i += 1) {
    await service.issueReportUploadUrl({
      uid: 'user1',
      reportId: `rep_rate_${String(i).padStart(4, '0')}`,
      contentType: 'image/jpeg',
    });
  }

  await assert.rejects(
    () =>
      service.issueReportUploadUrl({
        uid: 'user1',
        reportId: 'rep_rate_overflow',
        contentType: 'image/jpeg',
      }),
    (err) => err.reason === 'upload-rate-limited',
  );
});

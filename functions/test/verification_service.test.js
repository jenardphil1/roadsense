const test = require('node:test');
const assert = require('node:assert/strict');

const {
  ACCOUNT_HOURLY_FAIL_LIMIT,
  ACCOUNT_HOURLY_SEND_LIMIT,
  CODE_TTL_MS,
  IP_HOURLY_SEND_LIMIT,
  MAX_VERIFY_ATTEMPTS_PER_CODE,
  RESEND_COOLDOWN_MS,
  createVerificationService,
  generateNumericCode,
  maskEmail,
} = require('../verification_service');
const { buildVerificationEmail, deliverVerificationEmail } = require('../email_transport');

const TEST_SECRET = '0123456789abcdef0123456789abcdef';

class FakeFieldValue {
  constructor(op, value) {
    this.op = op;
    this.value = value;
  }
  static serverTimestamp() {
    return new FakeFieldValue('serverTimestamp');
  }
  static delete() {
    return new FakeFieldValue('delete');
  }
}

function applyMerge(target, patch) {
  const next = { ...target };
  for (const [k, v] of Object.entries(patch || {})) {
    if (v instanceof FakeFieldValue) {
      if (v.op === 'delete') {
        delete next[k];
      } else if (v.op === 'serverTimestamp') {
        next[k] = { __serverTimestamp: true };
      }
    } else if (v !== undefined) {
      next[k] = structuredClone(v);
    }
  }
  return next;
}

function createFakeStore() {
  const data = new Map();
  let lock = Promise.resolve();

  function key(col, id) {
    return `${col}/${id}`;
  }

  function docRef(col, id) {
    const k = key(col, id);
    return {
      path: k,
      async get() {
        const val = data.get(k);
        return {
          exists: val !== undefined,
          data: () => (val === undefined ? undefined : structuredClone(val)),
        };
      },
      async set(patch, opts = {}) {
        const cur = opts.merge ? (data.get(k) || {}) : {};
        data.set(k, applyMerge(cur, patch));
      },
      async update(patch) {
        if (!data.has(k)) throw new Error(`Missing doc ${k}`);
        data.set(k, applyMerge(data.get(k), patch));
      },
    };
  }

  return {
    _data: data,
    collection(col) {
      let autoId = 0;
      return {
        doc: (id) => docRef(col, id),
        add: async (obj) => {
          autoId++;
          const ref = docRef(col, `auto_${autoId}`);
          await ref.set(obj);
          return ref;
        },
      };
    },
    async runTransaction(fn) {
      // Serialize concurrent transactions just like optimistic lock retries in Firestore.
      const run = async () => {
        const writes = [];
        const tx = {
          async get(ref) {
            return ref.get();
          },
          set(ref, patch, opts) {
            writes.push(() => ref.set(patch, opts));
          },
          update(ref, patch) {
            writes.push(() => ref.update(patch));
          },
        };
        const result = await fn(tx);
        for (const w of writes) await w();
        return result;
      };
      const next = lock.then(run, run);
      lock = next.catch(() => { });
      return next;
    },
  };
}

function createFakeAuth(initialUsers = []) {
  const users = new Map();
  for (const u of initialUsers) {
    users.set(u.uid, {
      uid: u.uid,
      email: u.email,
      displayName: u.displayName || '',
      emailVerified: Boolean(u.emailVerified),
    });
  }
  return {
    _users: users,
    async getUser(uid) {
      const u = users.get(uid);
      if (!u) {
        const err = new Error('User not found');
        err.code = 'auth/user-not-found';
        throw err;
      }
      return { ...u };
    },
    async getUserByEmail(email) {
      const target = String(email || '').trim().toLowerCase();
      for (const u of users.values()) {
        if (String(u.email || '').trim().toLowerCase() === target) {
          return { ...u };
        }
      }
      const err = new Error('User not found');
      err.code = 'auth/user-not-found';
      throw err;
    },
    async updateUser(uid, patch) {
      const u = users.get(uid);
      if (!u) throw new Error('Missing user');
      Object.assign(u, patch);
      return { ...u };
    },
  };
}

function makeHarness({ initialUsers, fixedCodes = ['004219'] } = {}) {
  const db = createFakeStore();
  const auth = createFakeAuth(
    initialUsers || [{ uid: 'u1', email: 'Alice@Example.com', displayName: 'Alice <Test>', emailVerified: false }],
  );
  const sentEmails = [];
  const logEntries = [];
  let clock = 1_700_000_000_000;
  let codeIndex = 0;

  const logger = {
    info: (msg, meta) => logEntries.push({ level: 'info', msg, meta }),
    error: (msg, meta) => logEntries.push({ level: 'error', msg, meta }),
  };

  const service = createVerificationService({
    db,
    auth,
    FieldValue: FakeFieldValue,
    logger,
    env: {},
    secrets: { OTP_HMAC_SECRET: TEST_SECRET },
    now: () => clock,
    rng: () => Number(fixedCodes[Math.min(codeIndex++, fixedCodes.length - 1)]),
    customTransport: async (payload) => {
      sentEmails.push(payload);
    },
  });

  const extractLastCode = () => {
    const last = sentEmails[sentEmails.length - 1];
    const m = last.text.match(/\b(\d{6})\b/);
    return m ? m[1] : null;
  };

  return {
    db,
    auth,
    sentEmails,
    logEntries,
    service,
    extractLastCode,
    advanceMs: (ms) => {
      clock += ms;
    },
    setClock: (ms) => {
      clock = ms;
    },
  };
}

test('maskEmail masks short and standard addresses safely', () => {
  assert.equal(maskEmail('a@example.com'), '*@example.com');
  assert.equal(maskEmail('ab@example.com'), 'a*@example.com');
  assert.equal(maskEmail('joe@example.com'), 'j*e@example.com');
  assert.equal(maskEmail('jenard@Example.COM'), 'je***d@example.com');
});

test('generateNumericCode preserves leading zeros', () => {
  assert.equal(generateNumericCode(() => 0), '000000');
  assert.equal(generateNumericCode(() => 42), '000042');
  assert.equal(generateNumericCode(() => 999999), '999999');
});

test('buildVerificationEmail shows prominent code, 10-min expiry, ignore note, zero links, escapes HTML', () => {
  const mail = buildVerificationEmail({
    displayName: 'Jenard <Admin>',
    code: '004219',
    ttlMinutes: 10,
  });
  assert.match(mail.text, /004219/);
  assert.match(mail.text, /10 minutes/);
  assert.match(mail.text, /safely ignore this email/i);
  assert.doesNotMatch(mail.text, /https?:\/\//i);
  assert.match(mail.html, /004219/);
  assert.match(mail.html, /Jenard &lt;Admin&gt;/);
  assert.doesNotMatch(mail.html, /<a\s+href=/i);
});

test('complete happy path with leading-zero code stores no plaintext OTP or logs, sets emailVerified, prevents replay', async () => {
  const h = makeHarness({ fixedCodes: ['000317'] });
  const sendRes = await h.service.sendVerificationCode({ uid: 'u1', clientIp: '1.2.3.4' });
  assert.equal(sendRes.sent, true);
  assert.equal(sendRes.maskedEmail, 'Al**e@example.com');
  assert.equal(sendRes.expiresInSeconds, 600);
  assert.equal(sendRes.cooldownSeconds, 60);

  const code = h.extractLastCode();
  assert.equal(code, '000317');

  // Ensure Firestore & logs never hold plaintext OTP.
  const verifRaw = JSON.stringify(h.db._data.get('emailVerifications/u1'));
  const logsRaw = JSON.stringify(h.logEntries);
  assert.equal(verifRaw.includes('000317'), false);
  assert.equal(logsRaw.includes('000317'), false);

  const statusBefore = await h.service.getVerificationStatus({ uid: 'u1' });
  assert.equal(statusBefore.verified, false);
  assert.equal(statusBefore.hasActiveCode, true);
  assert.equal(statusBefore.attemptsRemaining, 5);

  const verifyRes = await h.service.verifyEmailCode({ uid: 'u1', code: '000317', clientIp: '1.2.3.4' });
  assert.equal(verifyRes.verified, true);
  assert.equal(h.auth._users.get('u1').emailVerified, true);
  assert.equal(h.db._data.get('users/u1').isVerified, true);

  // Replay with the exact same single-use code fails cleanly.
  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '000317', clientIp: '1.2.3.4' }),
    (err) => err.reason === 'already-used',
  );
});

test('concurrent verify submissions allow only one success and reject replay atomically', async () => {
  const h = makeHarness({ fixedCodes: ['007890'] });
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '1.2.3.4' });

  const results = await Promise.allSettled([
    h.service.verifyEmailCode({ uid: 'u1', code: '007890', clientIp: '1.2.3.4' }),
    h.service.verifyEmailCode({ uid: 'u1', code: '007890', clientIp: '1.2.3.4' }),
  ]);
  const fulfilled = results.filter((r) => r.status === 'fulfilled');
  const rejected = results.filter((r) => r.status === 'rejected');
  assert.equal(fulfilled.length, 1);
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason.reason, 'already-used');
});

test('code expires strictly after 10 minutes', async () => {
  const h = makeHarness({ fixedCodes: ['123456'] });
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '1.2.3.4' });
  h.advanceMs(CODE_TTL_MS + 1);

  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '123456', clientIp: '1.2.3.4' }),
    (err) => err.reason === 'expired' && err.httpsCode === 'deadline-exceeded',
  );
});

test('allows at most 5 incorrect attempts per issued code then locks until resend', async () => {
  const h = makeHarness({ fixedCodes: ['246810'] });
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '1.2.3.4' });

  for (let i = 1; i <= 4; i++) {
    await assert.rejects(
      () => h.service.verifyEmailCode({ uid: 'u1', code: '000000', clientIp: '1.2.3.4' }),
      (err) => err.reason === 'incorrect' && err.details.attemptsRemaining === MAX_VERIFY_ATTEMPTS_PER_CODE - i,
    );
  }

  // 5th wrong guess locks the issued code.
  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '000000', clientIp: '1.2.3.4' }),
    (err) => err.reason === 'attempt-limited' && err.details.attemptsRemaining === 0,
  );

  // Even the right code cannot succeed once attempt-limited.
  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '246810', clientIp: '1.2.3.4' }),
    (err) => err.reason === 'attempt-limited',
  );
});

test('resend enforces 60s cooldown, invalidates previous code as superseded, and does not reset abuse limits', async () => {
  const h = makeHarness({ fixedCodes: ['111111', '222222', '333333', '444444', '555555', '666666'] });
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '10.0.0.1' });

  // Cooldown active before 60s.
  h.advanceMs(30_000);
  await assert.rejects(
    () => h.service.sendVerificationCode({ uid: 'u1', clientIp: '10.0.0.1' }),
    (err) => err.reason === 'cooldown' && err.details.cooldownSeconds === 30,
  );

  // Burn 4 wrong guesses on first code.
  for (let i = 0; i < 4; i++) {
    await assert.rejects(() => h.service.verifyEmailCode({ uid: 'u1', code: '999999', clientIp: '10.0.0.1' }));
  }

  // Advance past 60s cooldown and resend -> issues '222222'.
  h.advanceMs(RESEND_COOLDOWN_MS);
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '10.0.0.1' });

  // Old code '111111' is superseded and clearly reported.
  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '111111', clientIp: '10.0.0.1' }),
    (err) => err.reason === 'superseded',
  );

  // Resending did NOT reset the hourly failed attempt limit (ACCOUNT_HOURLY_FAIL_LIMIT).
  // Burn 10 more failures across resends (4 initial + 1 superseded + 10 = 15 = limit).
  for (let i = 0; i < 4; i++) {
    await assert.rejects(() => h.service.verifyEmailCode({ uid: 'u1', code: '999999', clientIp: '10.0.0.1' }));
  }
  h.advanceMs(RESEND_COOLDOWN_MS);
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '10.0.0.1' });
  for (let i = 0; i < 4; i++) {
    await assert.rejects(() => h.service.verifyEmailCode({ uid: 'u1', code: '999999', clientIp: '10.0.0.1' }));
  }
  h.advanceMs(RESEND_COOLDOWN_MS);
  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '10.0.0.1' });
  for (let i = 0; i < 2; i++) {
    await assert.rejects(() => h.service.verifyEmailCode({ uid: 'u1', code: '999999', clientIp: '10.0.0.1' }));
  }

  // Next verification guess hits rolling account fail limit across resends!
  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '444444', clientIp: '10.0.0.1' }),
    (err) => err.reason === 'rate-limited',
  );
  assert.ok(ACCOUNT_HOURLY_FAIL_LIMIT === 15);
});

test('enforces hourly account send limit and IP send limit without resetting on resend', async () => {
  const users = [];
  for (let i = 0; i < IP_HOURLY_SEND_LIMIT + 2; i++) {
    users.push({ uid: `u${i}`, email: `user${i}@example.com`, emailVerified: false });
  }
  const h = makeHarness({ initialUsers: users, fixedCodes: ['123456'] });

  // Account limit for u0: 5 sends allowed in 1 hour, 6th rejected.
  for (let i = 0; i < ACCOUNT_HOURLY_SEND_LIMIT; i++) {
    await h.service.sendVerificationCode({ uid: 'u0', clientIp: '203.0.113.10' });
    h.advanceMs(RESEND_COOLDOWN_MS);
  }
  await assert.rejects(
    () => h.service.sendVerificationCode({ uid: 'u0', clientIp: '203.0.113.10' }),
    (err) => err.reason === 'rate-limited',
  );

  // Remaining IP budget from a different account on same IP (203.0.113.10): 5 more -> hits 10/hr IP cap.
  for (let i = 1; i <= IP_HOURLY_SEND_LIMIT - ACCOUNT_HOURLY_SEND_LIMIT; i++) {
    await h.service.sendVerificationCode({ uid: `u${i}`, clientIp: '203.0.113.10' });
  }
  await assert.rejects(
    () => h.service.sendVerificationCode({ uid: `u${IP_HOURLY_SEND_LIMIT}`, clientIp: '203.0.113.10' }),
    (err) => err.reason === 'rate-limited',
  );
});

test('updatePendingEmail updates Auth & Firestore email, invalidates old code, and sends code to corrected address', async () => {
  const h = makeHarness({
    initialUsers: [
      { uid: 'u1', email: 'typo@example.com', displayName: 'Jen', emailVerified: false },
      { uid: 'u2', email: 'taken@example.com', displayName: 'Other', emailVerified: true },
    ],
    fixedCodes: ['101010', '020202'],
  });

  await h.service.sendVerificationCode({ uid: 'u1', clientIp: '1.2.3.4' });

  // Reject email belonging to another user.
  await assert.rejects(
    () => h.service.updatePendingEmail({ uid: 'u1', newEmail: 'taken@example.com', clientIp: '1.2.3.4' }),
    (err) => err.reason === 'email-in-use',
  );

  // Update to corrected email.
  const upd = await h.service.updatePendingEmail({
    uid: 'u1',
    newEmail: 'jenard@example.com',
    clientIp: '1.2.3.4',
  });
  assert.equal(upd.updated, true);
  assert.equal(upd.maskedEmail, 'je***d@example.com');
  assert.equal(h.auth._users.get('u1').email, 'jenard@example.com');
  assert.equal(h.db._data.get('users/u1').email, 'jenard@example.com');

  // Old code cannot verify new email.
  await assert.rejects(
    () => h.service.verifyEmailCode({ uid: 'u1', code: '101010', clientIp: '1.2.3.4' }),
    (err) => err.reason === 'incorrect',
  );

  // New leading-zero code succeeds.
  const ok = await h.service.verifyEmailCode({ uid: 'u1', code: '020202', clientIp: '1.2.3.4' });
  assert.equal(ok.verified, true);
});

test('production configuration fails closed if OTP_HMAC_SECRET or email provider is unconfigured', async () => {
  const db = createFakeStore();
  const auth = createFakeAuth([{ uid: 'u1', email: 'u@example.com', emailVerified: false }]);

  const noSecretService = createVerificationService({
    db,
    auth,
    FieldValue: FakeFieldValue,
    env: {},
    secrets: {},
    customTransport: async () => { },
  });

  await assert.rejects(
    () => noSecretService.sendVerificationCode({ uid: 'u1' }),
    (err) => err.reason === 'server-misconfigured',
  );

  await assert.rejects(
    () =>
      deliverVerificationEmail({
        to: 'u@example.com',
        displayName: 'Test',
        code: '123456',
        env: {},
        secrets: {},
        db,
      }),
    (err) => err.name === 'EmailConfigError',
  );
});

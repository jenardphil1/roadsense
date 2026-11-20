const test = require('node:test');
const assert = require('node:assert/strict');
const {createUploadHandler} = require('../azure_upload_handler');
const {UploadUrlError} = require('../upload_url_service');

function setup({authError, serviceError} = {}) {
  const calls = [];
  const handler = createUploadHandler({
    auth: {async verifyIdToken(token, checkRevoked) {
      calls.push({token, checkRevoked});
      if (authError) throw authError;
      return {uid: 'verified-user', email_verified: true, firebase: {sign_in_provider: 'google.com'}};
    }},
    service: {async issueReportUploadUrl(data) {
      calls.push(data);
      if (serviceError) throw serviceError;
      return {uploadUrl: 'https://example.test/blob?short-lived-sas'};
    }},
    logger: {error() {}},
  });
  return {calls, async request(overrides = {}) {
    const context = {};
    await handler(context, {
      method: 'POST', headers: {authorization: 'Bearer signed-id-token'},
      body: {data: {reportId: 'report_123', contentType: 'image/jpeg', contentLength: 1024}},
      ...overrides,
    });
    return context.res;
  }};
}

test('Azure upload requires a bearer token before accessing storage', async () => {
  const fixture = setup();
  assert.equal((await fixture.request({headers: {}})).status, 401);
  assert.deepEqual(fixture.calls, []);
});

test('Azure upload rejects revoked Firebase tokens', async () => {
  const fixture = setup({authError: {code: 'auth/id-token-revoked'}});
  const response = await fixture.request();
  assert.equal(response.status, 401);
  assert.equal(response.body.error.details.reason, 'invalid-session');
  assert.deepEqual(fixture.calls, [{token: 'signed-id-token', checkRevoked: true}]);
});

test('Azure upload uses verified identity and ignores client-supplied identity', async () => {
  const fixture = setup();
  const response = await fixture.request({body: {data: {uid: 'attacker', reportId: 'report_123'}}});
  assert.equal(response.status, 200);
  assert.equal(fixture.calls[1].uid, 'verified-user');
  assert.equal(fixture.calls[1].tokenEmailVerified, true);
  assert.equal(fixture.calls[1].signInProvider, 'google.com');
  assert.equal(response.headers['Cache-Control'], 'no-store');
});

test('Azure upload validates the callable envelope', async () => {
  for (const body of [undefined, {}, {data: []}, {data: 'invalid'}]) {
    const fixture = setup();
    assert.equal((await fixture.request({body})).status, 400);
    assert.equal(fixture.calls.length, 1);
  }
});

test('Azure upload preserves ownership and rate-limit service errors', async () => {
  for (const [code, status, reason] of [
    ['permission-denied', 403, 'report-owner-mismatch'],
    ['resource-exhausted', 429, 'upload-rate-limited'],
    ['failed-precondition', 412, 'email-not-verified'],
  ]) {
    const fixture = setup({serviceError: new UploadUrlError(code, reason, 'Request rejected.', {retryAfterSec: 60})});
    const response = await fixture.request();
    assert.equal(response.status, status);
    assert.equal(response.body.error.details.reason, reason);
    assert.equal(response.body.error.details.retryAfterSec, 60);
  }
});

test('Azure upload hides infrastructure and secret errors', async () => {
  for (const failure of [
    {serviceError: new Error('private storage connection string')},
    {authError: new Error('private Firebase credential')},
  ]) {
    const response = await setup(failure).request();
    assert.equal(response.status, 503);
    assert.doesNotMatch(JSON.stringify(response), /private/);
  }
});

test('Azure upload only accepts POST', async () => {
  const fixture = setup();
  const response = await fixture.request({method: 'GET'});
  assert.equal(response.status, 405);
  assert.equal(response.headers.Allow, 'POST');
  assert.deepEqual(fixture.calls, []);
});

test('hosted HTTP server bounds and validates requests without leaking routes', async (t) => {
  const {createUploadServer} = require('../azure_upload_server');
  const server = createUploadServer(async context => {
    context.res = {status: 401, body: {error: {status: 'UNAUTHENTICATED'}}};
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.deepEqual(await (await fetch(`${base}/healthz`)).json(), {status: 'ok'});
  assert.equal((await fetch(`${base}/anything-else`)).status, 404);
  for (const [body, status] of [['{', 400], ['x'.repeat(16385), 413], ['{"data":{}}', 401]]) {
    const response = await fetch(`${base}/issueReportUploadUrl`, {method: 'POST', body});
    assert.equal(response.status, status);
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
});

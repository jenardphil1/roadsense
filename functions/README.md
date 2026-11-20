# RoadSense AI — Backend Email Verification Setup

This directory contains the Firebase Cloud Functions (Node 20, v2 Callables) implementing 6-digit OTP email verification and short-lived Azure Blob upload URL issuance.

## Architecture & Security
- **Endpoints**:
  - `sendVerificationCode`: Generates a CSPRNG 6-digit code preserving leading zeros, binds an HMAC-SHA256 verifier (`uid + email + email-verification + salt + code`), invalidates any prior code, enforces a 60s cooldown + rolling account/IP rate limits, and delivers a branded HTML/text email.
  - `verifyEmailCode`: Transactionally validates attempt count (max 5), expiry (10 min), active status, and HMAC verifier; atomically marks consumed; sets Firebase Auth `emailVerified = true` via Admin SDK.
  - `getVerificationStatus`: Returns masked email, active status, expiry timestamp, cooldown timestamp, and remaining attempts across app restarts without issuing a new code.
  - `updatePendingEmail`: Securely corrects an unverified account's email address, checks collision & limits, invalidates prior codes, and sends a fresh 6-digit code to the new address.
  - `issueReportUploadUrl`: Verifies Firebase Auth identity and verified-email/Google status, enforces report ownership and hourly per-UID rate limiting, and mints a 5-minute single-blob (`sr=b`), create+write (`sp=cw`), HTTPS-only (`spr=https`) Azure Blob Service SAS (`sv=2022-11-02`) upload URL scoped to `reports/{uid}/{reportId}.{ext}` inside the `photos` container.
- **No secrets, Azure account keys, or OTP codes are stored in mobile binaries, persisted in plaintext, or logged.**

## Configuring Production Secrets, Storage Upload & Rules
In Firebase project `pothole-app-b277b`:

1. Set the HMAC secret (`>= 16` chars, e.g. 64 hex chars):
   ```bash
   firebase functions:secrets:set OTP_HMAC_SECRET
   ```
2. Set the Azure Blob Storage connection string (never commit this value):
   ```bash
   firebase functions:secrets:set AZURE_STORAGE_CONNECTION_STRING
   ```
   Optional overrides (defaults shown): `AZURE_STORAGE_CONTAINER=photos`, `AZURE_STORAGE_ENDPOINT_SUFFIX=core.windows.net`.
3. Configure **one** email delivery provider:
   - **Option A — Resend (Recommended)**:
     Set `RESEND_API_KEY` as a secret/env var and `EMAIL_FROM` (e.g. `RoadSense AI <no-reply@roadsense.me>`).
   - **Option B — SMTP (Nodemailer)**:
     Configure `SMTP_HOST`, `SMTP_PORT` (`587` or `465`), `SMTP_USER`, `SMTP_PASS`, and `SMTP_FROM` (`SMTP_SECURE=true` for port `465`).
   - **Option C — Firebase Trigger Email Extension**:
     Set `EMAIL_PROVIDER=firestore_mail` if using the installed extension writing to `/mail`.

Note: Cloud Functions v2 deployment requires Firebase Blaze billing enabled on `pothole-app-b277b`. Bind runtime secrets (`OTP_HMAC_SECRET`, `AZURE_STORAGE_CONNECTION_STRING`, and your mail secret) in your Cloud Run / Cloud Functions deployment configuration, then deploy functions and rules:
```bash
firebase deploy --only functions,firestore:rules --project pothole-app-b277b
```
To test against the local backend bridge (`functions/local_server.js`) during development without deploying to Cloud Functions, put `AZURE_STORAGE_CONNECTION_STRING=...` inside an untracked `functions/.env`, start `node functions/local_server.js`, and pass `--dart-define=FUNCTIONS_BASE_URL=http://<lan-or-emulator-ip>:5001` when running the Flutter app. To allow `updatePendingEmail` to refresh an unverified user's session in-place without requiring them to sign back in after correcting a typo in their email address, grant `roles/iam.serviceAccountTokenCreator` (`iam.serviceAccounts.signBlob`) to the Cloud Functions runtime service account.

For the connected TECNO USB development setup, run
`powershell -File tools/start_upload_bridge.ps1` from the repository root.
It reads the existing gitignored `dart_defines.local.json` on the computer,
passes the Azure credential only to the backend process, and forwards port 5001
over ADB. Keep that process and USB connection active. The mobile functions
client already supports this local endpoint. This bridge is not a deployed
service and does not provide uploads when the computer is disconnected.

`issueReportUploadUrl` explicitly binds the `AZURE_STORAGE_CONNECTION_STRING`
Secret Manager secret. Setting a secret without binding it does not make it
available to a deployed function. Firebase deployment currently requires a
Blaze upgrade; alternatively host the authenticated upload backend on Azure.

## Azure upload hosting (deployed)

The mobile upload endpoint is `https://roadsense-upload-2026.azurewebsites.net/issueReportUploadUrl`.
It runs `azure_upload_server.js` on Node 22 in Azure App Service `roadsense-upload-2026`,
resource group `pothole-rg`, Indonesia Central, plan `roadsense-upload-free` (the name is historical; current SKU is **B1 Basic**, one Linux instance).
Upgraded from F1 on 2026-11-17 at the user's request for three days of availability.
Always On is enabled and the health-check path is `/healthz`. The Free-tier daily
CPU cutoff no longer applies. Listed regional Linux B1 pricing at upgrade: USD 0.017/hour
(about USD 1.224 per 72 hours), excluding existing Blob/Firebase usage. Billing continues
until the plan is downgraded or deleted. Remaining student-credit balance could not be
retrieved through the subscription balance API. Existing application rate limits,
subscription spending limits and cloud-service outages can still affect availability.

The adapter verifies Firebase ID tokens with revocation checks, then calls the same
`upload_url_service.js` used by the Firebase callable. Firebase Auth and Firestore
remain in `pothole-app-b277b`; photos remain in `potholestorage2026/photos`.
Only photo upload authorization is routed to Azure; email verification keeps its existing endpoint.

Azure app settings hold `AZURE_STORAGE_CONNECTION_STRING`, `AZURE_STORAGE_CONTAINER=photos`,
and `FIREBASE_SERVICE_ACCOUNT_JSON`. Never put these values into Flutter build defines.
The dedicated `roadsense-upload-azure` Firebase service account uses the custom role
`roadSenseUploadIssuer`: `firebaseauth.users.get`, `datastore.databases.get`, and
`datastore.entities.get/create/update`. This role can read database entities and update
them; the HTTP handler exposes only upload authorization and its ownership/rate checks.
Rotate its private key through Google Cloud IAM and replace the Azure app setting.
Developer Firebase CLI credentials are never deployed.

To package and redeploy the backend after changes, from the repository root:

```powershell
powershell -File tools/package_azure_upload.ps1
az webapp deploy --name roadsense-upload-2026 --resource-group pothole-rg --src-path .dart_tool/azure-upload/backend.zip --type zip --track-status false
```

The app startup command is `node azure_upload_server.js`; `SCM_DO_BUILD_DURING_DEPLOYMENT=true`
installs backend dependencies in Azure. The package contains only the upload server,
handler, shared SAS service, and its dependency manifest; credentials are excluded.

Build the mobile app with its dedicated public endpoint:

```powershell
flutter build apk --release -t lib/main.dart --dart-define=UPLOAD_FUNCTIONS_BASE_URL=https://roadsense-upload-2026.azurewebsites.net
flutter test test/upload_endpoint_test.dart --dart-define=UPLOAD_FUNCTIONS_BASE_URL=https://roadsense-upload-2026.azurewebsites.net
```

4. Run tests locally:
   ```bash
   cd functions
   npm test
   ```

5. Optional one-time transition for pre-migration verified users:
   ```bash
   node migrate_verified_users.js        # dry-run audit
   node migrate_verified_users.js --apply
   ```

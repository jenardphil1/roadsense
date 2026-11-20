/**
 * Branded email composition and pluggable backend delivery for RoadSense AI
 * 6-digit registration email verification codes.
 *
 * Security notes:
 * - Never logs the plaintext OTP code, tokens, or SMTP credentials.
 * - Never includes a verification link.
 * - Fails explicitly in production if no real email transport is configured.
 */

const nodemailer = require('nodemailer');

const DEFAULT_TTL_MINUTES = 10;
const EMULATOR_OUTBOX_COLLECTION = '_emulatorMailSink';

class EmailConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'EmailConfigError';
  }
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

function isEmulatorEnvironment(env = process.env) {
  return (
    env.FUNCTIONS_EMULATOR === 'true' ||
    Boolean(env.FIREBASE_AUTH_EMULATOR_HOST) ||
    Boolean(env.FIRESTORE_EMULATOR_HOST)
  );
}

/**
 * Builds the branded plain-text and HTML verification email.
 * Displays the 6-digit code prominently, states the 10-minute expiry,
 * explains what to do if unintended, and includes no verification links.
 */
function buildVerificationEmail({
  displayName,
  code,
  ttlMinutes = DEFAULT_TTL_MINUTES,
}) {
  const safeName = String(displayName || '').trim() || 'RoadSense Member';
  const escapedName = escapeHtml(safeName);
  const formattedCode = String(code ?? '').trim();
  const escapedCode = escapeHtml(formattedCode);
  const mins = Number(ttlMinutes) || DEFAULT_TTL_MINUTES;

  const subject = 'RoadSense AI — Verify your email address';
  const text = [
    `Hi ${safeName},`,
    '',
    'Welcome to RoadSense AI. Enter this 6-digit verification code in the app to verify your email address:',
    '',
    `    ${formattedCode}`,
    '',
    `This code expires in ${mins} minutes and can only be used once.`,
    '',
    'If you did not create a RoadSense account or request this code, you can safely ignore this email.',
    '',
    '— RoadSense AI Team',
  ].join('\n');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${escapeHtml(subject)}</title>
</head>
<body style="margin:0;padding:32px 16px;background-color:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#0f172a;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:520px;background-color:#ffffff;border-radius:16px;border:1px solid #e2e8f0;overflow:hidden;">
          <tr>
            <td style="background-color:#0f172a;padding:24px 32px;">
              <span style="display:inline-block;background-color:#0284c7;color:#ffffff;font-size:12px;font-weight:700;letter-spacing:1.2px;padding:6px 12px;border-radius:6px;">ROADSENSE AI</span>
              <h1 style="margin:16px 0 4px 0;font-size:22px;line-height:1.3;font-weight:700;color:#f8fafc;">Verify your email</h1>
              <p style="margin:0;font-size:14px;color:#94a3b8;">Account email verification code</p>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 32px 32px 32px;">
              <p style="margin:0 0 14px 0;font-size:15px;line-height:1.6;color:#334155;">Hi <strong>${escapedName}</strong>,</p>
              <p style="margin:0 0 22px 0;font-size:15px;line-height:1.6;color:#334155;">Enter the 6-digit verification code below in RoadSense to confirm your email address:</p>
              <div style="background-color:#f0f9ff;border:1.5px solid #bae6fd;border-radius:12px;padding:22px 16px;text-align:center;margin:0 0 22px 0;">
                <span style="display:inline-block;font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:36px;font-weight:800;letter-spacing:10px;color:#0369a1;padding-left:10px;">${escapedCode}</span>
              </div>
              <p style="margin:0 0 14px 0;font-size:14px;line-height:1.6;color:#334155;">This code expires in <strong>${mins} minutes</strong> and can only be used once.</p>
              <div style="border-top:1px solid #e2e8f0;margin-top:24px;padding-top:16px;">
                <p style="margin:0;font-size:12.5px;line-height:1.6;color:#64748b;">Didn't request this code? If you did not sign up for RoadSense AI, you can safely ignore this email—no account changes will be made without entering the code.</p>
              </div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;

  return {subject, text, html};
}

/**
 * Resolves the active delivery backend from explicit transport, secrets/env,
 * optional Trigger Email Firestore queue, or emulator-only capture sink.
 */
function resolveEmailBackend({env = process.env, secrets = {}, db, customTransport} = {}) {
  if (typeof customTransport === 'function') {
    return {kind: 'custom', send: customTransport};
  }

  const resendApiKey = String(secrets.RESEND_API_KEY || env.RESEND_API_KEY || '').trim();
  const smtpHost = String(env.SMTP_HOST || secrets.SMTP_HOST || '').trim();
  const smtpPort = Number(env.SMTP_PORT || secrets.SMTP_PORT || 587);
  const smtpUser = String(env.SMTP_USER || secrets.SMTP_USER || '').trim();
  const smtpPass = String(secrets.SMTP_PASS || env.SMTP_PASS || '').trim();
  const fromAddress = String(
    env.EMAIL_FROM || env.SMTP_FROM || secrets.SMTP_FROM || smtpUser || 'RoadSense AI <no-reply@roadsense.me>',
  ).trim();
  const emailProvider = String(env.EMAIL_PROVIDER || '').trim().toLowerCase();

  if (resendApiKey) {
    return {
      kind: 'resend',
      async send({to, subject, text, html}) {
        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${resendApiKey}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            from: fromAddress,
            to: [to],
            subject,
            text,
            html,
          }),
        });
        if (!res.ok) {
          throw new Error(`Email provider rejected delivery (${res.status}).`);
        }
      },
    };
  }

  if (smtpHost && smtpUser && smtpPass) {
    const secure =
      String(env.SMTP_SECURE || '').toLowerCase() === 'true' || smtpPort === 465;
    return {
      kind: 'smtp',
      async send({to, subject, text, html}) {
        const transporter = nodemailer.createTransport({
          host: smtpHost,
          port: smtpPort,
          secure,
          auth: {user: smtpUser, pass: smtpPass},
          connectionTimeout: 10000,
          greetingTimeout: 10000,
          socketTimeout: 15000,
        });
        await transporter.sendMail({
          from: fromAddress,
          to,
          subject,
          text,
          html,
        });
      },
    };
  }

  if (emailProvider === 'firestore_mail') {
    if (!db) {
      throw new EmailConfigError('Firestore instance required for firestore_mail provider.');
    }
    return {
      kind: 'firestore_mail',
      async send({to, subject, text, html}) {
        await db.collection('mail').add({
          to: [to],
          message: {subject, text, html},
        });
      },
    };
  }

  if (isEmulatorEnvironment(env) && db) {
    return {
      kind: 'emulator_sink',
      async send({to, subject, text, html, uid}) {
        await db.collection(EMULATOR_OUTBOX_COLLECTION).add({
          uid: uid || null,
          to,
          subject,
          text,
          html,
          createdAtMs: Date.now(),
        });
      },
    };
  }

  throw new EmailConfigError(
    'Verification email delivery is not configured. Configure SMTP secrets (SMTP_HOST, SMTP_USER, SMTP_PASS) or RESEND_API_KEY in Firebase Functions.',
  );
}

async function deliverVerificationEmail({
  to,
  displayName,
  code,
  uid,
  ttlMinutes = DEFAULT_TTL_MINUTES,
  env = process.env,
  secrets = {},
  db,
  customTransport,
}) {
  const backend = resolveEmailBackend({env, secrets, db, customTransport});
  const message = buildVerificationEmail({displayName, code, ttlMinutes});
  await backend.send({to, uid, ...message});
  return {provider: backend.kind};
}

module.exports = {
  DEFAULT_TTL_MINUTES,
  EMULATOR_OUTBOX_COLLECTION,
  EmailConfigError,
  buildVerificationEmail,
  deliverVerificationEmail,
  isEmulatorEnvironment,
  resolveEmailBackend,
};


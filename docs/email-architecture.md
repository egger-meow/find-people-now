# Email Architecture

This document describes the provider-neutral email sending layer, the env-var contract for
all email-related secrets, and the step-by-step migration guide for switching SMTP providers
(e.g. to Cloudflare Email) with **zero application-code changes**.

---

## Architecture Overview

```
                       ┌──────────────────────────────────────────┐
                       │   EmailSender interface                   │
                       │   (send-auth-email/email_sender.ts)       │
                       │                                           │
                       │   send(message: EmailMessage): Promise    │
                       └───────────────────┬──────────────────────┘
                                           │ implemented by
                                           ▼
                       ┌──────────────────────────────────────────┐
                       │   SmtpRoundRobinSender                   │
                       │   (send-auth-email/smtp_round_robin_     │
                       │    sender.ts)                            │
                       │                                          │
                       │   • reads SMTP_ACCOUNT_N_* env vars      │
                       │   • round-robins across N accounts       │
                       │   • sends via denomailer (TLS port 465)  │
                       └───────┬──────────────────────────────────┘
                               │ used by
              ┌────────────────┴───────────────────┐
              ▼                                     ▼
 ┌────────────────────────┐          ┌───────────────────────────┐
 │  send-auth-email       │          │  send-feedback-email      │
 │  (Auth / OTP hook)     │          │  (feedback notification)  │
 │                        │          │                           │
 │  GoTrue → this hook    │          │  Flutter → RPC →          │
 │  → emailSender.send()  │          │  this function →          │
 │                        │          │  emailSender.send()       │
 └────────────────────────┘          └───────────────────────────┘
```

Both Edge Functions import `EmailSender` from the same file and instantiate `SmtpRoundRobinSender`
at module scope. The interface is the stable contract; the sender implementation is swappable.

---

## Environment Variables

### SMTP Account Credentials
Read by `SmtpRoundRobinSender` (used by **both** email functions).

| Variable | Required | Default | Description |
|---|---|---|---|
| `SMTP_ACCOUNT_N_USER` | Yes (N=1) | — | SMTP authentication username (e.g. Gmail address). Probe starts at N=1 and stops at the first missing `USER`/`PASS` pair. |
| `SMTP_ACCOUNT_N_PASS` | Yes (N=1) | — | SMTP authentication password / app-password. |
| `SMTP_ACCOUNT_N_FROM` | No | `= USER` | Envelope sender address used in the MIME `From:` header. Set this when the display address should differ from the SMTP auth username (e.g. after moving to a custom domain or Cloudflare Email). Defaults to `USER` for backward compatibility — existing deployments need no change. |
| `SMTP_ACCOUNT_N_HOST` | No | `smtp.gmail.com` | SMTP server hostname. |
| `SMTP_ACCOUNT_N_PORT` | No | `465` | SMTP port. 465 = implicit TLS. If changing, also update the `tls` flag in `SmtpRoundRobinSender.send()`. |

> **Round-robin**: add `SMTP_ACCOUNT_2_USER/PASS`, `SMTP_ACCOUNT_3_USER/PASS`, etc. to spread
> sending across multiple accounts. The sender cycles through all loaded accounts sequentially.

### Auth Hook Secret
Used by `send-auth-email` only.

| Variable | Required | Description |
|---|---|---|
| `SEND_EMAIL_HOOK_SECRET` | Yes | Webhook signature secret (`v1,whsec_<base64>` format). Must match the value in `config.toml` `[auth.hook.send_email]` and the Supabase Auth Hook dashboard. |

### Feedback Email
Used by `send-feedback-email` only.

| Variable | Required | Description |
|---|---|---|
| `FEEDBACK_EMAIL_TO` | Yes | Destination address for feedback notification emails. |
| `FEEDBACK_EMAIL_FROM` | No | _(Legacy env var, currently unused at the SMTP level — the sender display name is controlled by `SMTP_ACCOUNT_N_FROM` or defaults to `SMTP_ACCOUNT_N_USER`.)_ Kept for future use if a provider-specific from-override is needed. |

---

## Local Development

Secrets for local Edge Function runs live in `supabase/functions/.env` (read by the local
edge-runtime container; **not** committed to git with real values):

```dotenv
SMTP_ACCOUNT_1_USER=your-gmail@example.com
SMTP_ACCOUNT_1_PASS=your-app-password
# Optional: override sender display address
# SMTP_ACCOUNT_1_FROM=noreply@yourdomain.com
SEND_EMAIL_HOOK_SECRET=v1,whsec_<base64>
FEEDBACK_EMAIL_TO=admin@yourdomain.com
```

The `supabase/.env` file feeds `config.toml`'s `env(...)` substitution (used by GoTrue) and
`supabase config push` / `secrets set --env-file`. It is separate from `functions/.env` — see the
comment at the top of both files for the distinction.

---

## Migrating to a New Email Provider

The entire migration is a **secrets-only operation** — no application code changes.

### Example: migrating to Cloudflare Email (SMTP relay)

1. **Get SMTP credentials** from Cloudflare Email > Settings > SMTP credentials.
2. **Update secrets** in the Supabase dashboard (or via CLI):
   ```bash
   supabase secrets set \
     SMTP_ACCOUNT_1_USER=<cloudflare-smtp-user> \
     SMTP_ACCOUNT_1_PASS=<cloudflare-smtp-password> \
     SMTP_ACCOUNT_1_HOST=<cloudflare-smtp-host> \
     SMTP_ACCOUNT_1_PORT=587 \
     SMTP_ACCOUNT_1_FROM=<your-verified-from-address>
   ```
3. **Remove old secrets** that are no longer needed (e.g. `RESEND_API_KEY` if it was set).
4. **Redeploy** edge functions to pick up the new secrets:
   ```bash
   supabase functions deploy send-auth-email
   supabase functions deploy send-feedback-email
   ```
5. **Test** by triggering an OTP login and submitting a feedback item in the app.

> [!NOTE]
> If Cloudflare Email uses port 587 (STARTTLS) instead of 465 (implicit TLS), also update the
> `tls: true` flag inside `SmtpRoundRobinSender.send()` to `tls: false` — that is the only code
> change that might be needed if the TLS handshake mode changes. Port and TLS mode are coupled
> (they are independent env vars on purpose for that reason).

### Example: migrating to a different provider with a dedicated SDK

If the target provider has its own SDK (e.g. SES, Resend, Postmark):

1. Create `supabase/functions/send-auth-email/<provider>_sender.ts` implementing `EmailSender`:
   ```typescript
   import type { EmailMessage, EmailSender } from "./email_sender.ts";
   export class MyProviderSender implements EmailSender {
     async send(message: EmailMessage): Promise<void> { /* ... */ }
   }
   ```
2. In both `send-auth-email/index.ts` and `send-feedback-email/index.ts`, change:
   ```typescript
   // Before:
   import { SmtpRoundRobinSender } from "./smtp_round_robin_sender.ts";
   const emailSender: EmailSender = new SmtpRoundRobinSender();
   // After:
   import { MyProviderSender } from "./myprovider_sender.ts";
   const emailSender: EmailSender = new MyProviderSender();
   ```
3. Update secrets.

Nothing else changes: GoTrue hook, OTP flow, Flutter code, DB schema, and Supabase config are
completely unaffected.

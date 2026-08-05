// =============================================================================
// TEMPORARY. This whole file exists only to work around Gmail's ~500/day
// per-account SMTP sending cap during pre-launch (no custom domain yet, see
// project memory project_production_launch_prep.md). Delete this file and
// the one `new SmtpRoundRobinSender(...)` line in index.ts once a real
// transactional provider (SES / Resend / Google Workspace) is adopted —
// nothing else needs to change, see index.ts header.
//
// Deliberately minimal, per the "temporary" brief:
//   - sequential round-robin via one in-memory counter, nothing fancier
//   - no retries, no failover, no health checks, no persistence
//   - if an account is down or throttled, this layer does not notice or
//     route around it — that's an accepted limitation of a stopgap
// =============================================================================

import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
import type { EmailMessage, EmailSender } from "./email_sender.ts";

interface SmtpAccount {
  host: string;
  port: number;
  user: string;
  pass: string;
}

// Accounts are read from SMTP_ACCOUNT_1_*, SMTP_ACCOUNT_2_*, ... and probed
// sequentially until one is missing USER/PASS — so the account count is
// env-driven, not a hardcoded limit.
function loadAccounts(): SmtpAccount[] {
  const accounts: SmtpAccount[] = [];
  for (let i = 1; ; i++) {
    const user = Deno.env.get(`SMTP_ACCOUNT_${i}_USER`);
    const pass = Deno.env.get(`SMTP_ACCOUNT_${i}_PASS`);
    if (!user || !pass) break;
    accounts.push({
      host: Deno.env.get(`SMTP_ACCOUNT_${i}_HOST`) ?? "smtp.gmail.com",
      // 465 = implicit TLS (paired with `tls: true` below), not 587's
      // plaintext-then-STARTTLS-upgrade — picked so the port and the `tls`
      // flag can't silently mismatch. If overriding via SMTP_ACCOUNT_*_PORT,
      // also flip `tls` below to match, or Gmail will refuse the handshake.
      port: Number(Deno.env.get(`SMTP_ACCOUNT_${i}_PORT`) ?? "465"),
      user,
      pass,
    });
  }
  return accounts;
}

export class SmtpRoundRobinSender implements EmailSender {
  private readonly accounts: SmtpAccount[];
  private nextIndex = 0;

  constructor() {
    this.accounts = loadAccounts();
    if (this.accounts.length === 0) {
      throw new Error(
        "SmtpRoundRobinSender: no SMTP_ACCOUNT_1_USER/PASS (etc.) env vars found",
      );
    }
  }

  async send(message: EmailMessage): Promise<void> {
    // Each edge function invocation runs single-threaded, so a plain
    // increment is effectively an atomic counter here — no locking needed.
    const accountIndex = this.nextIndex;
    this.nextIndex = (this.nextIndex + 1) % this.accounts.length;
    const account = this.accounts[accountIndex];

    console.log(`send-auth-email: using SMTP account #${accountIndex + 1}`);

    const client = new SMTPClient({
      connection: {
        hostname: account.host,
        port: account.port,
        tls: true,
        auth: { username: account.user, password: account.pass },
      },
    });

    try {
      await client.send({
        from: account.user,
        to: message.to,
        subject: message.subject,
        html: message.html,
      });
      console.log("send-auth-email: email sent successfully");
    } finally {
      await client.close();
    }
  }
}

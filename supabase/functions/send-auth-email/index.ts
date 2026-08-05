// =============================================================================
// Edge Function: send-auth-email — receiver for Supabase Auth's "Send Email"
// hook ([auth.hook.send_email] in supabase/config.toml).
//
// TEMPORARY WIRING NOTICE: this hook exists solely so OTP-login volume can be
// spread across multiple personal Gmail SMTP accounts — GoTrue's built-in
// `[auth.email.smtp]` only accepts a single account, and one Gmail account
// tops out around 500 sends/day (see project memory
// project_production_launch_prep.md). This function intercepts every auth
// email GoTrue would otherwise send itself and re-sends it via the
// `EmailSender` below.
//
// This is the ONLY thing that changes vs. GoTrue's built-in mailer. It does
// NOT touch OTP generation/verification (signInWithOtp / verifyOTP in
// otp_login_screen.dart are untouched), otp_length/otp_expiry, or
// [auth.rate_limit] — all of that still lives entirely in GoTrue exactly as
// before. It only replaces the delivery transport, and reproduces
// supabase/templates/magic_link.html's content inline, because GoTrue does
// not render `[auth.email.template.*]` files for hook-delivered mail — that
// template file is left untouched and simply goes unused while this hook is
// enabled.
//
// Future migration off the temporary round-robin sender: delete
// smtp_round_robin_sender.ts, add e.g. ses_sender.ts / resend_sender.ts
// implementing `EmailSender`, and change the one `new SmtpRoundRobinSender()`
// call below to `new SesSender()` / `new ResendSender()`. Nothing else in
// this file, in GoTrue, or in the Flutter app needs to change.
// =============================================================================

import { Webhook } from "npm:standardwebhooks@1.0.0";
import type { EmailSender } from "./email_sender.ts";
import { SmtpRoundRobinSender } from "./smtp_round_robin_sender.ts"; // TEMPORARY — see notice above

// v-- the one line that changes when migrating providers
const emailSender: EmailSender = new SmtpRoundRobinSender();

// Passed through exactly as issued (Supabase Dashboard's hook secret format,
// `v1,whsec_<base64>`) — the standardwebhooks Webhook class parses that
// format itself, so this deliberately does not strip anything.
const hookSecret = Deno.env.get("SEND_EMAIL_HOOK_SECRET") ?? "";

interface SendEmailPayload {
  user: { email: string };
  email_data: {
    token: string;
    token_hash: string;
    redirect_to: string;
    email_action_type: string;
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("METHOD_NOT_ALLOWED", { status: 405 });
  }

  const payload = await req.text();
  const headers = Object.fromEntries(req.headers);

  let parsed: SendEmailPayload;
  try {
    const wh = new Webhook(hookSecret);
    parsed = wh.verify(payload, headers) as SendEmailPayload;
  } catch {
    // Never log the payload/headers here — they carry the OTP token.
    console.error("send-auth-email: webhook signature verification failed");
    return new Response(
      JSON.stringify({ error: { http_code: 401, message: "Invalid signature" } }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const { user, email_data: emailData } = parsed;

  // 這支 App 目前只用 signInWithOtp()（見 otp_login_screen.dart），沒有密碼、
  // 邀請、email 變更等其他登入流程；GoTrue 仍會為所有 action type 呼叫這支
  // hook，非 OTP 登入的種類一律忽略（回 200，避免 GoTrue 判定失敗而重試）。
  if (
    emailData.email_action_type !== "magiclink" &&
    emailData.email_action_type !== "signup"
  ) {
    console.log(
      `send-auth-email: ignoring unsupported email_action_type=${emailData.email_action_type}`,
    );
    return new Response(JSON.stringify({}), { status: 200 });
  }

  // 內容對齊 supabase/templates/magic_link.html（該檔在這支 hook 啟用期間
  // 不會被 GoTrue 使用，但刻意保留不動，hook 停用時它會自動重新生效）。
  const subject = "你的驗證碼";
  const html = `
    <h2>你的驗證碼</h2>
    <p>請在 App 內輸入以下驗證碼完成登入：</p>
    <h1>${emailData.token}</h1>
    <p>如果你沒有嘗試登入，請忽略此信件。</p>
  `;

  try {
    await emailSender.send({ to: user.email, subject, html });
  } catch (err) {
    console.error(
      "send-auth-email: send failed:",
      err instanceof Error ? err.message : String(err),
    );
    return new Response(
      JSON.stringify({ error: { http_code: 500, message: "Email send failed" } }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(JSON.stringify({}), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

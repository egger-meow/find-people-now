// =============================================================================
// Edge Function: send-feedback-email（v1.25）
//
// 跟 delete-auth-user 同一種「唯一持有敏感金鑰的地方」精神：RESEND_API_KEY
// 絕對不能進 Flutter client，這支 Function 是唯一呼叫 Resend API 的地方。
//
// 呼叫順序（Flutter 端保證，見 lib/rpc/feedback_rpc.dart）：先
// submit_feedback() RPC 成功寫入 `feedback` 表（這一步是唯一保證存在的持久
// 記錄），才呼叫這支 Function 寄信。這支只接受 `feedback_id`，內容一律由
// 這裡用 service_role 重新查表取得——不接受呼叫端直接傳入信件內容，避免
// 有心人拿一個已通過驗證的 JWT 夾帶跟資料庫記錄不一致的內容寄信。
//
// 只認呼叫者自己的 JWT，且要求該 feedback row 的 user_id 必須等於呼叫者
// 自己——避免任何登入使用者拿別人的 feedback_id 重複觸發寄信（enumeration/
// 騷擾自己收件匣的疑慮，雖然影響有限，但檢查成本很低，順手擋掉）。
//
// 刻意不做成「失敗就整個請求失敗」：寄信只是盡力而為的通知管道，
// feedback row 本身才是唯一需要保證的持久資料（同 report/pending_review
// 的既有精神——人工/事後仍查得到，不靠這封信才算數）。呼叫端
// (lib/profile/feedback_screen.dart) 也據此設計：無論這支 Function 成功與
// 否，只要 RPC 成功就顯示「已收到你的回饋」。
// =============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'METHOD_NOT_ALLOWED' }), {
      status: 405,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'UNAUTHORIZED' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  let feedbackId: string | undefined
  try {
    const body = await req.json()
    feedbackId = body?.feedback_id
  } catch {
    // fall through to the missing-id check below
  }
  if (!feedbackId) {
    return new Response(JSON.stringify({ error: 'INVALID_INPUT', detail: 'FEEDBACK_ID_REQUIRED' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const resendApiKey = Deno.env.get('RESEND_API_KEY')
  const feedbackEmailTo = Deno.env.get('FEEDBACK_EMAIL_TO')
  // Resend's shared onboarding@resend.dev sender works with zero setup
  // (no domain verification needed) — good enough for MVP; swap in a
  // verified-domain address via this env var once one is set up in the
  // Resend dashboard for production.
  const feedbackEmailFrom = Deno.env.get('FEEDBACK_EMAIL_FROM') ?? 'Feedback <onboarding@resend.dev>'

  if (!resendApiKey || !feedbackEmailTo) {
    // Config gap, not a caller error — the feedback row is already durable
    // regardless (see file header). Logged server-side for ops to notice;
    // the client is designed to ignore this response either way.
    console.error('send-feedback-email misconfigured: missing RESEND_API_KEY or FEEDBACK_EMAIL_TO secret')
    return new Response(JSON.stringify({ error: 'EMAIL_NOT_CONFIGURED' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  const jwt = authHeader.replace(/^Bearer\s+/i, '')
  const { data: userData, error: userError } = await supabaseAdmin.auth.getUser(jwt)
  if (userError || !userData?.user) {
    return new Response(JSON.stringify({ error: 'UNAUTHORIZED' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const { data: feedbackRow, error: feedbackError } = await supabaseAdmin
    .from('feedback')
    .select('id, message, activity_id, app_version, device_info, created_at, user_id, app_user!inner(display_name, email)')
    .eq('id', feedbackId)
    .single()

  if (feedbackError || !feedbackRow) {
    return new Response(JSON.stringify({ error: 'NOT_FOUND' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
    })
  }
  if (feedbackRow.user_id !== userData.user.id) {
    return new Response(JSON.stringify({ error: 'FORBIDDEN' }), {
      status: 403,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const author = feedbackRow.app_user as unknown as { display_name: string; email: string }
  const html = `
    <p><strong>${escapeHtml(author.display_name)}</strong> (${escapeHtml(author.email)})</p>
    <p style="white-space: pre-wrap;">${escapeHtml(feedbackRow.message)}</p>
    <hr />
    <p style="color:#666;font-size:12px;">
      feedback_id: ${feedbackRow.id}<br/>
      activity_id: ${feedbackRow.activity_id ?? '-'}<br/>
      app_version: ${escapeHtml(feedbackRow.app_version ?? '-')}<br/>
      device: ${escapeHtml(feedbackRow.device_info ?? '-')}<br/>
      submitted_at: ${feedbackRow.created_at}
    </p>
  `

  const resendRes = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${resendApiKey}`,
    },
    body: JSON.stringify({
      from: feedbackEmailFrom,
      to: [feedbackEmailTo],
      subject: `[找人一起做點事] 新的使用者回饋`,
      html,
    }),
  })

  if (!resendRes.ok) {
    const detail = await resendRes.text()
    console.error('Resend send failed:', resendRes.status, detail)
    return new Response(JSON.stringify({ error: 'EMAIL_SEND_FAILED', detail }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  return new Response(JSON.stringify({ success: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})

function escapeHtml(input: string): string {
  return input
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

// =============================================================================
// Edge Function: send-push
// 職責：
// 1. 查詢目標使用者的有效 Web Push 訂閱 (user_push_subscription)
// 2. 構造無個人資訊 (No PII) 且具去重 tag 的推播 payload
// 3. 呼叫 Web Push 協議發送推播
// 4. 失敗處理：若端點回傳 404 / 410 (Gone)，自動清除失效端點，維持資料庫整潔
// =============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface PushRequest {
  notification_id?: string
  user_id?: string
  event_type?: string
  payload?: Record<string, unknown>
  title?: string
  body?: string
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'METHOD_NOT_ALLOWED' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return new Response(JSON.stringify({ error: 'UNAUTHORIZED' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const token = authHeader.replace(/^Bearer\s+/i, '').trim()
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const vapidPublicKey = Deno.env.get('VAPID_PUBLIC_KEY')
  const vapidPrivateKey = Deno.env.get('VAPID_PRIVATE_KEY')
  const vapidSubject = Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@findpeoplenow.internal'

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  // 驗證呼叫者權限：
  // 1. service_role key 擁有全域發送權限（後端 webhook / cron / matching engine）
  // 2. 一般使用者 JWT 僅允許向自己的帳號 (targetUserId === caller.id) 發送推播，嚴禁跨帳號代發
  const isServiceRole = token === serviceRoleKey
  let callerUserId: string | null = null

  if (!isServiceRole) {
    const { data: authData, error: authError } = await supabaseAdmin.auth.getUser(token)
    if (authError || !authData?.user) {
      return new Response(JSON.stringify({ error: 'UNAUTHORIZED', detail: 'INVALID_OR_EXPIRED_TOKEN' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    callerUserId = authData.user.id
  }

  let body: PushRequest
  try {
    body = await req.json()
  } catch (_) {
    return new Response(JSON.stringify({ error: 'INVALID_JSON' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  let targetUserId = body.user_id
  let eventType = body.event_type
  let payload = body.payload || {}

  // 若為一般使用者呼叫，嚴格限制只能向自己發送推播（防止跨使用者推播冒用）
  if (!isServiceRole) {
    if (targetUserId && targetUserId !== callerUserId) {
      return new Response(JSON.stringify({ error: 'FORBIDDEN', detail: 'CROSS_USER_PUSH_FORBIDDEN' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    if (!targetUserId) {
      targetUserId = callerUserId!
    }
  }

  // 若傳入 notification_id，自資料庫反查通知內容
  if (body.notification_id) {
    const { data: notif, error: notifError } = await supabaseAdmin
      .from('notification')
      .select('id, user_id, event_type, payload')
      .eq('id', body.notification_id)
      .single()

    if (notifError || !notif) {
      return new Response(JSON.stringify({ error: 'NOTIFICATION_NOT_FOUND' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // 一般使用者只能發送屬於自己的 notification
    if (!isServiceRole && notif.user_id !== callerUserId) {
      return new Response(JSON.stringify({ error: 'FORBIDDEN', detail: 'CANNOT_SEND_OTHERS_NOTIFICATION' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    targetUserId = notif.user_id
    eventType = notif.event_type
    payload = notif.payload as Record<string, unknown>
  }

  if (!targetUserId) {
    return new Response(JSON.stringify({ error: 'USER_ID_REQUIRED' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  // 查詢目標使用者的推播訂閱
  const { data: subscriptions, error: subError } = await supabaseAdmin
    .from('user_push_subscription')
    .select('id, endpoint, p256dh, auth')
    .eq('user_id', targetUserId)

  if (subError) {
    return new Response(JSON.stringify({ error: 'QUERY_SUBSCRIPTIONS_FAILED', detail: subError.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  if (!subscriptions || subscriptions.length === 0) {
    return new Response(JSON.stringify({ success: true, message: 'NO_SUBSCRIPTIONS_FOR_USER', sentCount: 0 }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  // 構造客觀、無 PII、具備去重 tag 的通知內容
  const s = (k: string) => payload[k] ? String(payload[k]) : ''
  let notifTitle = body.title || '敢不敢揪'
  let notifBody = body.body || '你有新的通知'
  let notifUrl = '/notifications'
  let notifTag = 'notif-' + (eventType || 'general')

  switch (eventType) {
    case 'MATCH_SUCCESS':
      notifTitle = '配對成功！'
      notifBody = '你的活動已經成團，點開查看地點與詳情'
      notifUrl = s('activity_id') ? `/activity/${s('activity_id')}` : '/my-activities'
      notifTag = `activity-${s('activity_id') || 'match'}`
      break
    case 'PENDING_CONFIRMATION':
      notifTitle = '找到相容的夥伴了！'
      notifBody = '雙方條件已吻合，請在限時內確認是否一起出發'
      notifUrl = '/my-activities'
      notifTag = `pc-${s('pending_confirmation_id') || s('request_id') || 'pending'}`
      break
    case 'DOWNGRADE_REQUEST':
      notifTitle = '有人數調整需要你同意'
      notifBody = `目前人數不夠，是否同意降到 ${s('target_size')} 人成局？`
      notifUrl = '/my-activities'
      notifTag = `downgrade-${s('downgrade_request_id') || 'request'}`
      break
    case 'MATCH_NOT_FORMED':
      notifTitle = '這次配對沒有成立'
      notifBody = '我們會繼續幫你留意合適的邀約'
      notifUrl = '/my-activities'
      notifTag = `match-not-formed-${s('request_id') || 'general'}`
      break
    case 'ACTIVITY_UPCOMING':
      notifTitle = '活動快開始了'
      notifBody = `還有 ${s('lead_minutes') || '少許'} 分鐘，記得看一下活動地點跟集合地點`
      notifUrl = s('activity_id') ? `/activity/${s('activity_id')}` : '/my-activities'
      notifTag = `upcoming-${s('activity_id')}`
      break
    case 'ACTIVITY_REMINDER':
      notifTitle = '活動開始了'
      notifBody = '時間到囉，記得看一下活動地點跟集合地點再出發'
      notifUrl = s('activity_id') ? `/activity/${s('activity_id')}` : '/my-activities'
      notifTag = `reminder-${s('activity_id')}`
      break
    case 'COMPLETE_CONFIRMATION':
      notifTitle = '活動結束了嗎？'
      notifBody = '花 10 秒回報一下，這次有順利進行嗎？'
      notifUrl = s('activity_id') ? `/activity/${s('activity_id')}` : '/my-activities'
      notifTag = `complete-${s('activity_id')}`
      break
  }

  const pushMessagePayload = JSON.stringify({
    title: notifTitle,
    body: notifBody,
    url: notifUrl,
    tag: notifTag,
    eventType: eventType,
    data: {
      url: notifUrl,
      eventType: eventType,
      payload: payload
    }
  })

  const staleEndpoints: string[] = []
  let sentSuccessCount = 0

  // 若未設定 VAPID 金鑰（如本機測試或無外部憑證環境）：安全模擬發送，記錄待驗證
  if (!vapidPublicKey || !vapidPrivateKey) {
    return new Response(JSON.stringify({
      success: true,
      mode: 'simulated',
      message: 'VAPID credentials not configured in environment. Push dispatch payload constructed safely.',
      targetUserId,
      subscriptionsCount: subscriptions.length,
      payload: JSON.parse(pushMessagePayload)
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  // 若有 VAPID 金鑰，依 Web Push 標準 (RFC 8291 / RFC 8292) 加密與簽名發送
  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey)

  for (const sub of subscriptions) {
    try {
      const pushSubscription = {
        endpoint: sub.endpoint,
        keys: {
          p256dh: sub.p256dh,
          auth: sub.auth,
        },
      }
      await webpush.sendNotification(pushSubscription, pushMessagePayload, {
        TTL: 86400,
      })
      sentSuccessCount++
    } catch (err: any) {
      const statusCode = err?.statusCode || err?.status
      if (statusCode === 404 || statusCode === 410) {
        // 端點已失效（使用者取消訂閱或解除安裝 SW）：標記清理
        staleEndpoints.push(sub.endpoint)
      } else {
        console.error(`Push dispatch failed for endpoint ${sub.endpoint}:`, err?.message || err)
      }
    }
  }

  // 自動清理失效端點
  if (staleEndpoints.length > 0) {
    await supabaseAdmin.rpc('cleanup_stale_push_subscriptions', {
      p_endpoints: staleEndpoints,
    })
  }

  const isDispatchSuccess = subscriptions.length === 0 || sentSuccessCount > 0
  return new Response(JSON.stringify({
    success: isDispatchSuccess,
    sentCount: sentSuccessCount,
    cleanedStaleCount: staleEndpoints.length,
    totalSubscriptions: subscriptions.length,
  }), {
    status: isDispatchSuccess ? 200 : 502,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
})

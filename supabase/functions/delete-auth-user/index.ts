// =============================================================================
// Edge Function: delete-auth-user（v1.14）
//
// 這是整個帳號刪除功能唯一偏離「純 SQL RPC」慣例的地方，理由記錄在對話與
// docs/SPEC.md v1.14 變更紀錄裡，這裡只重申結論：
//   刪除 auth.users 那一列（含清 GoTrue 內部的 sessions/refresh_tokens/
//   identities）只有官方 Admin API `auth.admin.deleteUser()` 有維護保證，而
//   它強制要求 service_role/secret key（GOTRUE_JWT_ADMIN_ROLES），這把 key
//   絕對不能進 Flutter client。這支 Function 是唯一持有這把 key 的地方，
//   職責僅止於「驗證呼叫者身分 → 呼叫官方 Admin API 做 soft delete」，不做
//   任何業務資料清理（那些全部由 Flutter 先呼叫 delete_account() RPC 完成，
//   見 20260724122700_delete_account_rpc.sql）。
//
// 呼叫順序（Flutter 端保證）：先 delete_account() RPC 成功，才呼叫這支。
// 這支只認呼叫者自己的 JWT（Authorization header），不接受任何外部傳入的
// user id 參數，避免被拿來刪除別人的帳號。
//
// shouldSoftDelete 明確傳 true：官方文件與原始碼都確認這個參數預設是
// false（backward compatibility），不明確傳的話會變成真正的 hard delete，
// 沒有「保留 deleted_at 殼、之後可能需要稽核」的空間，也會意外撞上
// app_user.id references auth.users(id) on delete cascade（見 schema
// migration 檔頭說明）。
//
// 冪等性— 已用本地環境實測過，記錄真實行為而非假設：
//   `auth.admin.deleteUser(id, true)` 本身對已經 soft-delete 過的帳號重複
//   呼叫是安全的 no-op（GoTrue 原始碼 internal/api/admin.go：
//   `if params.ShouldSoftDelete { if user.DeletedAt != nil { return nil } }`）。
//   但這支 Function 在呼叫它之前，會先用呼叫者自己的 JWT 呼叫
//   `supabaseAdmin.auth.getUser(jwt)` 來解析身分——實測發現，帳號一旦被
//   soft-delete，同一把（尚未自然過期的）access token 拿去打 getUser 會直接
//   回 401，根本進不到 deleteUser 那一步。也就是說「重複呼叫這支 Function」
//   不會是「兩次都 200」，而是「第一次 200，之後每次都 401」——但這正是
//   Flutter 端 account_deletion.dart 的重試設計本來就能正確處理的情況：
//   只要第一次已經成功，後續重試失敗也無所謂，反正最終都會走到本地登出。
// =============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'

// 全面檢查發現：這支 Function 完全沒處理 CORS。`client.functions.invoke()`
// 在 Flutter Web 上底層是瀏覽器 fetch，會先送 OPTIONS 預檢請求——這支
// Function 原本對非 POST 一律回 405，OPTIONS 也不例外，預檢一定失敗，等於
// Web 版帳號刪除功能整個打不通（原生 iOS/Android 走的是 HTTP client，不受
// CORS 限制，才沒被先發現）。
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'UNAUTHORIZED' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  // service_role client：唯一用途是驗證呼叫者 JWT + 執行 Admin API，兩者都
  // 需要這把 key，不需要另外一個 anon client
  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  const jwt = authHeader.replace(/^Bearer\s+/i, '')
  const { data: userData, error: userError } = await supabaseAdmin.auth.getUser(jwt)

  if (userError || !userData?.user) {
    return new Response(JSON.stringify({ error: 'UNAUTHORIZED' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const { error: deleteError } = await supabaseAdmin.auth.admin.deleteUser(
    userData.user.id,
    true // shouldSoftDelete — 見檔頭說明，不能省略
  )

  if (deleteError) {
    return new Response(JSON.stringify({ error: 'AUTH_DELETE_FAILED', detail: deleteError.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  return new Response(JSON.stringify({ success: true }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
})

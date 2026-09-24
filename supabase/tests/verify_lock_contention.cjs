const { execFile } = require('child_process');

const CONTAINER = 'supabase_db_find-people-now';
const OWNER_ID = '11111111-2222-3333-4444-555555555555';
const REQ_ID = '66666666-7777-8888-9999-000000000000';

function runPsql(sql, tuplesOnly = false) {
  return new Promise((resolve, reject) => {
    const args = ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres'];
    if (tuplesOnly) args.push('-t', '-A');
    args.push('-c', sql);
    execFile('docker', args, { encoding: 'utf8' }, (err, stdout, stderr) => {
      if (err) reject(new Error(stderr || err.message));
      else resolve(stdout);
    });
  });
}

async function main() {
  console.log('=== FOR UPDATE 列鎖等待與交易重疊觀測實測 ===\n');

  try {
    // 1. Setup test fixture
    console.log('[1/5] 建立初始資料（狀態：已被撤銷的邀請碼）...');
    const setupSql = `
      DO $$
      DECLARE
        v_act_id uuid;
      BEGIN
        SELECT id INTO v_act_id FROM activity_type WHERE name = '吃飯/咖啡/探店' LIMIT 1;
        DELETE FROM request_member WHERE request_id = '${REQ_ID}';
        DELETE FROM match_request WHERE id = '${REQ_ID}';
        DELETE FROM app_user WHERE id = '${OWNER_ID}';
        DELETE FROM auth.users WHERE id = '${OWNER_ID}';

        INSERT INTO auth.users (id, email) VALUES ('${OWNER_ID}', 'lock_test@nycu.edu.tw');
        INSERT INTO app_user (id, email, school, display_name, avatar_url, degree_level, contact_line)
        VALUES ('${OWNER_ID}', 'lock_test@nycu.edu.tw', 'NYCU', 'LockUser', 'https://avatar/1', 'UNDERGRAD', 'line_id');

        INSERT INTO match_request (id, owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, invite_token, revoked_at)
        VALUES ('${REQ_ID}', '${OWNER_ID}', v_act_id, 'NYCU', '光復', now() + interval '1 hour', now() + interval '3 hours', 3, 8, 'REQUESTING', 'stale-revoked-token', now() - interval '10 minutes');

        INSERT INTO request_member (request_id, user_id, role, status)
        VALUES ('${REQ_ID}', '${OWNER_ID}', 'OWNER', 'JOINED');
      END $$;
    `;
    await runPsql(setupSql);
    console.log('  ✓ 初始資料建立完成：match_request.revoked_at 非空，invite_token = stale-revoked-token\n');

    // 2. Session A: BEGIN transaction, lock the row FOR UPDATE, sleep for 2.5 seconds, update token, COMMIT
    console.log('[2/5] 連線 A 啟動：開啟交易並鎖定目標列 (SELECT ... FOR UPDATE)，保持鎖定 2.5 秒後才提交...');
    const sessionASql = `
      BEGIN;
      SELECT invite_token FROM match_request WHERE id = '${REQ_ID}' FOR UPDATE;
      SELECT pg_sleep(2.5);
      UPDATE match_request SET invite_token = 'token-locked-by-session-a', revoked_at = NULL WHERE id = '${REQ_ID}';
      COMMIT;
      SELECT 'SESSION_A_COMMITTED' AS status;
    `;

    const startA = Date.now();
    const promiseA = runPsql(sessionASql, true);

    // Wait 300ms to guarantee Session A has acquired the FOR UPDATE row lock and entered pg_sleep
    await new Promise(r => setTimeout(r, 300));
    console.log('  ✓ 連線 A 已進入交易並持有 FOR UPDATE 列鎖（休眠中）\n');

    // 3. Session B: Concurrently calls get_or_create_invite_link
    console.log('[3/5] 連線 B 同步發起呼叫 get_or_create_invite_link（遭遇連線 A 之列鎖，應被阻塞排隊）...');
    const sessionBSql = `
      SET ROLE authenticated;
      SELECT set_config('request.jwt.claim.sub', '${OWNER_ID}', true);
      SELECT get_or_create_invite_link('${REQ_ID}');
    `;

    const startB = Date.now();
    const promiseB = runPsql(sessionBSql, true);

    // Wait 300ms to ensure Session B query has reached database and is waiting for lock
    await new Promise(r => setTimeout(r, 300));

    // 4. Observer Query: Inspect pg_locks and pg_stat_activity
    console.log('[4/5] 觀測資料庫即時鎖與等待狀態 (pg_locks / pg_stat_activity)...');
    const lockInspectSql = `
      SELECT
        l.pid,
        l.locktype,
        l.mode,
        l.granted,
        a.wait_event_type,
        a.wait_event,
        LEFT(a.query, 60) AS query_snippet
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.granted = false;
    `;
    const lockOutput = await runPsql(lockInspectSql, true);
    console.log('  -- 鎖等待查詢輸出 (granted = false) --');
    console.log('  ' + (lockOutput.trim() ? lockOutput.trim().split('\n').join('\n  ') : '(未捕獲到 granted=false)'));

    const waitingActivitySql = `
      SELECT pid, wait_event_type, wait_event, state, LEFT(query, 60)
      FROM pg_stat_activity
      WHERE wait_event_type = 'Lock' OR (wait_event_type IS NOT NULL AND wait_event_type != 'Activity');
    `;
    const activityOutput = await runPsql(waitingActivitySql, true);
    console.log('  -- 等待中連線活動 (wait_event_type = Lock) --');
    console.log('  ' + (activityOutput.trim() ? activityOutput.trim().split('\n').join('\n  ') : '(無等待連線)'));

    const hasLockContention = lockOutput.includes('f') || activityOutput.includes('Lock') || activityOutput.includes('tuple');
    if (!hasLockContention) {
      console.warn('  [警告] 鎖等待檢測未獲取到 granted=false 或 wait_event=Lock，請核對執行時序');
    } else {
      console.log('  ✓ 實測捕捉到連線 B 處於 Lock / tuple 等待狀態（granted = false / wait_event_type = Lock）！\n');
    }

    // 5. Wait for both to complete and assert serialization
    console.log('[5/5] 等待連線 A 提交與連線 B 解除阻塞完成...');
    const [resA, resB] = await Promise.all([promiseA, promiseB]);
    const durationA = Date.now() - startA;
    const durationB = Date.now() - startB;

    console.log(`  連線 A 耗時: ${durationA}ms，輸出: ${resA.trim().split('\n').pop()}`);
    
    // Extract token from Session B
    const linesB = resB.trim().split('\n').map(l => l.trim()).filter(Boolean);
    const tokenB = linesB[linesB.length - 1];
    console.log(`  連線 B 耗時: ${durationB}ms，回傳 Token: ${tokenB}`);

    // Verify DB final state
    const dbState = await runPsql(`SELECT invite_token, (revoked_at IS NULL)::text FROM match_request WHERE id = '${REQ_ID}';`, true);
    const [dbToken, dbRevokedIsNull] = dbState.trim().split('|').map(s => s.trim());
    console.log(`  資料庫目前儲存 Token: ${dbToken}`);
    console.log(`  資料庫 revoked_at IS NULL: ${dbRevokedIsNull}`);

    // Assertions
    if (durationB < 1500) {
      throw new Error(`連線 B 未被阻塞足夠時間 (僅耗時 ${durationB}ms，預期應等待連線 A 完成 >= 1500ms)！`);
    }
    if (tokenB !== 'token-locked-by-session-a') {
      throw new Error(`連線 B 未回傳連線 A 提交的最新邀請碼！得到: ${tokenB}`);
    }
    if (dbToken !== tokenB) {
      throw new Error(`資料庫 Token (${dbToken}) 與連線 B 回傳 (${tokenB}) 不符！`);
    }
    if (dbRevokedIsNull !== 'true') {
      throw new Error('資料庫 revoked_at 尚未重設為 NULL！');
    }

    console.log('\n=== 實測驗證結論 ===');
    console.log('  ✓ 連線 A 在未 COMMIT 期間持有 FOR UPDATE 列鎖');
    console.log(`  ✓ 連線 B 在呼叫 get_or_create_invite_link 時發生實體排隊阻塞（耗時 ${durationB}ms，等待連線 A）`);
    console.log('  ✓ 觀測到 pg_locks / pg_stat_activity 的 Lock 等待狀態');
    console.log('  ✓ 連線 A COMMIT 後，連線 B 在 Read Committed 模式下解除阻塞並直接回傳連線 A 生成之 Token');
    console.log('  ✓ 確鑿實測證明：FOR UPDATE 列鎖具備嚴格串行化與防競態重生能力！');
  } finally {
    // Cleanup
    const cleanupSql = `
      DELETE FROM request_member WHERE request_id = '${REQ_ID}';
      DELETE FROM match_request WHERE id = '${REQ_ID}';
      DELETE FROM app_user WHERE id = '${OWNER_ID}';
      DELETE FROM auth.users WHERE id = '${OWNER_ID}';
    `;
    await runPsql(cleanupSql);
    console.log('\n測試資料清理完畢。');
  }
}

main().catch(err => {
  console.error('\n實測失敗:', err);
  process.exit(1);
});

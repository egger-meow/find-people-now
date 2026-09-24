const { execFile } = require('child_process');

const CONTAINER = 'supabase_db_find-people-now';
const OWNER_ID = '11111111-2222-3333-4444-555555555555';
const REQ_ID = '66666666-7777-8888-9999-000000000000';

function runPsql(sql, options = {}) {
  return new Promise((resolve, reject) => {
    const args = ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres'];
    if (options.tuplesOnly) {
      args.push('-t', '-A');
    }
    args.push('-c', sql);

    execFile('docker', args, { encoding: 'utf8' }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`psql error: ${stderr || error.message}`));
      } else {
        resolve(stdout);
      }
    });
  });
}

async function main() {
  console.log('=== 邀請碼並發列鎖 (FOR UPDATE) 實測 ===');

  try {
    // 1. Setup test fixture
    console.log('[1/4] 準備測試資料（狀態：已被撤銷的邀請碼）...');
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

        INSERT INTO auth.users (id, email) VALUES ('${OWNER_ID}', 'concurrent_test@nycu.edu.tw');
        INSERT INTO app_user (id, email, school, display_name, avatar_url, degree_level, contact_line)
        VALUES ('${OWNER_ID}', 'concurrent_test@nycu.edu.tw', 'NYCU', 'ConcurrentUser', 'https://avatar/1', 'UNDERGRAD', 'line_id');

        INSERT INTO match_request (id, owner_id, activity_type_id, school, campus, earliest_start, latest_start, min_participants, max_participants, status, invite_token, revoked_at)
        VALUES ('${REQ_ID}', '${OWNER_ID}', v_act_id, 'NYCU', '光復', now() + interval '1 hour', now() + interval '3 hours', 3, 8, 'REQUESTING', 'stale-revoked-token-old', now() - interval '10 minutes');

        INSERT INTO request_member (request_id, user_id, role, status)
        VALUES ('${REQ_ID}', '${OWNER_ID}', 'OWNER', 'JOINED');
      END $$;
    `;
    await runPsql(setupSql);
    console.log('  ✓ 測試資料建立完成：match_request.revoked_at 非空，invite_token = stale-revoked-token-old');

    // 2. Launch concurrent connections
    console.log('[2/4] 啟動 5 個獨立連線同時並發呼叫 get_or_create_invite_link...');
    const workerSql = `
      SET ROLE authenticated;
      SELECT set_config('request.jwt.claim.sub', '${OWNER_ID}', true);
      SELECT get_or_create_invite_link('${REQ_ID}');
    `;

    const CONCURRENCY_COUNT = 5;
    const promises = Array.from({ length: CONCURRENCY_COUNT }, (_, i) =>
      runPsql(workerSql, { tuplesOnly: true }).then(output => {
        // Find the token line (last non-empty line)
        const lines = output.trim().split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        const token = lines[lines.length - 1];
        return { index: i + 1, token };
      })
    );

    const results = await Promise.all(promises);
    console.log('[3/4] 接收到各連線回傳結果：');
    results.forEach(r => {
      console.log(`  連線 ${r.index} 回傳 Token: ${r.token}`);
    });

    // 3. Inspect database state
    const queryDbSql = `SELECT invite_token, (revoked_at IS NULL)::text FROM match_request WHERE id = '${REQ_ID}';`;
    const dbOutput = await runPsql(queryDbSql, { tuplesOnly: true });
    const [dbToken, dbRevokedIsNull] = dbOutput.trim().split('|').map(s => s.trim());

    console.log(`  資料庫目前儲存 Token: ${dbToken}`);
    console.log(`  資料庫 revoked_at IS NULL: ${dbRevokedIsNull}`);

    // 4. Assertions
    const uniqueTokens = new Set(results.map(r => r.token));
    if (uniqueTokens.size !== 1) {
      throw new Error(`並發測試失敗：各連線回傳了不同的邀請碼: ${[...uniqueTokens].join(', ')}，列鎖未生效！`);
    }

    const firstToken = results[0].token;
    if (firstToken === 'stale-revoked-token-old') {
      throw new Error('並發測試失敗：依然回傳已撤銷的舊碼！');
    }

    if (firstToken !== dbToken) {
      throw new Error(`並發測試失敗：回傳邀請碼 (${firstToken}) 與資料庫儲存 (${dbToken}) 不一致！`);
    }

    if (dbRevokedIsNull !== 'true') {
      throw new Error('並發測試失敗：資料庫 revoked_at 尚未重設為 NULL！');
    }

    console.log('[4/4] 測試全數 PASS！');
    console.log(`  ✓ 全部 ${CONCURRENCY_COUNT} 個獨立並發連線取得完全一致的全新邀請碼 (${firstToken})`);
    console.log('  ✓ FOR UPDATE 列鎖成功串行化重新生成，無競態覆寫或不同碼問題');
    console.log('  ✓ match_request.revoked_at 已重設為 NULL');
  } finally {
    // Cleanup
    console.log('清理測試資料...');
    const cleanupSql = `
      DELETE FROM request_member WHERE request_id = '${REQ_ID}';
      DELETE FROM match_request WHERE id = '${REQ_ID}';
      DELETE FROM app_user WHERE id = '${OWNER_ID}';
      DELETE FROM auth.users WHERE id = '${OWNER_ID}';
    `;
    await runPsql(cleanupSql);
    console.log('清理完畢。');
  }
}

main().catch(err => {
  console.error('測試失敗:', err);
  process.exit(1);
});

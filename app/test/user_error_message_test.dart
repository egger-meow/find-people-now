import 'package:flutter_test/flutter_test.dart';

import 'package:find_people_now/errors/user_error_message.dart';
import 'package:find_people_now/rpc/api_exception.dart';

void main() {
  test('已知業務錯誤轉成可行動的繁中提示', () {
    final error = ApiException(
      code: ApiErrorCode.inviteLinkExpired,
      rawMessage: 'INVITE_LINK_EXPIRED',
      detail: 'developer-only database detail',
    );

    expect(userErrorMessage(error), '邀請碼已失效，請向發起人取得新的邀請碼');
  });

  test('未知 API 錯誤不洩漏 raw message 或 detail', () {
    final error = ApiException(
      code: ApiErrorCode.unknown,
      rawMessage: 'PGRST_INTERNAL_SECRET',
      detail: 'relation public.private_table does not exist',
    );

    final message = userErrorMessage(error);
    expect(message, userSafeUnexpectedErrorMessage);
    expect(message, isNot(contains('PGRST')));
    expect(message, isNot(contains('private_table')));
  });

  test('任意 runtime exception 一律使用安全通用訊息', () {
    const secret = 'SocketException: host=db.internal.local';
    final message = userErrorMessage(StateError(secret));

    expect(message, userSafeUnexpectedErrorMessage);
    expect(message, isNot(contains(secret)));
  });
}

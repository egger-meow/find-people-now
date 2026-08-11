import 'package:flutter/foundation.dart';

import '../rpc/api_exception.dart';

const userSafeUnexpectedErrorMessage = 'Oops！系統出了點狀況，請稍後再試';

/// Only messages declared in this file may be derived from a runtime error.
/// Raw backend text, details, hints and exception strings must never reach UI.
String userErrorMessage(Object error, {StackTrace? stackTrace}) {
  if (kDebugMode) {
    debugPrint('User-facing operation failed: $error');
    if (stackTrace != null) debugPrintStack(stackTrace: stackTrace);
  }

  if (error is! ApiException) return userSafeUnexpectedErrorMessage;

  return switch (error.code) {
    ApiErrorCode.unauthorized => '登入狀態已失效，請重新登入',
    ApiErrorCode.userSuspended => '帳號目前暫停使用，如有疑問請聯絡客服',
    ApiErrorCode.profileIncomplete => '請先完成個人資料再繼續',
    ApiErrorCode.degreeLevelRequired => '請先補上年級資料再繼續',
    ApiErrorCode.noContactMethod => '請先新增至少一種聯絡方式',
    ApiErrorCode.invalidEmailDomain => '請使用學校信箱登入',
    ApiErrorCode.invalidInput ||
    ApiErrorCode.invalidMinParticipants ||
    ApiErrorCode.invalidMaxParticipants ||
    ApiErrorCode.invalidGroupSizeOption ||
    ApiErrorCode.invalidCampusScope => '部分資料不正確，請檢查後再試',
    ApiErrorCode.schoolLocationMismatch => '這個地點不在所選校區，請重新選擇',
    ApiErrorCode.notFound => '找不到這筆資料，可能已被移除',
    ApiErrorCode.requestNotOpen => '這個揪團目前無法加入',
    ApiErrorCode.activeActivityInProgress => '目前已有進行中的活動，結束後才能建立新的揪團',
    ApiErrorCode.requestCooldownActive => '操作太頻繁了，請稍後再試',
    ApiErrorCode.alreadyRequesting => '你已經有一個配對中的揪團',
    ApiErrorCode.windowExceeds24h => '可配對時段不能超過 24 小時',
    ApiErrorCode.newUserLowHeadcount => '新帳號目前只能建立較多人數的揪團',
    ApiErrorCode.inviteLinkExpired => '邀請碼已失效，請向發起人取得新的邀請碼',
    ApiErrorCode.requestFull => '這個揪團已經額滿',
    ApiErrorCode.confirmationWindowClosed => '確認時間已結束',
    ApiErrorCode.forbidden || ApiErrorCode.notActivityMember => '你目前沒有權限執行這個操作',
    ApiErrorCode.alreadyReported => '你已經回報過了',
    ApiErrorCode.consentWindowClosed => '回應時間已結束',
    ApiErrorCode.alreadyResponded => '你已經完成回應',
    ApiErrorCode.activityNotActive => '這個活動目前無法進行此操作',
    ApiErrorCode.meetingPointUpdateCooldown => '集合資訊剛更新過，請稍後再試',
    ApiErrorCode.accountDeleted => '這個帳號已不存在',
    ApiErrorCode.activityNotEnded => '活動尚未結束，暫時無法送出回報',
    ApiErrorCode.invalidAbsentTarget => '無法回報這位成員，請重新確認',
    ApiErrorCode.tooManyAlertSubscriptions => '通知條件已達上限，請先移除一個再新增',
    ApiErrorCode.duplicateTypeName ||
    ApiErrorCode.duplicateLocationName => '這個名稱已經有人使用',
    ApiErrorCode.unknown => userSafeUnexpectedErrorMessage,
  };
}

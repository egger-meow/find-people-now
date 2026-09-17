import 'package:supabase_flutter/supabase_flutter.dart';
import 'web_push_service.dart';

/// 非 Web 環境（VM 測試、原生）的 Stub 實作：安全降級，不拋出錯誤。
class WebPushServiceImpl implements WebPushService {
  const WebPushServiceImpl();

  @override
  bool get isSupported => false;

  @override
  Future<PushPermissionStatus> checkPermission() async => PushPermissionStatus.unsupported;

  @override
  Future<PushPermissionStatus> requestPermission() async => PushPermissionStatus.unsupported;

  @override
  Future<PushSubscriptionPayload?> subscribe({String? vapidPublicKey}) async => null;

  @override
  Future<bool> unsubscribe() async => true;

  @override
  Future<PushSubscriptionPayload?> getCurrentSubscription() async => null;

  @override
  Future<void> syncWithServer(SupabaseClient client, {String? vapidPublicKey}) async {}

  @override
  Future<void> onSignOut(SupabaseClient client) async {}
}

WebPushService createWebPushService() => const WebPushServiceImpl();

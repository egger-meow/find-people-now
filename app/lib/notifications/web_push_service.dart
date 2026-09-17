import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import 'web_push_service_stub.dart'
    if (dart.library.js_interop) 'web_push_service_web.dart';

export 'web_push_service_stub.dart'
    if (dart.library.js_interop) 'web_push_service_web.dart'
    show createWebPushService;

enum PushPermissionStatus {
  defaultStatus,
  granted,
  denied,
  unsupported,
}

class PushSubscriptionPayload {
  final String endpoint;
  final String p256dh;
  final String auth;
  final String? userAgent;

  const PushSubscriptionPayload({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
    this.userAgent,
  });

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'p256dh': p256dh,
    'auth': auth,
    if (userAgent != null) 'user_agent': userAgent,
  };
}

abstract class WebPushService {
  bool get isSupported;
  Future<PushPermissionStatus> checkPermission();
  Future<PushPermissionStatus> requestPermission();
  Future<PushSubscriptionPayload?> subscribe({String? vapidPublicKey});
  Future<bool> unsubscribe();
  Future<PushSubscriptionPayload?> getCurrentSubscription();
  Future<void> syncWithServer(SupabaseClient client, {String? vapidPublicKey});
  Future<void> onSignOut(SupabaseClient client);
}

final webPushServiceProvider = Provider<WebPushService>((ref) {
  return createWebPushService();
});

final pushPermissionStatusProvider = FutureProvider<PushPermissionStatus>((ref) async {
  final service = ref.watch(webPushServiceProvider);
  if (!service.isSupported) return PushPermissionStatus.unsupported;
  return service.checkPermission();
});

final pushSyncCoordinatorProvider = Provider<void>((ref) {
  final service = ref.watch(webPushServiceProvider);
  final client = ref.watch(supabaseClientProvider);
  ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
    final state = next.value;
    if (state == null) return;
    if (state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.tokenRefreshed ||
        state.event == AuthChangeEvent.initialSession) {
      if (state.session != null) {
        service.syncWithServer(client);
      }
    } else if (state.event == AuthChangeEvent.signedOut) {
      service.onSignOut(client);
    }
  });
});

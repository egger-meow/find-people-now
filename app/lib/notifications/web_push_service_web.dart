import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'web_push_service.dart';

class WebPushServiceImpl implements WebPushService {
  const WebPushServiceImpl();

  JSObject? get _helper {
    if (!globalContext.hasProperty('FindPeopleWebPush'.toJS).toDart) return null;
    return globalContext.getProperty('FindPeopleWebPush'.toJS) as JSObject?;
  }

  @override
  bool get isSupported {
    final helper = _helper;
    if (helper == null) return false;
    try {
      final res = helper.callMethod('isSupported'.toJS);
      return (res as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PushPermissionStatus> checkPermission() async {
    final helper = _helper;
    if (helper == null) return PushPermissionStatus.unsupported;
    try {
      final res = helper.callMethod('getPermission'.toJS);
      final str = (res as JSString).toDart;
      return switch (str) {
        'granted' => PushPermissionStatus.granted,
        'denied' => PushPermissionStatus.denied,
        'default' => PushPermissionStatus.defaultStatus,
        _ => PushPermissionStatus.unsupported,
      };
    } catch (_) {
      return PushPermissionStatus.unsupported;
    }
  }

  @override
  Future<PushPermissionStatus> requestPermission() async {
    final helper = _helper;
    if (helper == null) return PushPermissionStatus.unsupported;
    try {
      final promise = helper.callMethod('requestPermission'.toJS) as JSPromise;
      final res = await promise.toDart;
      final str = (res as JSString).toDart;
      return switch (str) {
        'granted' => PushPermissionStatus.granted,
        'denied' => PushPermissionStatus.denied,
        'default' => PushPermissionStatus.defaultStatus,
        _ => PushPermissionStatus.unsupported,
      };
    } catch (_) {
      return PushPermissionStatus.denied;
    }
  }

  @override
  Future<PushSubscriptionPayload?> subscribe({String? vapidPublicKey}) async {
    final helper = _helper;
    if (helper == null) return null;
    try {
      final promise = helper.callMethod(
        'subscribe'.toJS,
        vapidPublicKey != null ? vapidPublicKey.toJS : null,
      ) as JSPromise;
      final res = await promise.toDart;
      if (res == null) return null;
      final str = (res as JSString).toDart;
      if (str.isEmpty) return null;
      final map = jsonDecode(str) as Map<String, dynamic>;
      return PushSubscriptionPayload(
        endpoint: map['endpoint'] as String,
        p256dh: map['p256dh'] as String,
        auth: map['auth'] as String,
        userAgent: map['userAgent'] as String?,
      );
    } catch (e) {
      debugPrint('WebPush subscribe error: $e');
      return null;
    }
  }

  @override
  Future<bool> unsubscribe() async {
    final helper = _helper;
    if (helper == null) return true;
    try {
      final promise = helper.callMethod('unsubscribe'.toJS) as JSPromise;
      final res = await promise.toDart;
      return (res as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PushSubscriptionPayload?> getCurrentSubscription() async {
    final helper = _helper;
    if (helper == null) return null;
    try {
      final promise = helper.callMethod('getCurrentSubscription'.toJS) as JSPromise;
      final res = await promise.toDart;
      if (res == null) return null;
      final str = (res as JSString).toDart;
      if (str.isEmpty) return null;
      final map = jsonDecode(str) as Map<String, dynamic>;
      return PushSubscriptionPayload(
        endpoint: map['endpoint'] as String,
        p256dh: map['p256dh'] as String,
        auth: map['auth'] as String,
        userAgent: map['userAgent'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> syncWithServer(SupabaseClient client, {String? vapidPublicKey}) async {
    if (!isSupported) return;
    final perm = await checkPermission();
    if (perm != PushPermissionStatus.granted) return;

    final sub = await subscribe(vapidPublicKey: vapidPublicKey);
    if (sub == null) return;

    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      await client.rpc('save_push_subscription', params: {
        'p_endpoint': sub.endpoint,
        'p_p256dh': sub.p256dh,
        'p_auth': sub.auth,
        'p_user_agent': sub.userAgent,
      });
    } catch (e) {
      debugPrint('sync push subscription error: $e');
    }
  }

  @override
  Future<void> onSignOut(SupabaseClient client) async {
    if (!isSupported) return;
    try {
      final sub = await getCurrentSubscription();
      if (sub != null) {
        await client.rpc('remove_push_subscription', params: {
          'p_endpoint': sub.endpoint,
        }).catchError((_) {});
        await unsubscribe();
      }
    } catch (_) {}
  }
}

WebPushService createWebPushService() => const WebPushServiceImpl();

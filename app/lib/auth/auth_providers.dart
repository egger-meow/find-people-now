import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The single [SupabaseClient] instance — `Supabase.instance.client` wrapped
/// so the rest of the app depends on a provider, not a global singleton
/// directly, for testability.
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

/// Live auth session stream — drives [go_router]'s redirect logic (see
/// `lib/router/app_router.dart`) so login/logout immediately reroutes without
/// any manual navigation call at the login/logout call site.
final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseClientProvider).auth.onAuthStateChange;
});

/// Convenience derived provider: the current user id, or null when signed out.
final currentUserIdProvider = Provider<String?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  // .value covers the synchronous initial read; the stream above is what
  // actually triggers rebuilds/redirects on change.
  ref.watch(authStateProvider);
  return client.auth.currentUser?.id;
});

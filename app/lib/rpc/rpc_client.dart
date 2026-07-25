import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_exception.dart';

/// Calls `supabase.rpc(fnName, params: params)` and re-throws
/// [PostgrestException] as a typed [ApiException] (API.md §0 error format).
/// [decode] converts the raw response into the RPC's documented return type.
Future<T> callRpc<T>(
  SupabaseClient client,
  String fnName, {
  Map<String, dynamic>? params,
  required T Function(dynamic data) decode,
}) async {
  try {
    final data = await client.rpc(fnName, params: params);
    return decode(data);
  } on PostgrestException catch (e) {
    throw ApiException(
      code: ApiErrorCode.fromCode(e.message),
      rawMessage: e.message,
      detail: e.details as String?,
    );
  }
}

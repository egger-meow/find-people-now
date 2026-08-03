/// Guard against integration tests running against a non-local Supabase
/// project. These tests write real, uncleaned-up fixture rows (most visibly
/// `location` rows with names like `MAT測試區<timestamp>` — see the callers'
/// own comments for why each test needs a uniquely-named campus rather than
/// sharing the '光復' fixture). Pointed at a shared staging/prod `.env` by
/// mistake, that leaks directly into the real "去哪個校區？" picker in
/// create_request_screen.dart every real user sees — found while QA-testing
/// ahead of the production push (an unrelated `flutter test` run had already
/// left ~30 such rows in a local dev DB). This is cheap insurance, not a fix
/// for that incident itself.
void assertLocalSupabaseUrl(String supabaseUrl) {
  final isLocal = supabaseUrl.contains('127.0.0.1') || supabaseUrl.contains('localhost');
  if (!isLocal) {
    throw StateError(
      'Refusing to run integration tests against non-local SUPABASE_URL '
      '"$supabaseUrl" — these tests write real, uncleaned-up fixture data '
      '(auth users, match requests, location rows). Point app/.env at a '
      'local `supabase start` instance instead.',
    );
  }
}

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Loads `.env` (see `.env.example` — values come from `supabase status -o env`)
/// and initializes the Supabase client against the local instance.
Future<void> initSupabase() async {
  await dotenv.load();
  await Supabase.initialize(
    url: dotenv.get('SUPABASE_URL'),
    publishableKey: dotenv.get('SUPABASE_ANON_KEY'),
  );
}

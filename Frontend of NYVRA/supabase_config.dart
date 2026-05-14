// supabase_config.dart
// ─────────────────────────────────────────────────────────────
// Single place for all Supabase credentials.
// login_page.dart imports this file.
// ─────────────────────────────────────────────────────────────

class SupabaseConfig {
  // ✅ Your actual credentials — already working in main.dart
  static const String supabaseUrl =
      'https://*****************.supabase.co';

  static const String supabaseAnonKey =
      'ey*************************************************************************************************************************************************************************Cc';

  // Used by Google OAuth redirect — update if you configure OAuth
  static const String oauthRedirectUrl = 'io.supabase.nyvra://login-callback/';

  // Returns true so login_page doesn't block with "configure first" message
  static const bool isConfigured = true;
}

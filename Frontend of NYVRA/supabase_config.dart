// supabase_config.dart
// ─────────────────────────────────────────────────────────────
// Single place for all Supabase credentials.
// login_page.dart imports this file.
// ─────────────────────────────────────────────────────────────

class SupabaseConfig {
  // ✅ Your actual credentials — already working in main.dart
  static const String supabaseUrl =
      'https://yimkwjkoaepxhkeeouoj.supabase.co';

  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlpbWt3amtvYWVweGhrZWVvdW9qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NTg1NDcsImV4cCI6MjA5MzUzNDU0N30.8LHPrW42aHgNJmEysKELRQQCDc9VA2BY7eCA252kHCc';

  // Used by Google OAuth redirect — update if you configure OAuth
  static const String oauthRedirectUrl = 'io.supabase.nyvra://login-callback/';

  // Returns true so login_page doesn't block with "configure first" message
  static const bool isConfigured = true;
}
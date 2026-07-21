/// Build-time environment configuration.
///
/// Pass real values with `--dart-define` (see README):
/// ```
/// flutter run --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///             --dart-define=SUPABASE_ANON_KEY=eyJ...
/// ```
/// The defaults point at a local `supabase start` stack. The default anon key
/// is the public well-known key every local Supabase dev stack uses — it is
/// not a secret.
abstract final class Env {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://127.0.0.1:54321',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwi'
        'cm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.'
        'CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0',
  );
}

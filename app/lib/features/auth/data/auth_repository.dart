import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';

/// Auth flows: email/password plus Google and Facebook OAuth.
///
/// Steam login is deliberately NOT here (roadmap): Steam uses legacy
/// OpenID 2.0, so it will arrive as an edge function that verifies the
/// OpenID assertion and mints a Supabase session — a new method on this
/// repository, no restructuring needed.
class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  Future<void> signInWithEmail(String email, String password) =>
      _client.auth.signInWithPassword(email: email, password: password);

  Future<void> signUpWithEmail(
    String email,
    String password,
    String displayName,
  ) =>
      _client.auth.signUp(
        email: email,
        password: password,
        data: {'display_name': displayName},
      );

  Future<void> signInWithGoogle() => _signInWithOAuth(OAuthProvider.google);

  Future<void> signInWithFacebook() => _signInWithOAuth(OAuthProvider.facebook);

  Future<void> _signInWithOAuth(OAuthProvider provider) =>
      _client.auth.signInWithOAuth(
        provider,
        // Web redirects back to the site; native platforms use the app's
        // deep-link scheme registered in the Supabase dashboard.
        redirectTo: kIsWeb ? null : 'io.supabase.tradinggame://login-callback/',
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );

  Future<void> signOut() => _client.auth.signOut();
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(supabaseProvider)),
);

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The single Supabase client. Repositories depend on this provider rather
/// than the global, which keeps them overridable in tests.
final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

/// Auth state as a stream; `null` session means signed out.
final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

/// Convenience: the current user id, or null when signed out.
final currentUserIdProvider = Provider<String?>((ref) {
  // Re-evaluate on every auth change.
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser?.id;
});

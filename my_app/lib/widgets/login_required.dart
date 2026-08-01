/// Reusable "log in required" helper.
///
/// Any screen that performs an authenticated action can call [requireLogin]
/// to surface the login screen. The returned `Future<bool>` resolves to
/// `true` when the user is signed in (so the caller can continue with the
/// original action) and `false` when they cancelled.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/login_screen.dart';

/// Shows the sign-in screen if the user is not authenticated. Returns
/// `true` once a user is signed in (either they were already signed in or
/// just signed in via the pushed [LoginScreen]); `false` if they went back
/// without signing in.
Future<bool> requireLogin(BuildContext context, {String? action}) async {
  // Capture the navigator eagerly — we may need it after an async gap where
  // the original `context` is no longer safe to read providers from.
  final auth = context.read<AuthProvider>();
  if (auth.isLoggedIn) return true;

  // Friendly subtitle for the user; we keep it short since the login screen
  // has its own header.
  if (action != null) {
    debugPrint('requireLogin: prompt action="$action"');
  }

  final navigator = Navigator.of(context);
  await navigator.push(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
  );

  // After returning from the login screen, the auth state may have changed;
  // re-read from the (still-attached) ancestor provider.
  return auth.isLoggedIn;
}

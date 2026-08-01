/// Root authentication switcher.
///
/// Guests and authenticated users both enter [ShellScreen].
/// Login and registration screens manually return to [ShellScreen]
/// after successful authentication.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'shell_screen.dart';

class AuthWrapper extends StatelessWidget {
  final AuthProvider? authProvider;

  const AuthWrapper({
    super.key,
    this.authProvider,
  });

  @override
  Widget build(BuildContext context) {
    // If an AuthProvider was passed directly to this widget,
    // provide it to LoginScreen, RegisterScreen and ShellScreen.
    if (authProvider != null) {
      return ChangeNotifierProvider<AuthProvider>.value(
        value: authProvider!,
        child: const _AuthContent(),
      );
    }

    // Otherwise, use the AuthProvider already provided in main.dart.
    return const _AuthContent();
  }
}

class _AuthContent extends StatelessWidget {
  const _AuthContent();

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, child) {
        if (auth.isBootstrapping) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // Your app supports guest access, so signed-in users and
        // guests both enter the main ShellScreen.
        return const ShellScreen();
      },
    );
  }
}
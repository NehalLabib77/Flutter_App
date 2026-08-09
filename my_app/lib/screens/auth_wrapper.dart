/// Root authentication switcher.
///
/// Routing rules (newest → oldest, first match wins):
///
///  1. **Bootstrapping** — wait for [AuthProvider] to replay the
///     persisted JWT against `/auth/me`.
///  2. **Valid EduCompass JWT** — open [ShellScreen]. The backend issues
///     this token only after Firebase email verification, so an already
///     logged-in learner is treated as verified.
///  3. **No JWT + unverified Firebase user** — show
///     [EmailVerificationScreen] during the first registration flow.
///  4. **Otherwise** — open the guest [ShellScreen].
///
/// The previous implementation routed everyone straight to
/// [ShellScreen]. We keep the guest-friendly behaviour and only
/// intercept the small slice of users who are mid-verification.
library;

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth, User;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/firebase_auth_service.dart';
import 'email_verification_screen.dart';
import 'shell_screen.dart';

class AuthWrapper extends StatelessWidget {
  final AuthProvider? authProvider;
  final FirebaseAuthService? firebaseAuthService;

  const AuthWrapper({super.key, this.authProvider, this.firebaseAuthService});

  /// Wire the deep-link cold-start reader. Called once from
  /// `main.dart` after `DeepLinkService.start()` has had a chance
  /// to capture the initial URI. When the verification deep link
  /// brings a cold-launched app to the foreground, the gate will
  /// auto-apply the `oobCode` and reload the cached user so the
  /// user lands straight in the shell without having to tap
  /// "I have verified my email".
  static void installColdStartReader(String? Function() reader) {
    _AuthGateState.installColdStartReader(reader);
  }

  @override
  Widget build(BuildContext context) {
    if (authProvider != null) {
      return ChangeNotifierProvider<AuthProvider>.value(
        value: authProvider!,
        child: _AuthContent(firebaseAuthService: firebaseAuthService),
      );
    }
    return _AuthContent(firebaseAuthService: firebaseAuthService);
  }
}

class _AuthContent extends StatelessWidget {
  const _AuthContent({this.firebaseAuthService});

  final FirebaseAuthService? firebaseAuthService;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (auth.isBootstrapping) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // A persisted EduCompass JWT is issued only after the backend has
        // confirmed Firebase email verification. Once that verified session
        // exists, it is the authoritative app-login state. Do not send an
        // already logged-in learner back through the Firebase verification
        // gate because the local Firebase user can briefly be stale after an
        // app restart or token refresh.
        if (auth.isLoggedIn) {
          return const ShellScreen();
        }

        // No EduCompass JWT yet. Keep observing Firebase so a newly
        // registered, unverified user is still routed to the verification
        // screen before their first successful backend login.
        return _AuthGate(firebaseAuthService: firebaseAuthService);
      },
    );
  }
}

/// Observes Firebase's auth-state stream so the verification gate
/// reacts to sign-in / sign-out / refresh events without a manual
/// notify.
class _AuthGate extends StatefulWidget {
  const _AuthGate({this.firebaseAuthService});

  final FirebaseAuthService? firebaseAuthService;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  // userChanges() emits on every Firebase user-property change
  // (including `emailVerified` flipping to true). authStateChanges()
  // only fires on sign-in / sign-out / token refresh, which means
  // tapping "I have verified my email" would leave the gate stuck on
  // the verification screen until the user signs out and back in.
  late final Stream<User?> _authStream;
  FirebaseAuthService? _serviceOverride;

  @override
  void initState() {
    super.initState();
    _serviceOverride = widget.firebaseAuthService;
    _authStream = FirebaseAuth.instance.userChanges();
  }

  Future<void> _applyVerificationCodeIfPresent(
    FirebaseAuthService service,
  ) async {
    // Consume any cold-start verification code. The DeepLinkService
    // is not injected here — AuthWrapper sits above the Provider
    // tree, so we read it through a local fallback: a single global
    // hook on the factory (set up in main.dart). If nothing is
    // wired, this is a no-op and the user falls back to the
    // "I have verified my email" button.
    final code = _consumeInitialVerificationCode?.call();
    if (code == null || code.isEmpty) return;
    try {
      await service.applyVerificationCode(code);
      // applyActionCode updated the flag on Firebase's side; reload
      // the cached user so the next build sees emailVerified == true.
      await service.reloadCurrentUser();
    } on FirebaseAuthFailure catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      // Silent failure — the manual "I have verified my email"
      // button still works as a fallback.
    }
  }

  /// Static hook so `main.dart` can hand the cold-start verification
  /// code to `AuthWrapper` without threading a `DeepLinkService`
  /// instance through the root widget tree. Defaults to `null`
  /// (i.e. no code available).
  static String? Function()? _consumeInitialVerificationCode;

  /// Wire the deep-link cold-start reader. Called once from
  /// `main.dart` after `DeepLinkService.start()` has had a chance
  /// to capture the initial URI.
  static void installColdStartReader(String? Function() reader) {
    _consumeInitialVerificationCode = reader;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user != null && !user.emailVerified) {
          final service =
              _serviceOverride ?? FirebaseAuthServiceFactory.instance;
          // Kick off the cold-start oobCode apply after the first
          // frame so the stream listener has had time to attach.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _applyVerificationCodeIfPresent(service);
          });
          return EmailVerificationScreen(
            email: user.email ?? '',
            service: service,
            onVerified: () {
              // The stream may not emit for several seconds after
              // emailVerified flips; force a rebuild so the gate
              // drops the user straight into the shell as soon as
              // the manual "I have verified my email" tap succeeds.
              if (!mounted) return;
              setState(() {});
            },
            onUseAnotherAccount: () async {
              try {
                await service.signOutCurrent();
              } catch (_) {}
              if (!mounted) return;
              setState(() {});
            },
          );
        }
        return const ShellScreen();
      },
    );
  }
}

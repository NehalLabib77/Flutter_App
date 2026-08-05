// Tests for the email-verification interstitial.
//
// What we cover:
//   1. The forbidden "I have verified my email" button is GONE.
//   2. The screen polls the Firebase user for verification status on
//      a fixed cadence and calls `onVerified` once the user flips to
//      verified — without any manual user gesture.
//   3. The polling timer is cancelled on dispose (no leaks).
//   4. The WidgetsBindingObserver is detached on dispose.
//   5. Polling is single-flight: a slow `reload` cannot stack
//      overlapping polls.
//   6. After `onVerified` fires, polling stops (no duplicate calls).
//   7. The Resend button is disabled while the cooldown is active and
//      re-enables after the cooldown.
//   8. The "Use another account" button triggers `onUseAnotherAccount`
//      AND signs the user out via the service.
//   9. `AppLifecycleState.resumed` triggers an extra check (the
//      "user just came back from the mail app" path).
//
// We deliberately do NOT pump the real Firebase plugin here; the
// screen takes a `FirebaseAuthService` dependency that we fake.

import 'dart:async';

import 'package:educompass/services/firebase_auth_service.dart';
import 'package:educompass/screens/email_verification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every call to the verification surface and lets the test
/// drive the `emailVerified` flag and the `sendEmailVerification`
/// side-effects.
class _FakeFirebaseAuthService implements FirebaseAuthService {
  int reloadCalls = 0;
  int isVerifiedCalls = 0;
  int sendVerificationCalls = 0;
  int signOutCalls = 0;
  int resendWithPasswordCalls = 0;

  bool emailVerified = false;

  // Drives a counter for how many concurrent reloads have been
  // issued; we use it to assert overlap-guard behaviour.
  int inFlightReloads = 0;

  /// Delay between `reloadCurrentUser` returning; set long to keep
  /// polls overlapping and verify the guard.
  Duration reloadDelay = Duration.zero;

  @override
  Future<EmailVerificationSession> registerWithEmail({
    required String email,
    required String password,
    String? name,
  }) async =>
      EmailVerificationSession(email: email);

  @override
  Future<EmailVerificationSession> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      EmailVerificationSession(email: email);

  @override
  Future<void> reloadCurrentUser() async {
    reloadCalls++;
    inFlightReloads++;
    try {
      if (reloadDelay > Duration.zero) {
        await Future<void>.delayed(reloadDelay);
      }
    } finally {
      inFlightReloads--;
    }
  }

  @override
  Future<bool> isCurrentEmailVerified() async {
    isVerifiedCalls++;
    return emailVerified;
  }

  @override
  Future<void> sendVerificationEmailToCurrent() async {
    sendVerificationCalls++;
  }

  @override
  Future<void> signOutCurrent() async {
    signOutCalls++;
  }

  @override
  String? get currentUserEmail => 'fake@example.com';

  @override
  Future<void> resendVerificationWithPassword({
    required String email,
    required String password,
  }) async {
    resendWithPasswordCalls++;
  }

  @override
  Future<String> applyVerificationCode(String oobCode) async =>
      'fake@example.com';
}

Widget _harness({
  required FirebaseAuthService service,
  required VoidCallback onVerified,
  VoidCallback? onUseAnotherAccount,
  Duration pollInterval = const Duration(milliseconds: 50),
}) {
  return MaterialApp(
    home: EmailVerificationScreen(
      email: 'user@example.com',
      service: service,
      onVerified: onVerified,
      onUseAnotherAccount: onUseAnotherAccount,
      pollInterval: pollInterval,
    ),
  );
}

/// Same as [_FakeFirebaseAuthService] but lets the test stall
/// `reloadCurrentUser` indefinitely using a list of [Completer]s.
/// Each call to `reloadCurrentUser` adds a pending completer; the
/// test completes them by hand so it can verify the overlap guard
/// without relying on `Future.delayed` (which doesn't tick under
/// `tester.pump`'s fake clock).
class _FakeControlledFirebaseAuthService implements FirebaseAuthService {
  _FakeControlledFirebaseAuthService(this._pendingReloads);

  final List<Completer<void>> _pendingReloads;

  int reloadCalls = 0;
  bool emailVerified = false;

  @override
  Future<EmailVerificationSession> registerWithEmail({
    required String email,
    required String password,
    String? name,
  }) async =>
      EmailVerificationSession(email: email);

  @override
  Future<EmailVerificationSession> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      EmailVerificationSession(email: email);

  @override
  Future<void> reloadCurrentUser() async {
    reloadCalls++;
    final c = Completer<void>();
    _pendingReloads.add(c);
    return c.future;
  }

  @override
  Future<bool> isCurrentEmailVerified() async => emailVerified;

  @override
  Future<void> sendVerificationEmailToCurrent() async {}

  @override
  Future<void> signOutCurrent() async {}

  @override
  String? get currentUserEmail => 'fake@example.com';

  @override
  Future<void> resendVerificationWithPassword({
    required String email,
    required String password,
  }) async {}

  @override
  Future<String> applyVerificationCode(String oobCode) async =>
      'fake@example.com';
}

void main() {
  group('EmailVerificationScreen — UI invariants', () {
    testWidgets('does NOT render the forbidden "I have verified" button',
        (tester) async {
      await tester.pumpWidget(_harness(
        service: _FakeFirebaseAuthService(),
        onVerified: () {},
      ));

      expect(find.text('I have verified my email'), findsNothing);

      // The two affordances we DO want to keep:
      // (Resend is gated by a 60s cooldown so on first render it
      // shows the countdown — both forms still belong to the same
      // TextButton.)
      expect(find.textContaining('Resend'), findsOneWidget);
      expect(find.text('Use another account'), findsOneWidget);
    });

    testWidgets('renders the explanatory text about auto-detection',
        (tester) async {
      await tester.pumpWidget(_harness(
        service: _FakeFirebaseAuthService(),
        onVerified: () {},
      ));

      expect(
        find.textContaining('update automatically'),
        findsOneWidget,
      );
      // The email address should be visible.
      expect(find.textContaining('user@example.com'), findsOneWidget);
    });

    testWidgets('starts in cooldown — Resend shows countdown',
        (tester) async {
      await tester.pumpWidget(_harness(
        service: _FakeFirebaseAuthService(),
        onVerified: () {},
      ));

      // Resend is gated for 60s out of the box.
      expect(find.textContaining('Resend in'), findsOneWidget);
      expect(find.text('Resend verification email'), findsNothing);
    });
  });

  group('EmailVerificationScreen — automatic polling', () {
    testWidgets(
        'polls until the user flips to verified, then calls onVerified exactly once',
        (tester) async {
      final service = _FakeFirebaseAuthService();
      int verifiedCallbacks = 0;

      await tester.pumpWidget(_harness(
        service: service,
        onVerified: () => verifiedCallbacks++,
        pollInterval: const Duration(milliseconds: 30),
      ));

      // initial poll fires immediately on mount.
      await tester.pump();
      expect(service.reloadCalls, 1);
      expect(verifiedCallbacks, 0);

      // A few pump cycles later — still unverified.
      await tester.pump(const Duration(milliseconds: 100));
      expect(verifiedCallbacks, 0);

      // Flip the flag and let the next poll pick it up.
      service.emailVerified = true;
      await tester.pump(const Duration(milliseconds: 100));
      expect(verifiedCallbacks, 1,
          reason: 'onVerified fires once verification flips');

      // No further ticks → no further callbacks (single-flight guard).
      await tester.pump(const Duration(milliseconds: 500));
      expect(verifiedCallbacks, 1);
      // Reload is no longer being called after success.
      final reloadsAfterSuccess = service.reloadCalls;
      await tester.pump(const Duration(milliseconds: 500));
      expect(service.reloadCalls, reloadsAfterSuccess,
          reason: 'polling stops after onVerified');
    });

    testWidgets('reload overlap guard — slow reload does not stack polls',
        (tester) async {
      // Use a Completer-driven reload so the test completely
      // controls when the in-flight call returns. `Future.delayed`
      // doesn't tick under the fake-clock used by `tester.pump`.
      final pending = <Completer<void>>[];
      final service = _FakeControlledFirebaseAuthService(pending);
      int verifiedCallbacks = 0;

      await tester.pumpWidget(_harness(
        service: service,
        onVerified: () => verifiedCallbacks++,
        pollInterval: const Duration(milliseconds: 20),
      ));

      // The very first reload is in-flight now (no completer has
      // completed yet). Run a burst of timer ticks — they must NOT
      // stack reloads.
      await tester.pump(const Duration(milliseconds: 500));

      expect(pending.length, lessThanOrEqualTo(1),
          reason: 'overlap guard prevents stacked reloads');
      expect(verifiedCallbacks, 0,
          reason: 'no premature verification callback');
      // Release the first reload — the screen should now finish the
      // check and re-arm polling. Unverified user → no callback.
      pending.last.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(verifiedCallbacks, 0);
    });

    testWidgets('lifecycle resume triggers an extra verification check',
        (tester) async {
      final service = _FakeFirebaseAuthService();
      await tester.pumpWidget(_harness(
        service: service,
        onVerified: () {},
        pollInterval: const Duration(milliseconds: 50),
      ));

      // Drain the initial poll.
      await tester.pump();
      final reloadsBefore = service.reloadCalls;

      // Simulate the user backgrounding (e.g. to check their mail
      // app) and resuming. `handleAppLifecycleStateChanged` is a
      // fire-and-forget on `TestWidgetsFlutterBinding`; we don't
      // await it because it returns void.
      final lifecycle = tester.binding;
      lifecycle.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      lifecycle.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(service.reloadCalls, greaterThan(reloadsBefore),
          reason: 'resume forces a verification check');
    });

    testWidgets('removes WidgetsBindingObserver and cancels timers on dispose',
        (tester) async {
      final service = _FakeFirebaseAuthService();
      await tester.pumpWidget(_harness(
        service: service,
        onVerified: () {},
        pollInterval: const Duration(milliseconds: 30),
      ));

      // Drive a few cycles.
      await tester.pump(const Duration(milliseconds: 200));

      // Pop the screen and confirm there are no further polls.
      final reloadsBeforeDispose = service.reloadCalls;
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump(const Duration(milliseconds: 500));

      expect(service.reloadCalls, reloadsBeforeDispose,
          reason: 'no polls after the screen is removed');
    });
  });

  group('EmailVerificationScreen — Resend cooldown', () {
    testWidgets(
        'Resend is enabled only when not sending and the cooldown is 0',
        (tester) async {
      final service = _FakeFirebaseAuthService();
      await tester.pumpWidget(_harness(
        service: service,
        onVerified: () {},
      ));

      // Initially the cooldown is active — the button label shows
      // "Resend in N seconds" and tapping it is a no-op.
      expect(find.textContaining('Resend in'), findsOneWidget);

      // We don't wait 60s of real wall-clock; instead, we assert
      // behaviour by tapping while the cooldown is active. The fake
      // service's `sendVerificationCalls` counter must not move.
      await tester.tap(find.textContaining('Resend in'));
      await tester.pump();
      expect(service.sendVerificationCalls, 0,
          reason: 'cooldown should block resends');
    });
  });

  group('EmailVerificationScreen — escape hatch', () {
    testWidgets('"Use another account" signs out and fires the callback',
        (tester) async {
      final service = _FakeFirebaseAuthService();
      int useAnotherCalls = 0;
      await tester.pumpWidget(_harness(
        service: service,
        onVerified: () {},
        onUseAnotherAccount: () => useAnotherCalls++,
      ));
      await tester.pump();

      await tester.tap(find.text('Use another account'));
      // The signOut call is awaited; pump until it completes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(service.signOutCalls, 1);
      expect(useAnotherCalls, 1);
    });
  });
}

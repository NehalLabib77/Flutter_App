// Source-level invariants for the auth routing flow.
//
// These tests verify the *contract* of the auth flow by reading the
// source code of the production files. They protect against
// regressions where a future change re-introduces:
//
//   1. `await _auth.signOut()` inside `registerWithEmail` after the
//      verification email has been sent. That call previously
//      caused the AuthWrapper's `userChanges` stream to emit `null`,
//      route the user to the shell, and never show the verification
//      screen. The fix keeps the user signed in so the stream emits
//      the unverified user and the wrapper handles the route swap.
//   2. A `pushAndRemoveUntil(EmailVerificationScreen(...))` call from
//      inside `LoginScreen._submit` or `RegisterScreen._submit`. Both
//      must let AuthWrapper's `userChanges` stream do the routing
//      instead of pushing the screen directly (which would race with
//      the StreamBuilder tick and produce a double-navigation).
//   3. A "I have verified my email" button in
//      `EmailVerificationScreen` — the user has explicitly forbidden
//      that affordance. The screen must auto-detect verification by
//      polling the Firebase user.
//
// These aren't behavioural tests — they don't pump widgets — but they
// are still unit tests: they assert a property of the source. A
// behavioural test would require mocking the entire
// `package:firebase_auth` surface, which is out of scope.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('firebase_auth_service — register flow invariants', () {
    test('registerWithEmail does NOT sign the user out after sending '
        'the verification email', () async {
      final source = await File(
        'lib/services/firebase_auth_service.dart',
      ).readAsString();

      // Locate the concrete implementation in `_DefaultFirebaseAuthService`
      // — the abstract declaration in `FirebaseAuthService` has no body.
      const signature =
          'Future<EmailVerificationSession> registerWithEmail({';
      final regOpen = source.indexOf(signature);
      expect(regOpen, isNonNegative,
          reason: 'abstract registerWithEmail should exist');
      // The abstract declaration ends at the next `;`. Find the
      // concrete declaration after it.
      final concreteOpen = source.indexOf(signature, regOpen + signature.length);
      expect(concreteOpen, isNonNegative,
          reason: 'concrete registerWithEmail should exist');

      // Find the next method definition — `signInWithEmail` — and
      // confine the search to the body of registerWithEmail.
      final regClose = source.indexOf(
        'Future<EmailVerificationSession> signInWithEmail(',
        concreteOpen,
      );
      expect(regClose, isNonNegative);

      final body = source.substring(concreteOpen, regClose);

      // The sendEmailVerification call must still happen.
      expect(body, contains('sendEmailVerification'),
          reason: 'verification email must still be sent');

      // The bug we are guarding against: signing out after the
      // email is sent, which would invalidate the auth-state stream
      // that AuthWrapper relies on.
      expect(body, isNot(contains('await _auth.signOut()')),
          reason:
              'registerWithEmail must NOT sign the user out — '
              'AuthWrapper routes the unverified user to the '
              'verification screen via userChanges');
    });
  });

  group('Auth screens — no manual EmailVerificationScreen.push', () {
    bool hasForbiddenPush(String source) {
      // The forbidden pattern is a `pushAndRemoveUntil` followed by
      // an `EmailVerificationScreen(...)` constructor — anywhere in
      // the file. The two must appear within a 400-char window so
      // unrelated occurrences (e.g. just a doc comment) don't match.
      final idx = source.indexOf('pushAndRemoveUntil');
      if (idx < 0) return false;
      final tail = source.substring(idx, idx + 600);
      return tail.contains('EmailVerificationScreen');
    }

    test('LoginScreen._submit does not manually push '
        'EmailVerificationScreen', () async {
      final source = await File('lib/screens/login_screen.dart').readAsString();

      expect(hasForbiddenPush(source), isFalse,
          reason:
              'LoginScreen must NOT push EmailVerificationScreen — '
              'AuthWrapper handles the route swap via userChanges');
    });

    test('RegisterScreen._submit does not manually push '
        'EmailVerificationScreen', () async {
      final source =
          await File('lib/screens/register_screen.dart').readAsString();

      expect(hasForbiddenPush(source), isFalse,
          reason:
              'RegisterScreen must NOT push EmailVerificationScreen — '
              'AuthWrapper handles the route swap via userChanges');
    });
  });

  group('EmailVerificationScreen — auto-detection contract', () {
    test('does not render a manual "I have verified" button', () async {
      final source = await File(
        'lib/screens/email_verification_screen.dart',
      ).readAsString();

      expect(
        source,
        isNot(contains("Text('I have verified my email')")),
        reason:
            'The user has explicitly forbidden a manual "I have '
            'verified" button — the screen auto-detects via polling',
      );

      // The screen must still expose a polling timer.
      expect(source, contains('Timer.periodic'),
          reason: 'EmailVerificationScreen must poll for verification');
      expect(source, contains('WidgetsBindingObserver'),
          reason: 'EmailVerificationScreen must observe the '
              'lifecycle to re-check on resume');
      expect(source, contains('AppLifecycleState.resumed'),
          reason: 'Resume hook must trigger an extra verification check');
    });
  });
}

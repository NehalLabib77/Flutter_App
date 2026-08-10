
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Reasons a Firebase operation can fail. Mirrors the Firebase error
/// codes the app cares about and collapses the rest into [other].
enum FirebaseAuthFailureKind {
  emailAlreadyInUse,
  invalidEmail,
  weakPassword,
  userNotFound,
  wrongPassword,
  invalidCredential,
  userDisabled,
  tooManyRequests,
  emailNotVerified,
  network,
  notSignedIn,
  alreadyVerified,
  other,
}

/// User-presentable error from the Firebase auth wrapper.
class FirebaseAuthFailure implements Exception {
  FirebaseAuthFailure(this.kind, this.message);

  final FirebaseAuthFailureKind kind;
  final String message;

  @override
  String toString() => 'FirebaseAuthFailure($kind): $message';
}

/// Public surface used by the auth screens. The methods on the
/// concrete [_DefaultFirebaseAuthService] match this contract; the
/// tests substitute [FakeFirebaseAuthService] which records calls.
abstract class FirebaseAuthService {
  Future<EmailVerificationSession> registerWithEmail({
    required String email,
    required String password,
    String? name,
  });

  Future<EmailVerificationSession> signInWithEmail({
    required String email,
    required String password,
  });

  Future<void> reloadCurrentUser();

  Future<bool> isCurrentEmailVerified();

  Future<void> sendVerificationEmailToCurrent();

  Future<void> signOutCurrent();

  String? get currentUserEmail;

  /// Resend the verification email using the user's email + password.
  /// Used by the "Resend" button on the Login screen when the user
  /// forgot to verify before signing out.
  Future<void> resendVerificationWithPassword({
    required String email,
    required String password,
  });

  /// Consume the `oobCode` from a verification email. Returns the
  /// email address associated with the code so the caller can route
  /// the user back to the right verification screen.
  Future<String> applyVerificationCode(String oobCode);

  /// Extract `oobCode` from a verification-email deep link URI.
  /// Returns `null` if the URI doesn't look like one of ours.
  static String? extractVerificationCode(Uri uri) {
    if (uri.scheme.toLowerCase() != 'educompass') return null;
    if (uri.host.toLowerCase() != 'verify-email') return null;
    return uri.queryParameters['oobCode'];
  }
}

/// Result of register / sign-in. Carries the email so the verification
/// screen can show "We sent a link to `${email}`" without re-querying
/// Firebase.
class EmailVerificationSession {
  const EmailVerificationSession({required this.email});

  final String email;
}

class _DefaultFirebaseAuthService implements FirebaseAuthService {
  final FirebaseAuth _auth;

  _DefaultFirebaseAuthService([FirebaseAuth? auth])
    : _auth = auth ?? FirebaseAuth.instance;

  @override
  String? get currentUserEmail => _auth.currentUser?.email;

  @override
  Future<EmailVerificationSession> registerWithEmail({
    required String email,
    required String password,
    String? name,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw FirebaseAuthFailure(
          FirebaseAuthFailureKind.other,
          'Unable to create the user account.',
        );
      }
      if (name != null && name.trim().isNotEmpty) {
        try {
          await user.updateDisplayName(name.trim());
        } on FirebaseAuthException catch (e) {
          debugPrint('updateDisplayName failed: ${e.message}');
        }
      }
      // Send the verification email *and keep the user signed in* so
      // the AuthWrapper's `userChanges` stream emits the unverified
      // user and routes straight to EmailVerificationScreen. The link
      // is valid whether or not the local Firebase session is alive.
      await user.sendEmailVerification();
      return EmailVerificationSession(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw _mapFirebaseError(e);
    } catch (e) {
      throw FirebaseAuthFailure(FirebaseAuthFailureKind.other, e.toString());
    }
  }

  @override
  Future<EmailVerificationSession> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        await _auth.signOut();
        throw FirebaseAuthFailure(
          FirebaseAuthFailureKind.userNotFound,
          'Unable to find the user account.',
        );
      }
      // Refresh the cached user so the latest emailVerified flag
      // arrives from Firebase's servers.
      await user.reload();
      final refreshed = _auth.currentUser;
      if (refreshed == null || !refreshed.emailVerified) {
        // Keep the session — AuthWrapper will show the verification
        // screen. The wrapper signs the user out only when they
        // explicitly tap "Use another account".
        throw FirebaseAuthFailure(
          FirebaseAuthFailureKind.emailNotVerified,
          'Please verify your email before signing in.',
        );
      }
      return EmailVerificationSession(email: refreshed.email ?? email.trim());
    } on FirebaseAuthException catch (e) {
      throw _mapFirebaseError(e);
    } catch (e) {
      if (e is FirebaseAuthFailure) rethrow;
      throw FirebaseAuthFailure(FirebaseAuthFailureKind.other, e.toString());
    }
  }

  @override
  Future<void> reloadCurrentUser() async {
    await _auth.currentUser?.reload();
  }

  @override
  Future<bool> isCurrentEmailVerified() async {
    return _auth.currentUser?.emailVerified ?? false;
  }

  @override
  Future<void> sendVerificationEmailToCurrent() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthFailure(
        FirebaseAuthFailureKind.notSignedIn,
        'Please sign in again.',
      );
    }
    if (user.emailVerified) {
      throw FirebaseAuthFailure(
        FirebaseAuthFailureKind.alreadyVerified,
        'This email is already verified.',
      );
    }
    try {
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (e) {
      throw _mapFirebaseError(e);
    }
  }

  @override
  Future<void> signOutCurrent() async {
    await _auth.signOut();
  }

  @override
  Future<void> resendVerificationWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        await _auth.signOut();
        throw FirebaseAuthFailure(
          FirebaseAuthFailureKind.userNotFound,
          'User account not found.',
        );
      }
      await user.reload();
      final refreshed = _auth.currentUser;
      if (refreshed?.emailVerified == true) {
        await _auth.signOut();
        throw FirebaseAuthFailure(
          FirebaseAuthFailureKind.alreadyVerified,
          'This email is already verified.',
        );
      }
      await refreshed?.sendEmailVerification();
      // Sign out so the AuthWrapper sees a logged-out state and
      // routes the user to the login screen.
      await _auth.signOut();
    } on FirebaseAuthException catch (e) {
      throw _mapFirebaseError(e);
    }
  }

  @override
  Future<String> applyVerificationCode(String oobCode) async {
    try {
      await _auth.applyActionCode(oobCode);
      // applyActionCode updates the flag on Firebase's side but the
      // cached current user still reports the old value until we
      // reload. The caller (AuthWrapper) immediately calls
      // isCurrentEmailVerified, which calls currentUser.emailVerified,
      // so we trigger a reload here to make the next read accurate.
      await _auth.currentUser?.reload();
      return _auth.currentUser?.email ?? '';
    } on FirebaseAuthException catch (e) {
      throw _mapFirebaseError(e);
    } catch (e) {
      throw FirebaseAuthFailure(FirebaseAuthFailureKind.other, e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Error mapping
  // ---------------------------------------------------------------------------

  FirebaseAuthFailure _mapFirebaseError(FirebaseAuthException e) {
    final kind = _kindFor(e.code);
    return FirebaseAuthFailure(kind, _messageFor(kind, e));
  }

  FirebaseAuthFailureKind _kindFor(String code) {
    switch (code) {
      case 'email-already-in-use':
        return FirebaseAuthFailureKind.emailAlreadyInUse;
      case 'invalid-email':
        return FirebaseAuthFailureKind.invalidEmail;
      case 'weak-password':
        return FirebaseAuthFailureKind.weakPassword;
      case 'user-not-found':
      case 'user-not-found ':
        return FirebaseAuthFailureKind.userNotFound;
      case 'wrong-password':
        return FirebaseAuthFailureKind.wrongPassword;
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return FirebaseAuthFailureKind.invalidCredential;
      case 'user-disabled':
        return FirebaseAuthFailureKind.userDisabled;
      case 'too-many-requests':
        return FirebaseAuthFailureKind.tooManyRequests;
      case 'network-request-failed':
        return FirebaseAuthFailureKind.network;
      default:
        return FirebaseAuthFailureKind.other;
    }
  }

  String _messageFor(FirebaseAuthFailureKind kind, FirebaseAuthException e) {
    final raw = (e.message ?? '').trim();
    switch (kind) {
      case FirebaseAuthFailureKind.emailAlreadyInUse:
        return raw.isNotEmpty
            ? raw
            : 'An account already exists for this email.';
      case FirebaseAuthFailureKind.invalidEmail:
        return 'Please enter a valid email address.';
      case FirebaseAuthFailureKind.weakPassword:
        return 'Password must be at least 8 characters.';
      case FirebaseAuthFailureKind.userNotFound:
        return 'No account was found with this email.';
      case FirebaseAuthFailureKind.wrongPassword:
      case FirebaseAuthFailureKind.invalidCredential:
        return 'Incorrect email or password.';
      case FirebaseAuthFailureKind.userDisabled:
        return 'This account has been disabled.';
      case FirebaseAuthFailureKind.tooManyRequests:
        return 'Too many attempts. Try again in a few minutes.';
      case FirebaseAuthFailureKind.network:
        return 'Network error. Please check your connection.';
      case FirebaseAuthFailureKind.other:
        return raw.isNotEmpty ? raw : 'Authentication failed.';
      default:
        return raw.isNotEmpty ? raw : 'Authentication failed.';
    }
  }
}

/// Singleton accessor — keeps testability simple. Tests can swap the
/// instance via [FirebaseAuthService.overrideForTest].
class FirebaseAuthServiceFactory {
  static FirebaseAuthService _instance = _DefaultFirebaseAuthService();

  static FirebaseAuthService get instance => _instance;

  static void overrideForTest(FirebaseAuthService service) {
    _instance = service;
  }

  static void resetForTest() {
    _instance = _DefaultFirebaseAuthService();
  }
}

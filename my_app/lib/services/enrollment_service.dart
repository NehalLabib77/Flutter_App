/// Firestore-backed enrollment store.
///
/// Documents live at `users/{uid}/enrollments/{courseId}` with fields
///   courseId, paymentMethod, transactionId, paymentStatus, enrolledAt
/// so a logged-in user can pick up where they left off on a second
/// device without re-paying.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

class EnrollmentService {
  final FirebaseFirestore? _db;
  final FirebaseAuth? _auth;

  /// Firestore collection that holds every enrollment record.
  static const String enrollmentsCollection = 'enrollments';

  EnrollmentService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _db = firestore,
        _auth = auth;

  // Lazy resolvers — touching `FirebaseFirestore.instance` /
  // `FirebaseAuth.instance` during construction throws `[core/no-app]`
  // if `Firebase.initializeApp` hasn't completed yet. By deferring we
  // let the service construct anywhere and surface real errors only at
  // call time.
  FirebaseFirestore get _resolvedDb {
    final db = _db ?? FirebaseFirestore.instance;
    if (_db == null && Firebase.apps.isEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'no-app',
        message:
            'Firebase has not been initialized. Call Firebase.initializeApp() '
            'before using EnrollmentService.',
      );
    }
    return db;
  }

  FirebaseAuth get _resolvedAuth {
    final a = _auth ?? FirebaseAuth.instance;
    if (_auth == null && Firebase.apps.isEmpty) {
      throw FirebaseException(
        plugin: 'firebase_auth',
        code: 'no-app',
        message:
            'Firebase has not been initialized. Call Firebase.initializeApp() '
            'before using EnrollmentService.',
      );
    }
    return a;
  }

  /// Throws if the user is not signed in. The caller should have gated
  /// this with `requireLogin(...)` already.
  User _requireUser() {
    final user = _resolvedAuth.currentUser;
    if (user == null) {
      throw StateError('You must be signed in to manage enrollments.');
    }
    return user;
  }

  DocumentReference<Map<String, dynamic>> _doc(String uid, String courseId) {
    return _resolvedDb
        .collection('users')
        .doc(uid)
        .collection(enrollmentsCollection)
        .doc(courseId);
  }

  /// Returns `true` if the current user already has a Firestore record
  /// for [courseId]. Network / auth errors propagate to the caller.
  Future<bool> isEnrolled(String courseId) async {
    final user = _requireUser();
    final snap = await _doc(user.uid, courseId).get();
    return snap.exists;
  }

  /// Writes `users/{uid}/enrollments/{courseId}` with
  /// `{courseId, paymentMethod, transactionId, paymentStatus, enrolledAt}`.
  /// Idempotent: re-enrolling just overwrites the same fields.
  Future<void> saveEnrollment({
    required String courseId,
    required String paymentMethod,
    required String transactionId,
  }) async {
    final user = _requireUser();
    await _doc(user.uid, courseId).set({
      'courseId': courseId,
      'paymentMethod': paymentMethod,
      'transactionId': transactionId,
      'paymentStatus': 'completed',
      'enrolledAt': FieldValue.serverTimestamp(),
    });
  }

  /// Removes the `users/{uid}/enrollments/{courseId}` doc so the
  /// enrollment is gone on every device that syncs from this user.
  /// Throws if the user is not signed in; a missing doc is treated as
  /// success (no-op) so the UI doesn't need to special-case it.
  Future<void> deleteEnrollment(String courseId) async {
    final user = _requireUser();
    await _doc(user.uid, courseId).delete();
  }

  /// Live list of course ids the current user is enrolled in, newest
  /// first. Returns an empty stream if the user is signed out.
  Stream<List<String>> myEnrolledCourseIds() {
    final FirebaseAuth authInstance;
    final FirebaseFirestore dbInstance;
    try {
      authInstance = _resolvedAuth;
      dbInstance = _resolvedDb;
    } on FirebaseException {
      return const Stream.empty();
    }
    final uid = authInstance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return dbInstance
        .collection('users')
        .doc(uid)
        .collection(enrollmentsCollection)
        .orderBy('enrolledAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.id).toList());
  }
}

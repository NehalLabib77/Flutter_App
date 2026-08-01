import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app.dart';
import 'app_state.dart';
import 'firebase_options.dart';

Future<void> main() async {
  // Required before any plugin (Firebase / shared_preferences) call.
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase so MockPaymentService can reach FirebaseFirestore
  // and FirebaseAuth when a course is selected. Must happen before runApp.
  //
  // Wrapped in a try/catch so the app still boots if Firebase has not been
  // configured for this build (e.g. placeholder API keys in
  // firebase_options.dart). `Firebase.apps.isEmpty` is then false once we
  // exit, and `MockPaymentService` will report a clear error per call
  // instead of crashing the whole UI tree on first provider creation.
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e, st) {
    debugPrint('Firebase.initializeApp failed: $e\n$st');
  }

  // Build the API client, prefs, and the auth state holder up-front so
  // the splash is the instant Flutter can render the first frame.
  final api = ApiClient();
  final prefs = await SharedPreferences.getInstance();
  final auth = AuthProvider(api);
  // Replay the persisted JWT against `/auth/me` and clear the bootstrap
  // flag so AuthWrapper can pick the right screen on the first build.
  await auth.bootstrap();

  runApp(EduCompassApp(api: api, auth: auth, prefs: prefs));
}

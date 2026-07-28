import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app.dart';
import 'app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final api = ApiClient();
  final auth = AuthProvider(api);
  // Restore token + user before first frame so the splash gate sees the truth.
  await auth.bootstrap();
  runApp(EduCompassApp(api: api, auth: auth, prefs: prefs));
}

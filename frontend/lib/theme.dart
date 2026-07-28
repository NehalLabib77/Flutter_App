/// Material 3 theme for EduCompass.
///
/// `themeProvider` switches between [lightTheme] and [darkTheme].
library;

import 'package:flutter/material.dart';

class AppColors {
  static const Color seed = Color(0xFF1F6FEB);
}

ThemeData _base(ColorScheme scheme) => ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.symmetric(vertical: 6, horizontal: 0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      chipTheme: const ChipThemeData(
        side: BorderSide.none,
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
    );

final ThemeData lightTheme = _base(
  ColorScheme.fromSeed(seedColor: AppColors.seed, brightness: Brightness.light),
);

final ThemeData darkTheme = _base(
  ColorScheme.fromSeed(seedColor: AppColors.seed, brightness: Brightness.dark),
);
/// Material 3 theme for EduCompass.
///
/// All UI tokens (colors, spacing, radii) live here so every screen
/// shares the same vocabulary. `themeProvider` switches between
/// [lightTheme] and [darkTheme].
library;

import 'package:flutter/material.dart';

/// Professional education-app palette.
///
/// Tokens follow a single navy-blue accent so the app reads as a
/// consistent product across screens (Home, Course Details, Auth, etc.)
/// rather than letting Material's seed-color generator pick the hues.
class AppColors {
  const AppColors._();

  // --- Brand ---------------------------------------------------------------
  /// Primary navy — buttons, AppBar, selected nav item, primary icons.
  static const Color navy = Color(0xFF173F7A);

  /// Slightly lighter navy used in the AppBar gradient on the auth
  /// pages and the guest profile card so they read as a hero surface
  /// without veering away from the brand.
  static const Color navyDeep = Color(0xFF0F2B5C);

  /// Secondary blue — links, secondary actions, accent gradients.
  static const Color blue = Color(0xFF4F6DA8);

  /// Light blue background — selected nav indicator, banner fills.
  static const Color lightBlue = Color(0xFFEEF3FF);

  // --- Surfaces ------------------------------------------------------------
  /// Default page background (light mode).
  static const Color pageBg = Color(0xFFF6F8FC);

  /// Card / elevated surface background (light mode).
  static const Color cardBg = Color(0xFFFFFFFF);

  /// 1px hairline border.
  static const Color border = Color(0xFFE2E6EF);

  // --- Text ----------------------------------------------------------------
  /// Primary headings / body copy.
  static const Color textPrimary = Color(0xFF171A22);

  /// Secondary copy — subtitles, captions, metadata.
  static const Color textSecondary = Color(0xFF626878);

  // --- Status --------------------------------------------------------------
  /// Success green — "Enrolled", "FREE", check icons.
  static const Color success = Color(0xFF2E9E5B);

  // --- Auth screen accents -------------------------------------------------
  /// Used by the editorial Auth chrome (kept in sync with brand navy).
  static const Color seed = navy;
}

// ---------------------------------------------------------------------------
// Layout primitives (kept in one place so all screens stay aligned)
// ---------------------------------------------------------------------------

/// Spacing scale (logical pixels). The whole app follows 4 / 8 / 12 / 16 /
/// 24 / 32.
class AppSpacing {
  const AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Standard horizontal screen padding used on every page.
  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: lg);
}

/// Corner-radius scale.
class AppRadii {
  const AppRadii._();
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;

  /// Small pill — chips, status badges.
  static const BorderRadius pillRadius =
      BorderRadius.all(Radius.circular(pill));

  /// Standard card radius.
  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(lg));
}

// ---------------------------------------------------------------------------
// Theme builders
// ---------------------------------------------------------------------------

ThemeData _base({
  required ColorScheme scheme,
  required bool isDark,
}) {
  // The brand is intentionally navy in BOTH themes — every screenshot
  // shows the navy header regardless of mode. This keeps "brand"
  // recognisable and matches the user's expected look.
  final brand = AppColors.navy;
  final surface = isDark ? const Color(0xFF0E1426) : AppColors.pageBg;
  final cardSurface =
      isDark ? const Color(0xFF18203A) : AppColors.cardBg;
  final onSurface = isDark ? Colors.white : AppColors.textPrimary;
  final secondaryText =
      isDark ? const Color(0xFFB3BAD0) : AppColors.textSecondary;
  final inputFill =
      isDark ? const Color(0xFF1B2440) : Colors.white;
  final inputBorder = isDark
      ? const Color(0xFF2A3554)
      : AppColors.border;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(
      primary: brand,
      onPrimary: Colors.white,
      secondary: AppColors.blue,
      surface: surface,
      onSurface: onSurface,
      surfaceContainerHigh: cardSurface,
      surfaceContainerHighest:
          isDark ? const Color(0xFF222B4A) : Colors.white,
      surfaceContainer: cardSurface,
      surfaceContainerLow:
          isDark ? const Color(0xFF131A2E) : const Color(0xFFEEF1F8),
      outlineVariant: inputBorder,
    ),
    scaffoldBackgroundColor: surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    // AppBar uses the brand navy with white foreground; AppBarTheme
    // controls every MaterialApp route's top bar. We keep it navy in
    // both themes so the brand identity is consistent.
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.navy,
      foregroundColor: Colors.white,
      iconTheme: IconThemeData(color: Colors.white),
      actionsIconTheme: IconThemeData(color: Colors.white),
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      systemOverlayStyle: null,
      shape: Border(),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
      color: cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadii.lg)),
      ),
    ),
    chipTheme: const ChipThemeData(
      side: BorderSide.none,
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    dividerTheme: DividerThemeData(
      color: inputBorder.withValues(alpha: 0.6),
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brand,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.pillRadius,
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          letterSpacing: 0.2,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        foregroundColor: onSurface,
        side: BorderSide(color: inputBorder, width: 1),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.pillRadius,
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brand,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      hintStyle: TextStyle(
        color: secondaryText,
        fontWeight: FontWeight.w500,
      ),
      labelStyle: TextStyle(color: secondaryText),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: brand, width: 1.5),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: brand,
      linearTrackColor: inputBorder,
      circularTrackColor: inputBorder,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isDark ? const Color(0xFF0E1426) : Colors.white,
      indicatorColor: isDark
          ? const Color(0xFF1F3A78)
          : AppColors.lightBlue,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? brand : secondaryText,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? brand : secondaryText,
          size: 24,
        );
      }),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: isDark
            ? const Color(0xFF18203A)
            : Colors.white,
        foregroundColor: secondaryText,
        selectedBackgroundColor:
            isDark ? const Color(0xFF1F3A78) : AppColors.lightBlue,
        selectedForegroundColor: brand,
        side: BorderSide(color: inputBorder, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor:
          isDark ? const Color(0xFF222B4A) : const Color(0xFF1B1F2C),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cardSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: onSurface, fontSize: 15, height: 1.4),
      bodyMedium:
          TextStyle(color: onSurface, fontSize: 14, height: 1.4),
      bodySmall: TextStyle(
        color: secondaryText,
        fontSize: 12.5,
        height: 1.4,
      ),
      titleLarge: TextStyle(
        color: onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
      titleMedium: TextStyle(
        color: onSurface,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      titleSmall: TextStyle(
        color: onSurface,
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      labelLarge:
          TextStyle(color: onSurface, fontWeight: FontWeight.w700),
      labelMedium:
          TextStyle(color: secondaryText, fontWeight: FontWeight.w600),
      labelSmall:
          TextStyle(color: secondaryText, fontWeight: FontWeight.w600),
    ),
    splashFactory: InkRipple.splashFactory,
  );
}

final ThemeData lightTheme = _base(
  scheme: ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.light,
  ),
  isDark: false,
);

final ThemeData darkTheme = _base(
  scheme: ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.dark,
  ),
  isDark: true,
);

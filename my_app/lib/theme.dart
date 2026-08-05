/// Material 3 theme for EduCompass.
///
/// All visual tokens live here so every screen shares the same spacing,
/// radii, surfaces and contrast rules. Theme state remains owned by the
/// existing ThemeProvider; this file only defines presentation.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppColors {
  const AppColors._();

  // Brand
  static const Color navy = Color(0xFF1D4B87);
  static const Color navyDeep = Color(0xFF123567);
  static const Color blue = Color(0xFF5579B9);
  static const Color blueBright = Color(0xFF79A4F5);
  static const Color lightBlue = Color(0xFFE7EEF9);

  // Light surfaces
  static const Color pageBg = Color(0xFFF5F7FC);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE2E7F0);

  // Dark surfaces — intentionally navy/slate rather than pure black.
  static const Color darkPage = Color(0xFF0E1426);
  static const Color darkCard = Color(0xFF1B243F);
  static const Color darkCardRaised = Color(0xFF222D4C);
  static const Color darkBorder = Color(0xFF33405F);

  // Text
  static const Color textPrimary = Color(0xFF151923);
  static const Color textSecondary = Color(0xFF626A7B);
  static const Color darkTextPrimary = Color(0xFFF4F6FB);
  static const Color darkTextSecondary = Color(0xFFB7BED2);

  // Status
  static const Color success = Color(0xFF2E9E67);
  static const Color warning = Color(0xFFD69531);
  static const Color danger = Color(0xFFD95C66);

  static const Color seed = navy;
}

class AppSpacing {
  const AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: lg);
}

class AppRadii {
  const AppRadii._();
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 24;
  static const double pill = 999;
  static const BorderRadius pillRadius =
      BorderRadius.all(Radius.circular(pill));
  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(lg));
}

ThemeData _base({
  required ColorScheme seedScheme,
  required bool isDark,
}) {
  final primary = isDark ? AppColors.blueBright : AppColors.navy;
  final page = isDark ? AppColors.darkPage : AppColors.pageBg;
  final card = isDark ? AppColors.darkCard : AppColors.cardBg;
  final raised = isDark ? AppColors.darkCardRaised : Colors.white;
  final onSurface =
      isDark ? AppColors.darkTextPrimary : AppColors.textPrimary;
  final secondary =
      isDark ? AppColors.darkTextSecondary : AppColors.textSecondary;
  final outline = isDark ? AppColors.darkBorder : AppColors.border;
  final input = isDark ? const Color(0xFF202A47) : Colors.white;

  final scheme = seedScheme.copyWith(
    primary: primary,
    onPrimary: isDark ? const Color(0xFF0A1830) : Colors.white,
    primaryContainer:
        isDark ? const Color(0xFF203D72) : AppColors.lightBlue,
    onPrimaryContainer:
        isDark ? AppColors.darkTextPrimary : AppColors.navyDeep,
    secondary: isDark ? const Color(0xFF9CB9F0) : AppColors.blue,
    surface: page,
    onSurface: onSurface,
    onSurfaceVariant: secondary,
    surfaceContainerLowest: page,
    surfaceContainerLow:
        isDark ? const Color(0xFF141B30) : const Color(0xFFF0F3F9),
    surfaceContainer: card,
    surfaceContainerHigh: card,
    surfaceContainerHighest: raised,
    outline: outline,
    outlineVariant: outline,
    error: isDark ? const Color(0xFFFFB3B8) : AppColors.danger,
    errorContainer:
        isDark ? const Color(0xFF51252D) : const Color(0xFFFFE8EA),
    onErrorContainer:
        isDark ? const Color(0xFFFFDADB) : const Color(0xFF7A1B26),
  );

  final overlay = isDark
      ? SystemUiOverlayStyle.light.copyWith(
          statusBarColor: AppColors.navy,
          systemNavigationBarColor: AppColors.darkPage,
          systemNavigationBarIconBrightness: Brightness.light,
        )
      : SystemUiOverlayStyle.light.copyWith(
          statusBarColor: AppColors.navy,
          systemNavigationBarColor: Colors.black,
          systemNavigationBarIconBrightness: Brightness.light,
        );

  return ThemeData(
    useMaterial3: true,
    brightness: isDark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: page,
    canvasColor: page,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    splashFactory: InkRipple.splashFactory,

    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 72,
      titleSpacing: 24,
      backgroundColor: AppColors.navy,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      iconTheme: const IconThemeData(color: Colors.white, size: 25),
      actionsIconTheme: const IconThemeData(color: Colors.white, size: 24),
      titleTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 21,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.05,
      ),
      systemOverlayStyle: overlay,
      shape: const Border(),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.22 : 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.cardRadius,
        side: BorderSide(
          color: outline.withValues(alpha: isDark ? 0.78 : 0.58),
          width: 1,
        ),
      ),
    ),

    dividerTheme: DividerThemeData(
      color: outline.withValues(alpha: 0.7),
      thickness: 1,
      space: 1,
    ),

    chipTheme: ChipThemeData(
      backgroundColor:
          isDark ? const Color(0xFF283452) : AppColors.lightBlue,
      selectedColor:
          isDark ? const Color(0xFF2D4B80) : const Color(0xFFDCE8F8),
      side: BorderSide.none,
      labelStyle: TextStyle(color: onSurface, fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        disabledBackgroundColor: outline.withValues(alpha: 0.45),
        disabledForegroundColor: secondary.withValues(alpha: 0.7),
        minimumSize: const Size.fromHeight(52),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.pillRadius,
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 15,
          letterSpacing: 0.15,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        foregroundColor: onSurface,
        side: BorderSide(color: outline, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.pillRadius,
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: input,
      hintStyle: TextStyle(color: secondary, fontWeight: FontWeight.w500),
      labelStyle: TextStyle(color: secondary, fontWeight: FontWeight.w600),
      errorMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: outline,
      circularTrackColor: outline,
    ),

    navigationBarTheme: NavigationBarThemeData(
      height: 78,
      backgroundColor: isDark ? AppColors.darkPage : Colors.white,
      indicatorColor:
          isDark ? const Color(0xFF263E70) : const Color(0xFFE1EAF7),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          color: selected ? primary : secondary,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? primary : secondary,
          size: selected ? 26 : 24,
        );
      }),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: card,
        foregroundColor: secondary,
        selectedBackgroundColor:
            isDark ? const Color(0xFF2B4478) : const Color(0xFFDDE7F7),
        selectedForegroundColor:
            isDark ? AppColors.darkTextPrimary : AppColors.navy,
        side: BorderSide(color: outline, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor:
          isDark ? AppColors.darkCardRaised : const Color(0xFF1A1F2C),
      contentTextStyle: const TextStyle(color: Colors.white, height: 1.35),
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: card,
      modalBackgroundColor: card,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: primary,
      selectionColor: primary.withValues(alpha: 0.24),
      selectionHandleColor: primary,
    ),

    textTheme: TextTheme(
      displaySmall: TextStyle(
        color: onSurface,
        fontSize: 30,
        fontWeight: FontWeight.w800,
        height: 1.12,
      ),
      headlineSmall: TextStyle(
        color: onSurface,
        fontSize: 24,
        fontWeight: FontWeight.w800,
        height: 1.16,
      ),
      titleLarge: TextStyle(
        color: onSurface,
        fontSize: 21,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
      titleMedium: TextStyle(
        color: onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      titleSmall: TextStyle(
        color: onSurface,
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      bodyLarge: TextStyle(color: onSurface, fontSize: 15.5, height: 1.45),
      bodyMedium: TextStyle(color: onSurface, fontSize: 14.5, height: 1.45),
      bodySmall: TextStyle(color: secondary, fontSize: 12.8, height: 1.4),
      labelLarge: TextStyle(color: onSurface, fontWeight: FontWeight.w800),
      labelMedium: TextStyle(color: secondary, fontWeight: FontWeight.w700),
      labelSmall: TextStyle(color: secondary, fontWeight: FontWeight.w700),
    ),
  );
}

final ThemeData lightTheme = _base(
  seedScheme: ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.light,
  ),
  isDark: false,
);

final ThemeData darkTheme = _base(
  seedScheme: ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.dark,
  ),
  isDark: true,
);

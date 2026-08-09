/// Material 3 theme for EduCompass.
///
/// This file owns presentation tokens only. Existing providers, routes,
/// authentication, recommendation, enrollment, and payment logic remain
/// unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppColors {
  const AppColors._();

  // Brand — calm indigo keeps long study sessions focused without feeling
  // clinical. Teal is reserved for progress / secondary emphasis.
  static const Color navy = Color(0xFF4F46E5);
  static const Color navyDeep = Color(0xFF3730A3);
  static const Color blue = Color(0xFF2563EB);
  static const Color blueBright = Color(0xFF818CF8);
  static const Color lightBlue = Color(0xFFEEF2FF);

  static const Color teal = Color(0xFF0F766E);
  static const Color tealBright = Color(0xFF14B8A6);
  static const Color tealSoft = Color(0xFFECFDF5);
  static const Color amber = Color(0xFFF59E0B);
  static const Color amberSoft = Color(0xFFFFF7ED);

  // Light surfaces
  static const Color pageBg = Color(0xFFF8FAFC);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color cardSoft = Color(0xFFF1F5F9);
  static const Color border = Color(0xFFE2E8F0);

  // Dark surfaces — blue-black rather than pure black for softer contrast.
  static const Color darkPage = Color(0xFF0B1220);
  static const Color darkCard = Color(0xFF111827);
  static const Color darkCardRaised = Color(0xFF182235);
  static const Color darkBorder = Color(0xFF2A3850);

  // Text
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color darkTextPrimary = Color(0xFFF8FAFC);
  static const Color darkTextSecondary = Color(0xFFB6C2D2);

  // Status. Status is always paired with icon/text in shared widgets so
  // meaning never relies on colour alone.
  static const Color success = Color(0xFF059669);
  static const Color warning = Color(0xFFD97706);
  static const Color danger = Color(0xFFDC2626);
  static const Color rating = amber;

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
  static const double lg = 18;
  static const double xl = 22;
  static const double pill = 999;
  static const BorderRadius pillRadius = BorderRadius.all(
    Radius.circular(pill),
  );
  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(lg));
}

ThemeData _base({required ColorScheme seedScheme, required bool isDark}) {
  final primary = isDark ? AppColors.blueBright : AppColors.navy;
  final page = isDark ? AppColors.darkPage : AppColors.pageBg;
  final card = isDark ? AppColors.darkCard : AppColors.cardBg;
  final raised = isDark ? AppColors.darkCardRaised : AppColors.cardBg;
  final onSurface = isDark ? AppColors.darkTextPrimary : AppColors.textPrimary;
  final secondaryText = isDark
      ? AppColors.darkTextSecondary
      : AppColors.textSecondary;
  final outline = isDark ? AppColors.darkBorder : AppColors.border;
  final input = isDark ? const Color(0xFF131D2E) : AppColors.cardBg;

  final scheme = seedScheme.copyWith(
    primary: primary,
    onPrimary: Colors.white,
    primaryContainer: isDark ? const Color(0xFF27285E) : AppColors.lightBlue,
    onPrimaryContainer: isDark
        ? const Color(0xFFE4E7FF)
        : AppColors.navyDeep,
    secondary: isDark ? AppColors.tealBright : AppColors.teal,
    onSecondary: Colors.white,
    secondaryContainer: isDark
        ? const Color(0xFF123D3B)
        : AppColors.tealSoft,
    onSecondaryContainer: isDark
        ? const Color(0xFFC8FFF7)
        : const Color(0xFF064E46),
    tertiary: isDark ? const Color(0xFFFBBF24) : AppColors.amber,
    surface: page,
    onSurface: onSurface,
    onSurfaceVariant: secondaryText,
    surfaceContainerLowest: page,
    surfaceContainerLow: isDark
        ? const Color(0xFF0F1728)
        : const Color(0xFFF4F7FB),
    surfaceContainer: card,
    surfaceContainerHigh: card,
    surfaceContainerHighest: raised,
    outline: outline,
    outlineVariant: outline,
    error: isDark ? const Color(0xFFFFB4AB) : AppColors.danger,
    errorContainer: isDark ? const Color(0xFF5A1B1B) : const Color(0xFFFFEDEC),
    onErrorContainer: isDark ? const Color(0xFFFFDAD6) : const Color(0xFF7F1D1D),
  );

  final overlay = isDark
      ? SystemUiOverlayStyle.light.copyWith(
          statusBarColor: AppColors.darkPage,
          systemNavigationBarColor: AppColors.darkPage,
          systemNavigationBarIconBrightness: Brightness.light,
        )
      : SystemUiOverlayStyle.light.copyWith(
          statusBarColor: AppColors.navy,
          systemNavigationBarColor: AppColors.cardBg,
          systemNavigationBarIconBrightness: Brightness.dark,
        );

  return ThemeData(
    useMaterial3: true,
    brightness: isDark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: page,
    canvasColor: page,
    visualDensity: VisualDensity.standard,
    splashFactory: InkRipple.splashFactory,

    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 66,
      titleSpacing: 18,
      backgroundColor: isDark ? AppColors.darkCard : AppColors.navy,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      iconTheme: const IconThemeData(color: Colors.white, size: 24),
      actionsIconTheme: const IconThemeData(color: Colors.white, size: 23),
      titleTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.05,
      ),
      systemOverlayStyle: overlay,
      shape: const Border(),
    ),

    cardTheme: CardThemeData(
      elevation: isDark ? 0 : 1,
      margin: EdgeInsets.zero,
      color: card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.20 : 0.055),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.cardRadius,
        side: BorderSide(
          color: outline.withValues(alpha: isDark ? 0.86 : 0.72),
          width: 1,
        ),
      ),
    ),

    dividerTheme: DividerThemeData(
      color: outline.withValues(alpha: 0.78),
      thickness: 1,
      space: 1,
    ),

    chipTheme: ChipThemeData(
      backgroundColor: isDark ? const Color(0xFF1C2940) : AppColors.lightBlue,
      selectedColor: isDark
          ? const Color(0xFF2D3373)
          : const Color(0xFFE0E7FF),
      side: BorderSide(color: outline.withValues(alpha: 0.55)),
      labelStyle: TextStyle(color: onSurface, fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: outline.withValues(alpha: 0.55),
        disabledForegroundColor: secondaryText.withValues(alpha: 0.75),
        // Width stays finite inside Row while SizedBox/Expanded can still make
        // buttons full-width where a screen wants that behaviour.
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillRadius),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 15,
          letterSpacing: 0.1,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: primary,
        side: BorderSide(color: outline, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillRadius),
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

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: onSurface,
        hoverColor: primary.withValues(alpha: 0.08),
        highlightColor: primary.withValues(alpha: 0.08),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: input,
      hintStyle: TextStyle(color: secondaryText, fontWeight: FontWeight.w500),
      labelStyle: TextStyle(color: secondaryText, fontWeight: FontWeight.w600),
      prefixIconColor: secondaryText,
      suffixIconColor: secondaryText,
      errorMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
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
        borderSide: BorderSide(color: primary, width: 1.7),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: scheme.error, width: 1.7),
      ),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.secondary,
      linearTrackColor: outline.withValues(alpha: 0.65),
      circularTrackColor: outline.withValues(alpha: 0.65),
    ),

    navigationBarTheme: NavigationBarThemeData(
      height: 74,
      backgroundColor: isDark ? AppColors.darkCard : AppColors.cardBg,
      indicatorColor: isDark
          ? const Color(0xFF2D3373)
          : const Color(0xFFE8EAFE),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.8,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          color: selected ? primary : secondaryText,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? primary : secondaryText,
          size: selected ? 25 : 23,
        );
      }),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: card,
        foregroundColor: secondaryText,
        selectedBackgroundColor: isDark
            ? const Color(0xFF2D3373)
            : const Color(0xFFE8EAFE),
        selectedForegroundColor: isDark
            ? const Color(0xFFE8EAFE)
            : AppColors.navyDeep,
        side: BorderSide(color: outline, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return isDark ? AppColors.darkTextSecondary : AppColors.textSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return primary;
        return outline;
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark
          ? AppColors.darkCardRaised
          : const Color(0xFF172033),
      contentTextStyle: const TextStyle(color: Colors.white, height: 1.35),
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.xl),
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
      selectionColor: primary.withValues(alpha: 0.22),
      selectionHandleColor: primary,
    ),

    textTheme: TextTheme(
      displaySmall: TextStyle(
        color: onSurface,
        fontSize: 30,
        fontWeight: FontWeight.w800,
        height: 1.12,
        letterSpacing: -0.4,
      ),
      headlineSmall: TextStyle(
        color: onSurface,
        fontSize: 24,
        fontWeight: FontWeight.w800,
        height: 1.16,
        letterSpacing: -0.25,
      ),
      titleLarge: TextStyle(
        color: onSurface,
        fontSize: 20.5,
        fontWeight: FontWeight.w800,
        height: 1.2,
        letterSpacing: -0.1,
      ),
      titleMedium: TextStyle(
        color: onSurface,
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        height: 1.28,
      ),
      titleSmall: TextStyle(
        color: onSurface,
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
        height: 1.28,
      ),
      bodyLarge: TextStyle(color: onSurface, fontSize: 15.5, height: 1.5),
      bodyMedium: TextStyle(color: onSurface, fontSize: 14.4, height: 1.48),
      bodySmall: TextStyle(color: secondaryText, fontSize: 12.8, height: 1.42),
      labelLarge: TextStyle(color: onSurface, fontWeight: FontWeight.w800),
      labelMedium: TextStyle(color: secondaryText, fontWeight: FontWeight.w700),
      labelSmall: TextStyle(color: secondaryText, fontWeight: FontWeight.w700),
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

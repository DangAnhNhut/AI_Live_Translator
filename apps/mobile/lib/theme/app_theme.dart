import 'package:flutter/material.dart';

abstract final class AppColors {
  static const primary = Color(0xFF4F5FE7);
  static const primaryStrong = Color(0xFF3444CD);
  static const accent = Color(0xFF7456E8);
  static const background = Color(0xFFF6F5FF);
  static const card = Color(0xFFFFFFFF);
  static const text = Color(0xFF111827);
  static const secondaryText = Color(0xFF64748B);
  static const live = Color(0xFF22C55E);
  static const liveStrong = Color(0xFF15803D);
  static const error = Color(0xFFBA1A1A);
  static const errorSoft = Color(0xFFFFDAD6);
  static const border = Color(0xFFE2E4F0);
  static const lavenderSoft = Color(0xFFF0EFFF);
}

abstract final class AppRadii {
  static const control = 8.0;
  static const card = 16.0;
}

ThemeData buildAppTheme() {
  const colorScheme = ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    secondary: AppColors.accent,
    onSecondary: Colors.white,
    surface: AppColors.card,
    onSurface: AppColors.text,
    error: AppColors.error,
    onError: Colors.white,
    errorContainer: AppColors.errorSoft,
    onErrorContainer: AppColors.error,
  );
  const baseTextTheme = TextTheme(
    headlineLarge: TextStyle(
      fontFamily: 'Plus Jakarta Sans',
      fontSize: 32,
      height: 1.25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.64,
      color: AppColors.text,
    ),
    headlineMedium: TextStyle(
      fontFamily: 'Plus Jakarta Sans',
      fontSize: 26,
      height: 1.23,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.26,
      color: AppColors.text,
    ),
    titleLarge: TextStyle(
      fontFamily: 'Plus Jakarta Sans',
      fontSize: 20,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: AppColors.text,
    ),
    titleMedium: TextStyle(
      fontFamily: 'Plus Jakarta Sans',
      fontSize: 18,
      height: 1.33,
      fontWeight: FontWeight.w600,
      color: AppColors.text,
    ),
    bodyLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      height: 1.5,
      fontWeight: FontWeight.w400,
      color: AppColors.text,
    ),
    bodyMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 15,
      height: 1.47,
      fontWeight: FontWeight.w400,
      color: AppColors.text,
    ),
    bodySmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      height: 1.33,
      color: AppColors.secondaryText,
    ),
    labelLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      height: 1.25,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      height: 1.33,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.24,
    ),
    labelSmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 11,
      height: 1.45,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.7,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Inter',
    textTheme: baseTextTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'Plus Jakarta Sans',
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: AppColors.text,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        textStyle: baseTextTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 56),
        foregroundColor: AppColors.primaryStrong,
        side: const BorderSide(color: AppColors.primary, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        textStyle: baseTextTheme.labelLarge,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
    ),
  );
}

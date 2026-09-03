import 'package:flutter/material.dart';

/// Kavach design system — colours, risk-band palette, and light/dark themes.
class AppTheme {
  static const seed = Color(0xFF1E3A8A); // deep indigo

  // risk band palette (shared with charts + chips)
  static const bandLow = Color(0xFF16A34A);
  static const bandModerate = Color(0xFFF59E0B);
  static const bandHigh = Color(0xFFF97316);
  static const bandCritical = Color(0xFFDC2626);

  static Color bandColor(String band) {
    switch (band.toUpperCase()) {
      case 'LOW':
        return bandLow;
      case 'MODERATE':
        return bandModerate;
      case 'HIGH':
        return bandHigh;
      case 'CRITICAL':
        return bandCritical;
      default:
        return bandModerate;
    }
  }

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF7F8FB),
        cardTheme: CardTheme(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: seed, brightness: Brightness.dark),
      );
}

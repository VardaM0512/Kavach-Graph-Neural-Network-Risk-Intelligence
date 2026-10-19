import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Kavach design tokens.
///
/// The look is a credit desk terminal, not a consumer app: ink surfaces, hairline
/// rules instead of shadows, a serif for headlines, monospaced figures so
/// numbers line up, one interactive colour (ultramarine) and a four-step risk
/// scale that is never reused for anything else.
@immutable
class KColors extends ThemeExtension<KColors> {
  final Color bg, surface, raised, line, lineStrong, text, muted, faint, accent, accentSoft;
  final Color low, moderate, high, critical;

  const KColors({
    required this.bg, required this.surface, required this.raised, required this.line,
    required this.lineStrong, required this.text, required this.muted, required this.faint,
    required this.accent, required this.accentSoft, required this.low, required this.moderate,
    required this.high, required this.critical,
  });

  static const dark = KColors(
    bg: Color(0xFF0A0B0D), surface: Color(0xFF101216), raised: Color(0xFF161920),
    line: Color(0xFF1F232B), lineStrong: Color(0xFF2C313B),
    text: Color(0xFFECE9E2), muted: Color(0xFF969BA5), faint: Color(0xFF5D636E),
    accent: Color(0xFF8C9BFF), accentSoft: Color(0x268C9BFF),
    low: Color(0xFF41D69B), moderate: Color(0xFFE4C452), high: Color(0xFFFF8B45), critical: Color(0xFFFF4F64),
  );

  static const light = KColors(
    bg: Color(0xFFF5F2EB), surface: Color(0xFFFFFDF8), raised: Color(0xFFEFEBE2),
    line: Color(0xFFE2DDD2), lineStrong: Color(0xFFCFC8BA),
    text: Color(0xFF15171B), muted: Color(0xFF5C616B), faint: Color(0xFF9A9EA6),
    accent: Color(0xFF3B4BD8), accentSoft: Color(0x1F3B4BD8),
    low: Color(0xFF168A5C), moderate: Color(0xFFB08A0B), high: Color(0xFFD5620F), critical: Color(0xFFD12A3E),
  );

  Color band(String band) {
    switch (band.toUpperCase()) {
      case 'LOW':
        return low;
      case 'MODERATE':
        return moderate;
      case 'HIGH':
        return high;
      case 'CRITICAL':
        return critical;
    }
    return muted;
  }

  /// Continuous colour for a probability of default (log-scaled, band-aligned).
  Color forPd(double pd) {
    if (pd < 0.03) return Color.lerp(low, moderate, (pd / 0.03).clamp(0, 1) * 0.35)!;
    if (pd < 0.10) return Color.lerp(moderate, high, ((pd - 0.03) / 0.07).clamp(0, 1) * 0.5)!;
    if (pd < 0.30) return Color.lerp(high, critical, ((pd - 0.10) / 0.20).clamp(0, 1) * 0.6)!;
    return critical;
  }

  @override
  KColors copyWith() => this;

  @override
  KColors lerp(ThemeExtension<KColors>? other, double t) => t < 0.5 ? this : (other as KColors);
}

extension KTheme on BuildContext {
  KColors get k => Theme.of(this).extension<KColors>()!;
  TextTheme get tt => Theme.of(this).textTheme;
}

class KType {
  static TextStyle display(Color c, double size) =>
      GoogleFonts.instrumentSerif(color: c, fontSize: size, height: 1.02, letterSpacing: -0.5);
  static TextStyle mono(Color c, double size, {FontWeight w = FontWeight.w500}) =>
      GoogleFonts.jetBrainsMono(color: c, fontSize: size, fontWeight: w, letterSpacing: -0.2,
          fontFeatures: const [FontFeature.tabularFigures()]);
  static TextStyle label(Color c) =>
      GoogleFonts.interTight(color: c, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.1);
}

class AppTheme {
  static ThemeData build(KColors k, Brightness b) {
    final base = GoogleFonts.interTightTextTheme(
        ThemeData(brightness: b).textTheme).apply(bodyColor: k.text, displayColor: k.text);
    final scheme = ColorScheme(
      brightness: b, primary: k.accent, onPrimary: b == Brightness.dark ? k.bg : Colors.white,
      secondary: k.accent, onSecondary: k.bg, error: k.critical, onError: Colors.white,
      surface: k.surface, onSurface: k.text,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: k.bg,
      extensions: [k],
      textTheme: base.copyWith(
        headlineLarge: KType.display(k.text, 44),
        headlineMedium: KType.display(k.text, 34),
        headlineSmall: KType.display(k.text, 26),
        titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 18),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.45, color: k.text),
        bodySmall: base.bodySmall?.copyWith(fontSize: 12.5, color: k.muted, height: 1.4),
      ),
      dividerTheme: DividerThemeData(color: k.line, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: k.surface, elevation: 0, margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: k.line)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: k.raised, isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        labelStyle: TextStyle(color: k.muted), hintStyle: TextStyle(color: k.faint),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: k.line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: k.line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: k.accent, width: 1.4)),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        backgroundColor: k.text, foregroundColor: k.bg, minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: GoogleFonts.interTight(fontWeight: FontWeight.w600, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        foregroundColor: k.text, minimumSize: const Size(0, 46), side: BorderSide(color: k.lineStrong),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: GoogleFonts.interTight(fontWeight: FontWeight.w600, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      )),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: k.accent)),
      sliderTheme: SliderThemeData(
        activeTrackColor: k.accent, inactiveTrackColor: k.line, thumbColor: k.text,
        overlayColor: k.accentSoft, trackHeight: 2, valueIndicatorColor: k.raised,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? k.bg : k.muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? k.accent : k.raised),
        trackOutlineColor: WidgetStatePropertyAll(k.line),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: k.raised, border: Border.all(color: k.lineStrong), borderRadius: BorderRadius.circular(4)),
        textStyle: TextStyle(color: k.text, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(backgroundColor: k.raised, contentTextStyle: TextStyle(color: k.text),
          behavior: SnackBarBehavior.floating),
      dialogTheme: DialogThemeData(backgroundColor: k.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: k.line))),
      popupMenuTheme: PopupMenuThemeData(color: k.raised,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: k.line))),
      scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(k.lineStrong)),
      splashFactory: InkSparkle.splashFactory,
    );
  }

  static ThemeData get dark => build(KColors.dark, Brightness.dark);
  static ThemeData get light => build(KColors.light, Brightness.light);
}

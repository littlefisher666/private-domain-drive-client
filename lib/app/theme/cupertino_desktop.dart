import 'package:flutter/material.dart';

/// Visual tokens aligned with docs/ui macOS Cupertino prototype.
class CupertinoDesktopTokens {
  CupertinoDesktopTokens._();

  static const Color blue = Color(0xFF007AFF);
  static const Color bluePress = Color(0xFF0063D1);
  static const Color background = Color(0xFFF2F2F7);
  static const Color ink = Color(0xFF1C1C1E);
  static const Color secondary = Color(0xFF8E8E93);
  static const Color line = Color(0x2E3C3C43);
  static const Color sidebar = Color(0xEBF2F2F7);
  static const Color surface = Colors.white;
  static const Color previewBg = Color(0xF5F8F8FA);
  static const Color danger = Color(0xFFFF3B30);
  static const Color success = Color(0xFF34C759);
  static const Color warning = Color(0xFFFF9500);
  static const Color chipAdminBg = Color(0x1F007AFF);
  static const Color chipMemberBg = Color(0x2434C759);
  static const Color chipMemberFg = Color(0xFF248A3D);
  static const Color folderBg = Color(0xFFFFF3E0);
  static const Color folderFg = Color(0xFFC27803);
  static const Color imageBg = Color(0xFFE8F8EF);
  static const Color imageFg = Color(0xFF1F8A4C);
  static const Color pdfBg = Color(0xFFFDECEC);
  static const Color pdfFg = Color(0xFFD12B2B);
  static const Color textBg = Color(0xFFEEF2FF);
  static const Color textFg = Color(0xFF4F46E5);
  static const Color fileBg = Color(0xFFF2F2F7);
  static const Color fileFg = Color(0xFF636366);
  static const Color controlFill = Color(0x1F767680);
  static const Color noteBg = Color(0x1AFF9500);
  static const Color noteFg = Color(0xFF9A5B00);

  static const double sidebarWidth = 248;
  static const double previewWidth = 300;
  static const double titleBarHeight = 44;
}

class CupertinoDesktopTheme {
  CupertinoDesktopTheme._();

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF5AA7FF),
      onPrimary: Color(0xFF061A33),
      secondary: Color(0xFF8ED0FF),
      onSecondary: Color(0xFF06223A),
      error: Color(0xFFFF6961),
      onError: Color(0xFF3A0805),
      surface: Color(0xFF15171B),
      onSurface: Color(0xFFF2F4F7),
      surfaceContainerHighest: Color(0xFF25282E),
      onSurfaceVariant: Color(0xFFAEB4BE),
      outline: Color(0xFF3A3E46),
      outlineVariant: Color(0xFF2D3138),
      shadow: Color(0x99000000),
      scrim: Color(0xB3000000),
      inverseSurface: Color(0xFFF2F4F7),
      onInverseSurface: Color(0xFF15171B),
      inversePrimary: Color(0xFF0063D1),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
    );

    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF1C1E22),
      dividerColor: scheme.outlineVariant,
      textTheme: base.textTheme
          .apply(
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
          )
          .copyWith(
            headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
            titleLarge: base.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
            titleMedium: base.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            titleSmall: base.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
            bodySmall: base.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
            labelLarge: base.textTheme.labelLarge?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: scheme.surfaceContainerHighest,
          side: BorderSide.none,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFFF2F4F7),
        contentTextStyle:
            const TextStyle(color: Color(0xFF15171B), fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        dense: true,
      ),
    );
  }

  static ThemeData light() {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: CupertinoDesktopTokens.blue,
      onPrimary: Colors.white,
      secondary: Color(0xFF5AC8FA),
      onSecondary: Colors.white,
      error: CupertinoDesktopTokens.danger,
      onError: Colors.white,
      surface: CupertinoDesktopTokens.surface,
      onSurface: CupertinoDesktopTokens.ink,
      surfaceContainerHighest: CupertinoDesktopTokens.background,
      onSurfaceVariant: CupertinoDesktopTokens.secondary,
      outline: CupertinoDesktopTokens.line,
      outlineVariant: CupertinoDesktopTokens.line,
      shadow: Color(0x14000000),
      scrim: Color(0x47000000),
      inverseSurface: CupertinoDesktopTokens.ink,
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFF64B5FF),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
    );

    return base.copyWith(
      scaffoldBackgroundColor: CupertinoDesktopTokens.background,
      dividerColor: CupertinoDesktopTokens.line,
      textTheme: base.textTheme
          .apply(
            bodyColor: CupertinoDesktopTokens.ink,
            displayColor: CupertinoDesktopTokens.ink,
          )
          .copyWith(
            headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: CupertinoDesktopTokens.ink,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: CupertinoDesktopTokens.ink,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: CupertinoDesktopTokens.ink,
            ),
            titleSmall: base.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: CupertinoDesktopTokens.ink,
            ),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(
              color: CupertinoDesktopTokens.ink,
            ),
            bodySmall: base.textTheme.bodySmall?.copyWith(
              color: CupertinoDesktopTokens.secondary,
            ),
            labelLarge: base.textTheme.labelLarge?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: CupertinoDesktopTokens.secondary,
            ),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: CupertinoDesktopTokens.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: CupertinoDesktopTokens.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: CupertinoDesktopTokens.line),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: CupertinoDesktopTokens.line,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: CupertinoDesktopTokens.blue,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              CupertinoDesktopTokens.blue.withValues(alpha: 0.4),
          elevation: 0,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CupertinoDesktopTokens.ink,
          backgroundColor: CupertinoDesktopTokens.controlFill,
          side: BorderSide.none,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: CupertinoDesktopTokens.blue,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: CupertinoDesktopTokens.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: CupertinoDesktopTokens.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
              color: CupertinoDesktopTokens.blue.withValues(alpha: 0.55)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: CupertinoDesktopTokens.blue,
        linearTrackColor: Color(0x29767680),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xEB1C1C1E),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xF5FFFFFF),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: CupertinoDesktopTokens.line),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: CupertinoDesktopTokens.secondary,
        textColor: CupertinoDesktopTokens.ink,
        dense: true,
      ),
    );
  }
}

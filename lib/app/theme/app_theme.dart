import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1C6E5B)),
      useMaterial3: true,
    );
  }
}

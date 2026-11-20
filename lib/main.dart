import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:grid_frontend/styles/tokens.dart';
import 'package:grid_frontend/styles/grid_colors.dart';
import 'package:grid_frontend/services/theme_controller.dart';
import 'package:grid_frontend/services/location_manager.dart';
import 'package:grid_frontend/services/sharing_state_notifier.dart';
import 'package:grid_frontend/services/veilid_service.dart';
import 'package:grid_frontend/services/database_service.dart';
import 'package:grid_frontend/repositories/location_history_repository.dart';
import 'package:grid_frontend/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GridApp());
  _initLocation();
  _initHistory();
  _initSharing();
}

/// Best-effort location boot: start tracking so "Send location" has a real
/// fix. Fire-and-forget so it never blocks first frame or crashes boot.
Future<void> _initLocation() async {
  try {
    await LocationManager.instance.initialize();
    await LocationManager.instance.startTracking();
  } catch (e) {
    debugPrint('[Location] init failed (non-fatal): $e');
  }
}

/// Wire the device-local location history repo into VeilidService so received
/// contact locations (and my own fixes) are recorded as trails. Construction is
/// cheap (the DB is opened lazily on first write).
void _initHistory() {
  final db = DatabaseService();
  final repo = LocationHistoryRepository(db);
  VeilidService.instance.attachHistoryRepo(repo);

  // Record my own trail from the location stream (the repo throttles points).
  LocationManager.instance.locationStream.listen((update) {
    VeilidService.instance.recordMyLocation(update.latitude, update.longitude);
  });
}

/// Continuously share my location: on each fix, push to every non-paused
/// contact unless sharing is paused/incognito.
void _initSharing() {
  LocationManager.instance.locationStream.listen((update) {
    if (SharingStateNotifier.instance.isPaused) return;
    VeilidService.instance.sendLocation(update.latitude, update.longitude,
        accuracy: update.accuracy);
  });
}

class GridApp extends StatelessWidget {
  const GridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'Grid',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(GridTokens.lightScheme()),
        darkTheme: _buildTheme(GridTokens.darkScheme()),
        themeMode: ThemeController.instance.mode,
        home: const HomeScreen(),
      ),
    );
  }
}

/// Build the app theme from a Grid-tokenized ColorScheme.
ThemeData _buildTheme(ColorScheme scheme) {
  final base = scheme.brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  final gridColors = scheme.brightness == Brightness.dark
      ? GridColors.dark()
      : GridColors.light();

  final textTheme = GoogleFonts.getTextTheme('Geist', base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[gridColors],
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.getFont('Geist',
        color: scheme.onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.015,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceVariant,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GridTokens.rLg),
        side: BorderSide(color: scheme.outlineVariant, width: 1),
      ),
    ),
    dividerColor: scheme.outlineVariant,
    iconTheme: IconThemeData(color: scheme.onSurface),
    primaryIconTheme: IconThemeData(color: scheme.onPrimary),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: GoogleFonts.getFont('Geist',
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: scheme.outline, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: GoogleFonts.getFont('Geist',
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        textStyle: GoogleFonts.getFont('Geist',
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceVariant,
      hintStyle: GoogleFonts.getFont('Geist', color: gridColors.text3, fontSize: 15),
      labelStyle: GoogleFonts.getFont('Geist', color: gridColors.text2, fontSize: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: GoogleFonts.getFont('Geist', color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GridTokens.rMd),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(GridTokens.r2Xl),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GridTokens.rXl),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : scheme.onSurface.withOpacity(0.5),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    ),
  );
}

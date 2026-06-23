import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/constants/api_constants.dart';
import 'core/constants/theme_constants.dart';
import 'core/network/api_client.dart';
import 'core/router/app_router.dart';
import 'features/settings/domain/settings_model.dart';
import 'features/settings/providers/settings_provider.dart';

class RedSlideApp extends ConsumerStatefulWidget {
  const RedSlideApp({super.key});

  @override
  ConsumerState<RedSlideApp> createState() => _RedSlideAppState();
}

class _RedSlideAppState extends ConsumerState<RedSlideApp> {
  bool _hasSynced = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);

    ref.listen(settingsProvider, (_, next) {
      if (_hasSynced) return;
      next.whenData((settings) {
        if (settings.backendUrl.isNotEmpty && settings.subreddits.isNotEmpty) {
          _hasSynced = true;
          _syncSubreddits(settings);
        }
      });
    });

    return settingsAsync.when(
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      error: (_, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: Text('Failed to load settings'))),
      ),
      data: (settings) {
        final router = ref.watch(routerProvider);

        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          title: 'RedSlide',
          routerConfig: router,
          themeMode: _resolveThemeMode(settings.themeMode),
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
        );
      },
    );
  }

  Future<void> _syncSubreddits(SettingsModel settings) async {
    try {
      final client = ApiClient(baseUrl: settings.backendUrl);
      await client.post(
        ApiConstants.subredditsSync,
        data: {'subreddits': settings.subreddits},
      );
    } catch (_) {}
  }

  ThemeMode _resolveThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  ThemeData _buildLightTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primarySeed,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme);
  }

  ThemeData _buildDarkTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primarySeed,
      brightness: Brightness.dark,
      surface: const Color(0xFF121212),
    );
    return _buildTheme(colorScheme);
  }

  ThemeData _buildTheme(ColorScheme colorScheme) {
    final textTheme = GoogleFonts.interTextTheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: colorScheme.surfaceContainerHighest, width: 1),
        ),
        color: colorScheme.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.secondaryContainer,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 0.5,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
        ),
      ),
    );
  }
}

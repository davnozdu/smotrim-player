import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:open_tv/l10n/strings.dart';
import 'package:open_tv/backend/launch_bridge.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/updater.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/custom_shortcut.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/setup.dart';
import 'package:open_tv/tv_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Cap decoded-image memory (default is ~100 MB) so channel logos don't
  // balloon RAM on weak TV boxes.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 48 << 20 // ~48 MB
    ..maximumSize = 300;
  final hasSources = await Sql.hasSources();
  final settings = await SettingsService.getSettings();
  final hasTouchScreen = await Utils.hasTouchScreen();
  final isTV = await DeviceDetector.isTV();
  runApp(
    MyApp(
      skipSetup: hasSources,
      settings: settings,
      hasTouchScreen: hasTouchScreen,
      isTV: isTV,
    ),
  );
  if (Platform.isAndroid) {
    // Keep the native boot-receiver flag in sync with the stored setting.
    LaunchBridge.setAutostartEnabled(settings.autostartOnBoot);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Updater.checkAndPrompt(MyApp.navigatorKey);
    });
  }
}

class MyApp extends StatelessWidget {
  final bool skipSetup;
  final Settings settings;
  final bool hasTouchScreen;
  final bool isTV;
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  const MyApp({
    super.key,
    required this.skipSetup,
    required this.settings,
    required this.hasTouchScreen,
    required this.isTV,
  });

  bool get _isEditingText {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final context = focus.context;
    if (context == null || !context.mounted) return false;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smotrim CZ Player',
      navigatorKey: navigatorKey,
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FormBuilderLocalizations.delegate,
      ],
      builder: (context, child) {
        return _KeyboardNavFix(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_isEditingText) {
                  final focus = FocusManager.instance.primaryFocus;
                  focus?.unfocus();
                  focus?.nextFocus();
                  return;
                }
                navigatorKey.currentState?.maybePop();
              },
              const SingleActivator(LogicalKeyboardKey.goBack): () {
                // Only handle the in-keyboard case; the system Back button drives
                // route navigation (PopScope), so don't pop here too — otherwise
                // Back fires twice (over-pops / double-exits).
                if (_isEditingText) {
                  final focus = FocusManager.instance.primaryFocus;
                  focus?.unfocus();
                  focus?.nextFocus();
                }
              },
              CustomShortcut(
                const SingleActivator(LogicalKeyboardKey.backspace),
              ): () {
                if (_isEditingText) return;
                navigatorKey.currentState?.maybePop();
              },
            },
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          surface: Colors.black,
          brightness: Brightness.dark,
          surfaceContainer: Color.fromARGB(255, 29, 36, 41),
        ),
        // High-contrast D-pad focus highlight (default is a faint grey that is
        // hard to see on the black background).
        focusColor: const Color(0x804FC3F7), // bright blue overlay
        hoverColor: const Color(0x334FC3F7),
        listTileTheme: const ListTileThemeData(
          selectedColor: Colors.white,
          selectedTileColor: Color(0x334FC3F7),
        ),
        // Make focused dialog buttons (TextButton) clearly visible too.
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return const Color(0x804FC3F7);
              }
              return null;
            }),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return const BorderSide(
                  color: Colors.yellow, // yellow border
                  width: 4,
                );
              }
              return BorderSide.none;
            }),
          ),
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      home: skipSetup
          ? (settings.hotelMode ||
                    settings.forceTVMode ||
                    isTV ||
                    (!hasTouchScreen && (Platform.isAndroid || Platform.isIOS))
                ? TvHome(hotelMode: settings.hotelMode)
                : Home(
                    firstLaunch: true,
                    refresh: settings.refreshOnStart,
                    home: HomeManager(
                      filters: Filters(viewType: settings.defaultView),
                    ),
                  ))
          : const Setup(),
    );
  }
}

/// Android TV fix: when the soft keyboard is dismissed (e.g. with Back) while a
/// text field still holds focus, the D-pad arrows keep moving the text cursor
/// and navigation feels "dead". When the keyboard closes we move focus to the
/// next focusable widget so the remote can navigate again.
class _KeyboardNavFix extends StatefulWidget {
  final Widget child;
  const _KeyboardNavFix({required this.child});

  @override
  State<_KeyboardNavFix> createState() => _KeyboardNavFixState();
}

class _KeyboardNavFixState extends State<_KeyboardNavFix>
    with WidgetsBindingObserver {
  double _lastInset = 0;
  bool _keyboardWasVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final inset = WidgetsBinding
            .instance.platformDispatcher.implicitView?.viewInsets.bottom ??
        0;
    final keyboardVisible = inset > 0;
    if ((_lastInset > 0 || _keyboardWasVisible) && !keyboardVisible) {
      _restoreNavigationFocusAfterKeyboardClose();
    }
    _lastInset = inset;
    _keyboardWasVisible = keyboardVisible;
  }

  @override
  Widget build(BuildContext context) => widget.child;

  void _restoreNavigationFocusAfterKeyboardClose() {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    final editing =
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (!editing || focus == null) return;

    for (var i = 0; i < 8; i++) {
      if (!focus.nextFocus()) break;
      final nextFocus = FocusManager.instance.primaryFocus;
      final nextContext = nextFocus?.context;
      final nextIsEditing =
          nextContext?.findAncestorWidgetOfExactType<EditableText>() != null;
      if (!nextIsEditing) return;
    }

    focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scope = FocusScope.of(context);
      if (scope.focusedChild == null || scope.focusedChild == focus) {
        scope.nextFocus();
      }
    });
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/intl_keys.g.dart';
import 'package:immich_mobile/pages/common/external_file_viewer.page.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/share_intent_upload.provider.dart';
import 'package:immich_mobile/providers/db.provider.dart';
import 'package:immich_mobile/providers/view_intent.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/background.service.dart';
import 'package:immich_mobile/services/deep_link.service.dart';
import 'package:immich_mobile/services/local_notification.service.dart';
import 'package:immich_mobile/services/view_intent.service.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/cache/widgets_binding.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/http_ssl_options.dart';
import 'package:immich_mobile/utils/licenses.dart';
import 'package:immich_mobile/utils/migration.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest.dart';

void main() async {
  ImmichWidgetsBinding();

  // Check if this is a cold start via external intent BEFORE doing heavy initialization
  bool isColdStartViaIntent = false;
  if (Platform.isAndroid) {
    try {
      const platform = MethodChannel('app.alextran.immich/intent');
      isColdStartViaIntent = await platform.invokeMethod<bool>('isColdStartViaIntent') ?? false;
      if (isColdStartViaIntent) {
        dPrint(() => "[MAIN] Detected cold start via intent - using fast path");
      }
    } catch (e) {
      dPrint(() => "[MAIN] Could not check intent status: $e");
    }
  }

  if (!isColdStartViaIntent) {
    // Normal startup - full initialization
    unawaited(BackgroundWorkerLockService(BackgroundWorkerLockApi()).lock());
    final (isar, drift, logDb) = await Bootstrap.initDB();
    await Bootstrap.initDomain(isar, drift, logDb);
    await initApp();
    await workerManagerPatch.init(dynamicSpawning: true, isolatesCount: max(Platform.numberOfProcessors - 1, 5));
    await migrateDatabaseIfNeeded(isar, drift);
    HttpSSLOptions.apply();

    runApp(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(isar),
          isarProvider.overrideWithValue(isar),
          driftProvider.overrideWith(driftOverride(drift)),
        ],
        child: const MainWidget(),
      ),
    );
  } else {
    // FAST PATH for external viewing - SKIP database entirely!
    dPrint(() => "[MAIN] Fast path: INSTANT initialization for external file viewing");

    // ONLY minimal initialization - no database, no domain, nothing heavy
    final stopwatch = Stopwatch()..start();
    await initAppMinimal();
    dPrint(() => "[MAIN] Fast path: initAppMinimal took ${stopwatch.elapsedMilliseconds}ms");

   // HttpSSLOptions.apply();
    dPrint(() => "[MAIN] Fast path: Launching app NOW (no database initialization)");

    // Launch app IMMEDIATELY without any database
    // AppSettingsService now safely returns defaults when Store isn't initialized
    runApp(
      ProviderScope(
        overrides: [
          wasColdStartViaIntentProvider.overrideWith((ref) => true),
          // NO database providers - app will use defaults
        ],
        child: const ExternalIntentApp(),
      ),
    );

    dPrint(() => "[MAIN] Fast path: App launched in ${stopwatch.elapsedMilliseconds}ms total");

  }
}

Future<void> initApp() async {
  await EasyLocalization.ensureInitialized();
  await initializeDateFormatting();

  if (kReleaseMode && Platform.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
      dPrint(() => "Enabled high refresh mode");
    } catch (e) {
      dPrint(() => "Error setting high refresh rate: $e");
    }
  }

  await DynamicTheme.fetchSystemPalette();

  final log = Logger("ImmichErrorLogger");

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.severe(
      'FlutterError - Catch all',
      "${details.toString()}\nException: ${details.exception}\nLibrary: ${details.library}\nContext: ${details.context}",
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.severe('PlatformDispatcher - Catch all', error, stack);
    return true;
  };

  initializeTimeZones();

  // Initialize the file downloader
  await FileDownloader().configure(
    // maxConcurrent: 6, maxConcurrentByHost(server):6, maxConcurrentByGroup: 3

    // On Android, if files are larger than 256MB, run in foreground service
    globalConfig: [(Config.holdingQueue, (6, 6, 3)), (Config.runInForegroundIfFileLargerThan, 256)],
  );

  await FileDownloader().trackTasksInGroup(kDownloadGroupLivePhoto, markDownloadedComplete: false);

  await FileDownloader().trackTasks();

  LicenseRegistry.addLicense(() async* {
    for (final license in nonPubLicenses.entries) {
      yield LicenseEntryWithLineBreaks([license.key], license.value);
    }
  });
}

/// Minimal initialization for external file viewing (fast path)
Future<void> initAppMinimal() async {
  // Only initialize what's absolutely necessary for viewing external files
  await EasyLocalization.ensureInitialized();
  await initializeDateFormatting();

  // Error logging is still important
  final log = Logger("ImmichErrorLogger");

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.severe(
      'FlutterError - Catch all',
      "${details.toString()}\nException: ${details.exception}\nLibrary: ${details.library}\nContext: ${details.context}",
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.severe('PlatformDispatcher - Catch all', error, stack);
    return true;
  };

  // Skip: DynamicTheme (not needed initially)
  // Skip: FlutterDisplayMode (not critical)
  // Skip: initializeTimeZones (not needed for viewing)
  // Skip: FileDownloader (not needed for external viewing)
  // Skip: LicenseRegistry (not needed for viewing)

  dPrint(() => "[INIT] Minimal app init completed for external file viewing");
}

class ImmichApp extends ConsumerStatefulWidget {
  const ImmichApp({super.key});

  @override
  ImmichAppState createState() => ImmichAppState();
}

class ImmichAppState extends ConsumerState<ImmichApp> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasColdStartViaIntent = ref.read(wasColdStartViaIntentProvider);
    if (wasColdStartViaIntent) {
      dPrint(() => "[APP STATE] $state (cold start) - skipping lifecycle handlers");
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        dPrint(() => "[APP STATE] resumed");
        ref.read(appStateProvider.notifier).handleAppResume();
        break;
      case AppLifecycleState.inactive:
        dPrint(() => "[APP STATE] inactive");
        ref.read(appStateProvider.notifier).handleAppInactivity();
        break;
      case AppLifecycleState.paused:
        dPrint(() => "[APP STATE] paused");
        ref.read(appStateProvider.notifier).handleAppPause();
        break;
      case AppLifecycleState.detached:
        dPrint(() => "[APP STATE] detached");
        ref.read(appStateProvider.notifier).handleAppDetached();
        break;
      case AppLifecycleState.hidden:
        dPrint(() => "[APP STATE] hidden");
        ref.read(appStateProvider.notifier).handleAppHidden();
        break;
    }
  }

  Future<void> initApp() async {
    WidgetsBinding.instance.addObserver(this);

    // Draw the app from edge to edge
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

    // Sets the navigation bar color
    SystemUiOverlayStyle overlayStyle = const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent);
    if (Platform.isAndroid) {
      // Android 8 does not support transparent app bars
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt <= 26) {
        overlayStyle = context.isDarkTheme ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light;
      }
    }
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);
    await ref.read(localNotificationService).setup();
  }

  Future<DeepLink> _deepLinkBuilder(PlatformDeepLink deepLink) async {
    final deepLinkHandler = ref.read(deepLinkServiceProvider);
    final currentRouteName = ref.read(currentRouteNameProvider.notifier).state;

    final isColdStart = currentRouteName == null || currentRouteName == SplashScreenRoute.name;

    if (deepLink.uri.scheme == "immich") {
      final proposedRoute = await deepLinkHandler.handleScheme(deepLink, ref, isColdStart);

      return proposedRoute;
    }

    if (deepLink.uri.host == "my.immich.app") {
      final proposedRoute = await deepLinkHandler.handleMyImmichApp(deepLink, ref, isColdStart);

      return proposedRoute;
    }

    return DeepLink.path(deepLink.path);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Intl.defaultLocale = context.locale.toLanguageTag();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      configureFileDownloaderNotifications();
    });
  }

  @override
  initState() {
    super.initState();
    initApp().then((_) => dPrint(() => "App Init Completed"));

    // Initialize view intent first to determine if this is a cold start
    ref.read(viewIntentProvider).init();

    // Defer background services initialization until after first frame
    // This speeds up external file viewing significantly
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Skip background services if app was cold-started via external intent
      // These are not needed for just viewing external files
      final wasColdStart = ref.read(wasColdStartViaIntentProvider);
      if (!wasColdStart) {
        // needs to be delayed so that EasyLocalization is working
        if (Store.isBetaTimelineEnabled) {
          ref.read(backgroundServiceProvider).disableService();
          ref.read(backgroundWorkerFgServiceProvider).enable();
          if (Platform.isAndroid) {
            ref
                .read(backgroundWorkerFgServiceProvider)
                .saveNotificationMessage(
                  IntlKeys.uploading_media.t(),
                  IntlKeys.backup_background_service_default_notification.t(),
                );
          }
        } else {
          ref.read(backgroundWorkerFgServiceProvider).disable();
          ref.read(backgroundServiceProvider).resumeServiceIfEnabled();
        }

        // Share intent upload is also not needed for external viewing
        ref.read(shareIntentUploadProvider.notifier).init();
      } else {
        dPrint(() => "[INIT] Skipping background services for external file view");
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final immichTheme = ref.watch(immichThemeProvider);

    return ProviderScope(
      overrides: [localeProvider.overrideWithValue(context.locale)],
      child: MaterialApp.router(
        title: 'Immich',
        debugShowCheckedModeBanner: true,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        themeMode: ref.watch(immichThemeModeProvider),
        darkTheme: getThemeData(colorScheme: immichTheme.dark, locale: context.locale),
        theme: getThemeData(colorScheme: immichTheme.light, locale: context.locale),
        routerConfig: router.config(
          deepLinkBuilder: _deepLinkBuilder,
          navigatorObservers: () => [AppNavigationObserver(ref: ref)],
        ),
      ),
    );
  }
}

class MainWidget extends StatelessWidget {
  const MainWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      useFallbackTranslations: true,
      fallbackLocale: locales.values.first,
      assetLoader: const CodegenLoader(),
      child: const ImmichApp(),
    );
  }
}

class ExternalIntentApp extends ConsumerStatefulWidget {
  const ExternalIntentApp({super.key});

  @override
  ConsumerState<ExternalIntentApp> createState() => _ExternalIntentAppState();
}

class _ExternalIntentAppState extends ConsumerState<ExternalIntentApp> {
  String? _uri;

  @override
  void initState() {
    super.initState();
    final service = ref.read(viewIntentServiceProvider);
    service.onViewIntent = (uri, wasColdStart) {
      if (!mounted) return;
      setState(() {
        _uri = uri;
      });
    };
    service.init();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Immich',
      debugShowCheckedModeBanner: true,
      theme: ThemeData.dark(),
      home: _uri == null
          ? const Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            )
          : ExternalFileViewerPage(uri: _uri!),
    );
  }
}

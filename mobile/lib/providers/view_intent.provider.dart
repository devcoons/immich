import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/view_intent.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';

final viewIntentProvider = Provider<ViewIntentNotifier>((ref) {
  return ViewIntentNotifier(
    ref.watch(appRouterProvider),
    ref.watch(viewIntentServiceProvider),
  );
});

class ViewIntentNotifier {
  final AppRouter router;
  final ViewIntentService _viewIntentService;

  ViewIntentNotifier(this.router, this._viewIntentService);

  void init() {
    _viewIntentService.onViewIntent = onViewIntent;
    _viewIntentService.init();
  }

  void onViewIntent(String uriString) {
    dPrint(() => "[ViewIntentNotifier] Handling VIEW intent for URI: $uriString");

    try {
      // Parse the URI
      final uri = Uri.parse(uriString);
      String? filePath;

      // Handle different URI schemes
      if (uri.scheme == 'file') {
        // file:// URIs - extract the path directly
        filePath = uri.path;
      } else if (uri.scheme == 'content') {
        // content:// URIs - we'll need to use the share_handler package or similar
        // For now, we'll pass the URI string and let the native viewer handle it
        // This is a limitation - content URIs typically need native handling
        dPrint(() => "[ViewIntentNotifier] Content URIs require additional handling");

        // Navigate to an external file viewer page
        // Use push with a delay to ensure the app is fully resumed first
        dPrint(() => "[ViewIntentNotifier] Pushing ExternalFileViewerRoute for content URI");
        // Add a small delay to let the app settle after resume
        Future.delayed(const Duration(milliseconds: 100), () {
          try {
            router.push(ExternalFileViewerRoute(uri: uriString));
            dPrint(() => "[ViewIntentNotifier] Navigation pushed successfully");
          } catch (e) {
            dPrint(() => "[ViewIntentNotifier] ERROR during navigation: $e");
          }
        });
        return;
      } else {
        dPrint(() => "[ViewIntentNotifier] Unsupported URI scheme: ${uri.scheme}");
        return;
      }

      if (filePath != null && File(filePath).existsSync()) {
        dPrint(() => "[ViewIntentNotifier] Opening file at path: $filePath");
        Future.delayed(const Duration(milliseconds: 100), () {
          try {
            router.push(ExternalFileViewerRoute(uri: uriString));
            dPrint(() => "[ViewIntentNotifier] Navigation pushed successfully");
          } catch (e) {
            dPrint(() => "[ViewIntentNotifier] ERROR during navigation: $e");
          }
        });
      } else {
        dPrint(() => "[ViewIntentNotifier] File not found at path: $filePath");
      }
    } catch (e) {
      dPrint(() => "[ViewIntentNotifier] ERROR handling VIEW intent: $e");
    }
  }
}

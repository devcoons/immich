import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/providers/asset_viewer/current_asset.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/view_intent.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/external_asset.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart';

// Provider to track if the app was launched via external intent (cold start)
final wasColdStartViaIntentProvider = StateProvider<bool>((ref) => false);

final viewIntentProvider = Provider<ViewIntentNotifier>((ref) {
  return ViewIntentNotifier(
    ref.watch(appRouterProvider),
    ref.watch(viewIntentServiceProvider),
    ref,
  );
});

class ViewIntentNotifier {
  final AppRouter router;
  final ViewIntentService _viewIntentService;
  final Ref _ref;

  ViewIntentNotifier(this.router, this._viewIntentService, this._ref);

  void init() {
    _viewIntentService.onViewIntent = onViewIntent;
    _viewIntentService.init();
  }

  void onViewIntent(String uriString, bool wasColdStart) async {
    dPrint(() => "[ViewIntentNotifier] Handling VIEW intent for URI: $uriString (coldStart: $wasColdStart)");

    try {
      // Track if the app was cold-started via intent (if not already set in main())
      if (wasColdStart && !_ref.read(wasColdStartViaIntentProvider)) {
        _ref.read(wasColdStartViaIntentProvider.notifier).state = true;
        dPrint(() => "[ViewIntentNotifier] App was cold-started via intent - will exit on back press");
      }

      // Create a temporary external asset from the URI
      final Asset externalAsset = await ExternalAssetHelper.createFromUri(uriString);
      dPrint(() => "[ViewIntentNotifier] Created external asset: ${externalAsset.fileName}, type: ${externalAsset.type}");

      // Set this as the current asset
      _ref.read(currentAssetProvider.notifier).set(externalAsset);

      // Create a single-item render list for the gallery viewer
      final renderList = await RenderList.fromAssets([externalAsset], GroupAssetsBy.none);

      // Navigate to the normal gallery viewer with the external asset
      // For cold starts, navigate immediately for faster loading
      // For warm starts, add a small delay to let the app settle
      final navigationDelay = wasColdStart ? Duration.zero : const Duration(milliseconds: 100);

      Future.delayed(navigationDelay, () {
        try {
          router.push(
            GalleryViewerRoute(
              renderList: renderList,
              initialIndex: 0,
            ),
          );
          dPrint(() => "[ViewIntentNotifier] Navigation to GalleryViewer pushed successfully");
        } catch (e) {
          dPrint(() => "[ViewIntentNotifier] ERROR during navigation: $e");
        }
      });
    } catch (e) {
      dPrint(() => "[ViewIntentNotifier] ERROR handling VIEW intent: $e");
    }
  }
}

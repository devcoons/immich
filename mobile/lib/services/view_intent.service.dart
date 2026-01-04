import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/utils/debug_print.dart';

final viewIntentServiceProvider = Provider((ref) => ViewIntentService());

/// Service to handle ACTION_VIEW intents (opening images/videos directly)
class ViewIntentService {
  static const MethodChannel _intentChannel = MethodChannel('app.alextran.immich/intent');

  void Function(String uri)? onViewIntent;

  void init() {
    if (!Platform.isAndroid) {
      // Only Android supports this intent handling for now
      return;
    }

    _intentChannel.setMethodCallHandler(_handleMethodCall);
    dPrint(() => "[ViewIntentService] Initialized and listening for VIEW intents");
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    dPrint(() => "[ViewIntentService] Method call received: ${call.method}, arguments: ${call.arguments}");
    if (call.method == 'viewUri') {
      try {
        final arguments = call.arguments as Map<dynamic, dynamic>;
        final uri = arguments['uri'] as String?;
        if (uri != null && uri.isNotEmpty) {
          dPrint(() => "[ViewIntentService] Received VIEW intent with URI: $uri");
          onViewIntent?.call(uri);
        } else {
          dPrint(() => "[ViewIntentService] ERROR: URI is null or empty");
        }
      } catch (e) {
        dPrint(() => "[ViewIntentService] ERROR parsing arguments: $e");
      }
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/external_asset.dart';

/// Image provider for external assets loaded from file:// or content:// URIs
class ImmichExternalImageProvider extends ImageProvider<ImmichExternalImageProvider> {
  final Asset asset;

  ImmichExternalImageProvider({required this.asset});

  @override
  Future<ImmichExternalImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<ImmichExternalImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(ImmichExternalImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: 'ExternalAsset(${asset.fileName})',
    );
  }

  Future<ui.Codec> _loadAsync(ImmichExternalImageProvider key, ImageDecoderCallback decode) async {
    assert(key == this);

    try {
      final uri = ExternalAssetHelper.getUri(asset);
      if (uri == null) {
        throw Exception('External asset has no URI');
      }

      dPrint(() => "[ImmichExternalImageProvider] Loading image from URI: $uri");
      final parsedUri = Uri.parse(uri);
      Uint8List bytes;

      if (parsedUri.scheme == 'file') {
        // Load from file path
        final filePath = parsedUri.path;
        final file = File(filePath);

        if (!file.existsSync()) {
          throw Exception('File not found: $filePath');
        }

        bytes = await file.readAsBytes();
        dPrint(() => "[ImmichExternalImageProvider] Loaded ${bytes.length} bytes from file");
      } else if (parsedUri.scheme == 'content') {
        // Load from content URI via platform channel
        final loadedBytes = await ExternalAssetHelper.readContentUriBytes(uri);
        if (loadedBytes == null) {
          throw Exception('Failed to read content URI: $uri');
        }
        bytes = loadedBytes;
        dPrint(() => "[ImmichExternalImageProvider] Loaded ${bytes.length} bytes from content URI");
      } else {
        throw Exception('Unsupported URI scheme: ${parsedUri.scheme}');
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer);
    } catch (e) {
      dPrint(() => "[ImmichExternalImageProvider] Error loading external image: $e");
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ImmichExternalImageProvider) return false;
    return asset.localId == other.asset.localId;
  }

  @override
  int get hashCode => asset.localId.hashCode;

  @override
  String toString() => 'ImmichExternalImageProvider(${asset.fileName})';
}

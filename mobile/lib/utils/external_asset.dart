import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:isar/isar.dart';
import 'package:path/path.dart' as p;

/// Helper class to create temporary Asset objects from external files
/// These assets are not stored in the database and are used only for viewing
class ExternalAssetHelper {
  /// Creates a temporary Asset object from a URI (file:// or content://)
  /// This asset will have minimal metadata and is intended for view-only purposes
  static Future<Asset> createFromUri(String uri) async {
    dPrint(() => "[ExternalAssetHelper] Creating asset from URI: $uri");

    final parsedUri = Uri.parse(uri);
    String fileName = 'External File';
    AssetType type = AssetType.image;
    DateTime now = DateTime.now();

    try {
      if (parsedUri.scheme == 'file') {
        // Direct file path
        final filePath = parsedUri.path;
        final file = File(filePath);

        if (file.existsSync()) {
          fileName = p.basename(filePath);
          final extension = p.extension(fileName).toLowerCase();
          type = _isVideoExtension(extension) ? AssetType.video : AssetType.image;

          final stat = file.statSync();
          now = stat.modified;
        }
      } else if (parsedUri.scheme == 'content') {
        // Content URI - try to get filename and type from platform
        try {
          const platform = MethodChannel('app.alextran.immich/intent');
          final String? path = await platform.invokeMethod('getPathFromUri', {'uri': uri});

          if (path != null) {
            fileName = p.basename(path);
            final extension = p.extension(fileName).toLowerCase();
            type = _isVideoExtension(extension) ? AssetType.video : AssetType.image;
          }
        } catch (e) {
          dPrint(() => "[ExternalAssetHelper] Could not get path from content URI: $e");
        }
      }
    } catch (e) {
      dPrint(() => "[ExternalAssetHelper] Error processing URI: $e");
    }

    return Asset(
      id: Isar.autoIncrement, // Not stored in DB
      checksum: uri.hashCode.toString(), // Use URI hash as temporary checksum
      localId: 'external:$uri', // Store the full URI with external prefix
      ownerId: 0, // No owner for external files
      fileCreatedAt: now,
      fileModifiedAt: now,
      updatedAt: now,
      durationInSeconds: 0, // Unknown for external files
      type: type,
      fileName: fileName,
    );
  }

  /// Checks if the asset is an external asset (not from Immich library)
  static bool isExternalAsset(Asset? asset) {
    return asset?.localId?.startsWith('external:') ?? false;
  }

  /// Gets the URI from an external asset
  static String? getUri(Asset asset) {
    if (!isExternalAsset(asset)) {
      return null;
    }
    return asset.localId?.substring('external:'.length);
  }

  /// Gets the file path from an external asset (only for file:// URIs)
  static String? getFilePath(Asset asset) {
    final uri = getUri(asset);
    if (uri == null) return null;

    final parsedUri = Uri.parse(uri);
    if (parsedUri.scheme == 'file') {
      return parsedUri.path;
    }
    return null;
  }

  /// Reads bytes from a content URI using platform channel
  static Future<Uint8List?> readContentUriBytes(String uri) async {
    try {
      const platform = MethodChannel('app.alextran.immich/intent');
      final Uint8List? bytes = await platform.invokeMethod('readUriBytes', {'uri': uri});
      return bytes;
    } catch (e) {
      dPrint(() => "[ExternalAssetHelper] Error reading content URI bytes: $e");
      return null;
    }
  }

  /// Copies a content URI video to a temporary file for playback
  /// Returns the path to the temporary file, or null on error
  static Future<String?> copyContentUriToTempFile(String uri, String fileName) async {
    try {
      dPrint(() => "[ExternalAssetHelper] Copying content URI to temp file: $uri");

      // Read the bytes from the content URI
      final bytes = await readContentUriBytes(uri);
      if (bytes == null || bytes.isEmpty) {
        dPrint(() => "[ExternalAssetHelper] Failed to read bytes from content URI");
        return null;
      }

      // Create a temporary file
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/immich_external_${fileName}');

      // Write the bytes to the temp file
      await tempFile.writeAsBytes(bytes);
      dPrint(() => "[ExternalAssetHelper] Copied ${bytes.length} bytes to ${tempFile.path}");

      return tempFile.path;
    } catch (e) {
      dPrint(() => "[ExternalAssetHelper] Error copying content URI to temp file: $e");
      return null;
    }
  }

  /// Gets the aspect ratio from a video file
  /// Returns the aspect ratio (width/height) or null on error
  static Future<double?> getVideoAspectRatio(String uri) async {
    try {
      const platform = MethodChannel('app.alextran.immich/intent');
      final Map<dynamic, dynamic>? metadata = await platform.invokeMethod('getVideoMetadata', {'uri': uri});

      if (metadata != null) {
        final width = metadata['width'] as int?;
        final height = metadata['height'] as int?;

        if (width != null && height != null && height > 0) {
          final aspectRatio = width / height;
          dPrint(() => "[ExternalAssetHelper] Video aspect ratio: $aspectRatio (${width}x${height})");
          return aspectRatio;
        }
      }

      dPrint(() => "[ExternalAssetHelper] Could not get video metadata from URI");
      return null;
    } catch (e) {
      dPrint(() => "[ExternalAssetHelper] Error getting video aspect ratio: $e");
      return null;
    }
  }

  /// Determines if a file extension represents a video
  static bool _isVideoExtension(String extension) {
    const videoExtensions = [
      '.mp4',
      '.mov',
      '.avi',
      '.mkv',
      '.webm',
      '.m4v',
      '.3gp',
      '.flv',
      '.wmv',
    ];
    return videoExtensions.contains(extension);
  }
}

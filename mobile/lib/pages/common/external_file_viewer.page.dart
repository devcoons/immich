import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:path/path.dart' as p;

@RoutePage()
class ExternalFileViewerPage extends HookConsumerWidget {
  final String uri;

  const ExternalFileViewerPage({
    super.key,
    required this.uri,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsedUri = Uri.parse(uri);
    final isLoading = useState(true);
    final error = useState<String?>(null);
    final filePath = useState<String?>(null);
    final isVideo = useState(false);
    final imageBytes = useState<Uint8List?>(null);
    final decodedImage = useState<ui.Image?>(null);

    useEffect(() {
      dPrint(() => "[ExternalFileViewer] useEffect triggered for URI: $uri");
      bool isMounted = true;

      Future<void> loadFile() async {
        try {
          String? path;
          Uint8List? bytes;

          // Decode the URI in case it's double-encoded
          String decodedUriString = Uri.decodeComponent(uri);
          dPrint(() => "[ExternalFileViewer] Original URI: $uri");
          dPrint(() => "[ExternalFileViewer] Decoded URI: $decodedUriString");

          final decodedUri = Uri.parse(decodedUriString);

          if (decodedUri.scheme == 'file') {
            // Direct file path
            path = decodedUri.path;
            dPrint(() => "[ExternalFileViewer] Using file path: $path");
          } else if (parsedUri.scheme == 'file') {
            // Fallback to original URI if decoding didn't help
            path = parsedUri.path;
            dPrint(() => "[ExternalFileViewer] Using original file path: $path");
          } else if (parsedUri.scheme == 'content') {
            // Content URI - needs to be resolved and read via platform channel
            const platform = MethodChannel('app.alextran.immich/intent');
            try {
              dPrint(() => "[ExternalFileViewer] Reading content URI bytes: $uri");
              // Get the bytes directly from content URI
              bytes = await platform.invokeMethod('readUriBytes', {'uri': uri});
              dPrint(() => "[ExternalFileViewer] Read ${bytes?.length ?? 0} bytes from content URI");

              if (bytes != null && bytes.isNotEmpty) {
                if (!isMounted) return;
                imageBytes.value = bytes;

                // Decode the image immediately to avoid issues with widget rebuilds
                dPrint(() => "[ExternalFileViewer] Decoding image from ${bytes?.length ?? 0} bytes");
                try {
                  final codec = await ui.instantiateImageCodec(bytes);
                  final frame = await codec.getNextFrame();
                  if (!isMounted) {
                    dPrint(() => "[ExternalFileViewer] Widget unmounted during decode, skipping");
                    return;
                  }
                  decodedImage.value = frame.image;
                  dPrint(() => "[ExternalFileViewer] Image decoded successfully: ${frame.image.width}x${frame.image.height}");
                } catch (e) {
                  dPrint(() => "[ExternalFileViewer] Failed to decode image: $e");
                  if (isMounted) {
                    error.value = "Failed to decode image: $e";
                    isLoading.value = false;
                  }
                  return;
                }

                // Still try to get the path for extension detection
                try {
                  path = await platform.invokeMethod('getPathFromUri', {'uri': uri});
                  dPrint(() => "[ExternalFileViewer] Also got path: $path");
                  if (path != null) {
                    filePath.value = path;
                  } else {
                    filePath.value = "content_uri_image";
                  }
                } catch (e) {
                  dPrint(() => "[ExternalFileViewer] Could not get path, but have decoded image: $e");
                  // We have decoded image, so we can still display it
                  filePath.value = "content_uri_image";
                }
              } else {
                error.value = "Unable to read file from content URI";
                isLoading.value = false;
                return;
              }
            } catch (e) {
              dPrint(() => "[ExternalFileViewer] Failed to read content URI: $e");
              error.value = "Unable to access file: $e";
              isLoading.value = false;
              return;
            }
          }

          if (path != null && bytes == null) {
            final file = File(path);
            dPrint(() => "[ExternalFileViewer] Checking if file exists at: $path");
            if (!file.existsSync()) {
              dPrint(() => "[ExternalFileViewer] ERROR: File does not exist at path: $path");
              error.value = "File not found at: $path";
              isLoading.value = false;
              return;
            }

            dPrint(() => "[ExternalFileViewer] File exists! Size: ${file.lengthSync()} bytes");

            // Read the bytes to ensure we can display it
            try {
              bytes = await file.readAsBytes();
              imageBytes.value = bytes;
              dPrint(() => "[ExternalFileViewer] Read ${bytes?.length ?? 0} bytes from file");
            } catch (e) {
              dPrint(() => "[ExternalFileViewer] ERROR reading file bytes: $e");
              error.value = "Unable to read file: $e";
              isLoading.value = false;
              return;
            }

            // Check if it's a video based on extension
            final extension = p.extension(path).toLowerCase();
            isVideo.value = ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'].contains(extension);

            dPrint(() => "[ExternalFileViewer] File extension: $extension, isVideo: ${isVideo.value}");

            filePath.value = path;
            dPrint(() => "[ExternalFileViewer] Set filePath to: $path");
          } else if (bytes != null && path == null) {
            // We have bytes from content URI but no path
            filePath.value = "content_uri_image";
            dPrint(() => "[ExternalFileViewer] Using bytes from content URI");
          } else if (path == null && bytes == null) {
            dPrint(() => "[ExternalFileViewer] ERROR: No path or bytes available");
            error.value = "Unable to resolve file";
          }
        } catch (e) {
          dPrint(() => "[ExternalFileViewer] ERROR: $e");
          if (isMounted) {
            error.value = "Error loading file: $e";
          }
        } finally {
          if (isMounted) {
            isLoading.value = false;
            dPrint(() => "[ExternalFileViewer] Loading complete. isLoading: false, error: ${error.value}, filePath: ${filePath.value}, hasBytes: ${imageBytes.value != null}");
          }
        }
      }

      loadFile();
      return () {
        dPrint(() => "[ExternalFileViewer] useEffect cleanup/disposal called");
        isMounted = false;
      };
    }, [uri]);

    dPrint(() => "[ExternalFileViewer] Build - isLoading: ${isLoading.value}, error: ${error.value}, filePath: ${filePath.value}");

    if (isLoading.value) {
      dPrint(() => "[ExternalFileViewer] Rendering loading indicator");
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (error.value != null) {
      dPrint(() => "[ExternalFileViewer] Rendering error: ${error.value}");
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.white,
                  size: 64,
                ),
                const SizedBox(height: 16),
                Text(
                  error.value!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final path = filePath.value;
    if (path == null) {
      dPrint(() => "[ExternalFileViewer] Rendering 'No file to display'");
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Text(
            'No file to display',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    // For videos, show a message that videos are not yet supported
    if (isVideo.value) {
      dPrint(() => "[ExternalFileViewer] Rendering video not supported message for: $path");
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.videocam_off,
                color: Colors.white,
                size: 64,
              ),
              const SizedBox(height: 16),
              const Text(
                'Video playback from external sources\nis not yet supported',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                path,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // For images, use InteractiveViewer with Image
    dPrint(() => "[ExternalFileViewer] Rendering image viewer for: $path");

    final decoded = decodedImage.value;
    final bytes = imageBytes.value;
    Widget imageWidget;

    if (decoded != null) {
      // Use RawImage with the pre-decoded image to avoid decode issues during rebuilds
      dPrint(() => "[ExternalFileViewer] Using RawImage with decoded image ${decoded.width}x${decoded.height}");
      try {
        imageWidget = RawImage(
          image: decoded,
          fit: BoxFit.contain,
        );
      } catch (e) {
        dPrint(() => "[ExternalFileViewer] ERROR creating RawImage widget: $e");
        // Fallback to error display
        imageWidget = Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.broken_image, size: 64, color: Colors.white),
              const SizedBox(height: 16),
              Text(
                'Failed to display image:\n$e',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      }
    } else if (bytes != null) {
      dPrint(() => "[ExternalFileViewer] Using Image.memory with ${bytes.length} bytes");
      imageWidget = Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          dPrint(() => "[ExternalFileViewer] frameBuilder called - frame: $frame, wasSynchronouslyLoaded: $wasSynchronouslyLoaded");
          if (frame == null) {
            dPrint(() => "[ExternalFileViewer] Image.memory is loading (frame is null)");
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          dPrint(() => "[ExternalFileViewer] Image.memory frame loaded successfully: frame=$frame");
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          dPrint(() => "[ExternalFileViewer] ERROR loading Image.memory: $error");
          dPrint(() => "[ExternalFileViewer] Stack trace: $stackTrace");
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.broken_image, size: 64, color: Colors.white),
                const SizedBox(height: 16),
                Text(
                  'Failed to load image:\n$error',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        },
      );
    } else {
      dPrint(() => "[ExternalFileViewer] Using Image.file for path: $path");
      imageWidget = Image.file(
        File(path),
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == null) {
            dPrint(() => "[ExternalFileViewer] Image.file is loading (frame: $frame)");
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          dPrint(() => "[ExternalFileViewer] Image.file frame loaded: $frame");
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          dPrint(() => "[ExternalFileViewer] ERROR loading Image.file: $error");
          dPrint(() => "[ExternalFileViewer] Stack trace: $stackTrace");
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.broken_image, size: 64, color: Colors.white),
                const SizedBox(height: 16),
                Text(
                  'Failed to load image:\n$error',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        },
      );
    }

    try {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black87,
          foregroundColor: Colors.white,
          title: const Text('External Image'),
        ),
        body: SafeArea(
          child: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: imageWidget,
            ),
          ),
        ),
      );
    } catch (e) {
      dPrint(() => "[ExternalFileViewer] ERROR building scaffold: $e");
      // Ultimate fallback - show a basic error screen
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black87,
          foregroundColor: Colors.white,
          title: const Text('External Image'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.white),
              const SizedBox(height: 16),
              Text(
                'Error displaying image:\n$e',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
  }
}

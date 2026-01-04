import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:native_video_player/native_video_player.dart';
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

                // First, try to get the path to determine file type
                try {
                  path = await platform.invokeMethod('getPathFromUri', {'uri': uri});
                  dPrint(() => "[ExternalFileViewer] Got path from content URI: $path");

                  // Check if it's a video based on extension
                  if (path != null) {
                    final extension = p.extension(path).toLowerCase();
                    if (['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'].contains(extension)) {
                      dPrint(() => "[ExternalFileViewer] Detected video file: $extension");
                      isVideo.value = true;
                      filePath.value = path;
                      if (isMounted) {
                        isLoading.value = false;
                      }
                      return; // Skip image decoding for videos
                    }
                  }
                } catch (e) {
                  dPrint(() => "[ExternalFileViewer] Could not get path from content URI: $e");
                  // Continue with image decode attempt
                }

                // Decode as image (only if not a video)
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

                  // Set the file path if we have it
                  if (path != null) {
                    filePath.value = path;
                  } else {
                    filePath.value = "content_uri_image";
                  }
                } catch (e) {
                  dPrint(() => "[ExternalFileViewer] Failed to decode image: $e");
                  if (isMounted) {
                    error.value = "Failed to decode image: $e";
                    isLoading.value = false;
                  }
                  return;
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

            // Check if it's a video based on extension FIRST to avoid reading video bytes
            final extension = p.extension(path).toLowerCase();
            isVideo.value = ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v'].contains(extension);

            dPrint(() => "[ExternalFileViewer] File extension: $extension, isVideo: ${isVideo.value}");
            filePath.value = path;

            // Only read bytes for images, not videos
            if (!isVideo.value) {
              dPrint(() => "[ExternalFileViewer] File exists! Size: ${file.lengthSync()} bytes");

              // Read the bytes for image display
              try {
                bytes = await file.readAsBytes();
                if (!isMounted) return;
                imageBytes.value = bytes;
                dPrint(() => "[ExternalFileViewer] Read ${bytes?.length ?? 0} bytes from file");

                // Pre-decode image for better performance
                try {
                  final codec = await ui.instantiateImageCodec(bytes);
                  final frame = await codec.getNextFrame();
                  if (!isMounted) return;
                  decodedImage.value = frame.image;
                  dPrint(() => "[ExternalFileViewer] Image decoded successfully: ${frame.image.width}x${frame.image.height}");
                } catch (e) {
                  dPrint(() => "[ExternalFileViewer] Failed to pre-decode image: $e");
                  // Continue anyway, will use Image.memory fallback
                }
              } catch (e) {
                dPrint(() => "[ExternalFileViewer] ERROR reading file bytes: $e");
                error.value = "Unable to read file: $e";
                isLoading.value = false;
                return;
              }
            } else {
              dPrint(() => "[ExternalFileViewer] Skipping byte read for video file");
            }

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

    // For videos, use native video player
    if (isVideo.value) {
      dPrint(() => "[ExternalFileViewer] Rendering video player for: $path");
      return _ExternalVideoPlayer(
        filePath: path,
        fileBytes: imageBytes.value,
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

// Simple video player for external files
class _ExternalVideoPlayer extends HookWidget {
  final String filePath;
  final Uint8List? fileBytes;

  const _ExternalVideoPlayer({
    required this.filePath,
    this.fileBytes,
  });

  @override
  Widget build(BuildContext context) {
    final controller = useState<NativeVideoPlayerController?>(null);
    final isReady = useState(false);
    final error = useState<String?>(null);
    final videoInfo = useState<VideoInfo?>(null);
    final isPlaying = useState(false);
    final showControls = useState(false);
    final isMounted = useRef(true);

    useEffect(() {
      dPrint(() => "[ExternalVideoPlayer] Initializing video player for: $filePath");
      isMounted.value = true;

      return () {
        dPrint(() => "[ExternalVideoPlayer] Cleaning up video player");
        isMounted.value = false;
        final ctrl = controller.value;
        if (ctrl != null) {
          try {
            ctrl.stop();
            ctrl.dispose();
          } catch (e) {
            dPrint(() => "[ExternalVideoPlayer] Error during cleanup: $e");
          }
        }
      };
    }, [filePath]);

    void initController(NativeVideoPlayerController nc) async {
      if (controller.value != null || !isMounted.value) {
        return;
      }

      dPrint(() => "[ExternalVideoPlayer] Controller ready, loading video");

      try {
        VideoSource source;

        if (filePath == "content_uri_image" || filePath.startsWith("content://")) {
          if (isMounted.value) {
            error.value = "Cannot play video from content URI";
          }
          return;
        }

        source = await VideoSource.init(
          path: filePath,
          type: VideoSourceType.file,
        );

        void onPlaybackReady() {
          if (!isMounted.value) return;
          dPrint(() => "[ExternalVideoPlayer] Video playback ready");
          final info = nc.videoInfo;
          if (info != null) {
            videoInfo.value = info;
            dPrint(() => "[ExternalVideoPlayer] Video size: ${info.width}x${info.height}");
          }
          isReady.value = true;
          nc.play().catchError((e) {
            dPrint(() => "[ExternalVideoPlayer] Error auto-playing video: $e");
          });
          isPlaying.value = true;
        }

        void onPlaybackStatusChanged() {
          if (!isMounted.value) return;
          final playbackInfo = nc.playbackInfo;
          if (playbackInfo != null) {
            isPlaying.value = playbackInfo.status == PlaybackStatus.playing;
          }
        }

        void onError() {
          if (!isMounted.value) return;
          dPrint(() => "[ExternalVideoPlayer] Video playback error");
          error.value = "Video playback error";
        }

        nc.onPlaybackReady.addListener(onPlaybackReady);
        nc.onPlaybackStatusChanged.addListener(onPlaybackStatusChanged);
        nc.onError.addListener(onError);

        await nc.loadVideoSource(source);

        if (!isMounted.value) {
          nc.stop();
          nc.dispose();
          return;
        }

        controller.value = nc;
        dPrint(() => "[ExternalVideoPlayer] Video loaded successfully");
      } catch (e) {
        dPrint(() => "[ExternalVideoPlayer] Error loading video: $e");
        if (isMounted.value) {
          error.value = "Failed to load video: $e";
        }
      }
    }

    if (error.value != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('External Video'),
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

    final info = videoInfo.value;
    final aspectRatio = info != null && info.width > 0 && info.height > 0
        ? info.width / info.height
        : 16 / 9; // Default aspect ratio

    void togglePlayPause() async {
      final ctrl = controller.value;
      if (ctrl == null || !isMounted.value) return;

      try {
        if (isPlaying.value) {
          await ctrl.pause();
        } else {
          await ctrl.play();
        }
      } catch (e) {
        dPrint(() => "[ExternalVideoPlayer] Error toggling play/pause: $e");
      }
    }

    void restart() async {
      final ctrl = controller.value;
      if (ctrl == null || !isMounted.value) return;

      try {
        await ctrl.seekTo(0);
        await ctrl.play();
      } catch (e) {
        dPrint(() => "[ExternalVideoPlayer] Error restarting video: $e");
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: const Text('External Video'),
      ),
      body: SafeArea(
        child: Center(
                   child: GestureDetector(
            onTap: () {
              dPrint(() => "[ExternalVideoPlayer] Video tapped, toggling controls from ${showControls.value} to ${!showControls.value}");
              showControls.value = !showControls.value;
            },
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Video player with proper aspect ratio
              AspectRatio(
                aspectRatio: aspectRatio,
                child: NativeVideoPlayerView(
                  onViewReady: initController,
                ),
              ),
              // Tap detector overlay (invisible, captures taps)
     
              // Loading indicator
              if (!isReady.value)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              // Video controls overlay - positioned at bottom
              if (isReady.value && showControls.value)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: false,
                    child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.8),
                              Colors.black.withOpacity(0.6),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Restart button
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.replay, size: 32),
                                color: Colors.white,
                                onPressed: restart,
                                tooltip: 'Restart',
                              ),
                            ),
                            const SizedBox(width: 24),
                            // Play/Pause button
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: Icon(
                                  isPlaying.value ? Icons.pause : Icons.play_arrow,
                                  size: 40,
                                ),
                                color: Colors.white,
                                onPressed: togglePlayPause,
                                tooltip: isPlaying.value ? 'Pause' : 'Play',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

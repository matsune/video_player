import 'package:flutter/material.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player/configurations/configurations.dart';
import 'package:video_player/controller/controller.dart';
import 'package:video_player/platform/platform.dart';

abstract class VideoPlayerPlatform extends PlatformInterface {
  /// Constructs a VideoPlayerPlatform.
  VideoPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoPlayerPlatform _instance = MethodChannelVideoPlayer()..init();

  /// The default instance of [VideoPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoPlayer].
  static VideoPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoPlayerPlatform] when
  /// they register themselves.
  static set instance(VideoPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Initializes the platform interface and disposes all existing players.
  ///
  /// This method is called when the plugin is first initialized
  /// and on every full restart.
  Future<void> init() =>
      throw UnimplementedError('init() has not been implemented.');

  /// Clears one video.
  Future<void> dispose(int? textureId) =>
      throw UnimplementedError('dispose() has not been implemented.');

  /// Creates an instance of a video player and returns its textureId.
  Future<int?> create(
          VideoPlayerBufferingConfiguration bufferingConfiguration) =>
      throw UnimplementedError('create() has not been implemented.');

  /// Returns a Stream of [PlatformEventType]s.
  Stream<PlatformEvent> eventStreamFor(int? textureId) =>
      throw UnimplementedError('eventStreamFor() has not been implemented.');

  /// Returns a widget displaying the video with a given textureID.
  Widget buildView(int? textureId, bool isFullscreen) =>
      throw UnimplementedError('buildView() has not been implemented.');

  Future<void> setDataSource(
          int? textureId, VideoPlayerDataSource dataSource) =>
      throw UnimplementedError('setDataSource() has not been implemented.');

  Future<void> setAutoLoop(int? textureId, bool autoLoop) =>
      throw UnimplementedError('setAutoLoop() has not been implemented.');

  Future<void> play(int? textureId) =>
      throw UnimplementedError('play() has not been implemented.');

  Future<void> pause(int? textureId) =>
      throw UnimplementedError('pause() has not been implemented.');

  /// Sets the video position to a [Duration] from the start.
  Future<void> seekTo(int? textureId, Duration position) =>
      throw UnimplementedError('seekTo() has not been implemented.');

  Future<void> willExitFullscreen(int? textureId) => throw UnimplementedError(
      'willExitFullscreen() has not been implemented.');

  Future<bool> isPictureInPictureSupported() => throw UnimplementedError(
      'isPictureInPictureSupported() has not been implemented.');

  Future<void> enablePictureInPicture(int? textureId) =>
      throw UnimplementedError(
          'enablePictureInPicture() has not been implemented.');

  Future<void> disablePictureInPicture(int? textureId) =>
      throw UnimplementedError(
          'disablePictureInPicture() has not been implemented.');

  Future<void> setMuted(int? textureId, bool muted) =>
      throw UnimplementedError('setMuted() has not been implemented.');

  Future<void> setPlaybackRate(int? textureId, double rate) =>
      throw UnimplementedError('setPlaybackRate() has not been implemented.');

  /// Sets the video track parameters (used to select quality of the video)
  Future<void> setTrackParameters(
      int? textureId, int? width, int? height, int? bitrate) {
    throw UnimplementedError('setTrackParameters() has not been implemented.');
  }

  /// iOS only
  Future<void> selectLegibleMediaGroup(int? textureId, int? index) {
    throw UnimplementedError(
        'selectLegibleMediaGroup() has not been implemented.');
  }

  /// Returns a Stream of [PlatformEventType]s.
  Stream<PlatformDownloadEvent> downloadEventStream() =>
      throw UnimplementedError(
          'downloadEventStreamFor() has not been implemented.');

  Future<void> downloadOfflineAsset({
    required String key,
    required String url,
    Map<String, String?>? headers,
  }) =>
      throw UnimplementedError(
          'downloadOfflineAsset() has not been implemented.');

  Future<void> pauseDownload(String key) =>
      throw UnimplementedError('pauseDownload() has not been implemented.');

  Future<void> resumeDownload(String key) =>
      throw UnimplementedError('resumeDownload() has not been implemented.');

  Future<void> cancelDownload(String key) =>
      throw UnimplementedError('cancelDownload() has not been implemented.');

  Future<void> deleteOfflineAsset(String key) => throw UnimplementedError(
      'deleteOfflineAsset() has not been implemented.');

  Future<List<Download>> getDownloads() =>
      throw UnimplementedError('getDownloads() has not been implemented.');

  Future<void> shrink(int? textureId) =>
      throw UnimplementedError('shrink() has not been implemented.');

  Future<void> expand(int? textureId) =>
      throw UnimplementedError('expand() has not been implemented.');

  Future<double> getCurrentVideoResolution(int? textureId) =>
      throw UnimplementedError('getCurrentVideoResolution() has not been implemented.');

  Future<double> getCurrentVideoFrameRate(int? textureId) =>
      throw UnimplementedError('getCurrentVideoFrameRate() has not been implemented.');
}

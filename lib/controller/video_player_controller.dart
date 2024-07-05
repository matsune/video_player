import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/abr/abr.dart';
import 'package:video_player/configurations/configurations.dart';
import 'package:video_player/controls/controls_event.dart';
import 'package:video_player/platform/platform.dart';
import 'package:video_player/subtitles/subtitles.dart';
import 'package:video_player/utils.dart';

import 'video_player_data_source.dart';
import 'video_player_tracks_controller.dart';
import 'video_player_value.dart';

class VideoPlayerControllerProvider extends InheritedWidget {
  const VideoPlayerControllerProvider({
    Key? key,
    required this.controller,
    required Widget child,
  }) : super(key: key, child: child);

  final VideoPlayerController controller;

  @override
  bool updateShouldNotify(VideoPlayerControllerProvider oldWidget) =>
      controller != oldWidget.controller;
}

class VideoPlayerController extends ValueNotifier<VideoPlayerValue> {
  VideoPlayerController({
    required this.configuration,
    VideoPlayerDataSource? dataSource,
    this.initialPlayBackSpeedRate = 1.0,
  }) : super(VideoPlayerValue()) {
    _create();
    if (dataSource != null) _setDataSource(dataSource);
  }

  final VideoPlayerConfiguration configuration;
  VideoPlayerBufferingConfiguration bufferingConfiguration =
      const VideoPlayerBufferingConfiguration();

  int? _textureId;

  int? get textureId => _textureId;

  StreamSubscription<PlatformEvent>? _eventSubscription;

  bool _isDisposed = false;

  late Completer<void> _initializeCompleter;

  final Completer<void> _createCompleter = Completer<void>();

  final double initialPlayBackSpeedRate;

  final VideoPlayerSubtitlesController subtitlesController =
      VideoPlayerSubtitlesController();

  final VideoPlayerTracksController tracksController =
      VideoPlayerTracksController();

  final StreamController<bool> controlsVisibilityStreamController =
      StreamController.broadcast();

  Stream<bool> get controlsVisibilityStream =>
      controlsVisibilityStreamController.stream;

  final StreamController<ControlsEvent> controlsEventStreamController =
      StreamController.broadcast();

  Stream<ControlsEvent> get controlsEventStream =>
      controlsEventStreamController.stream;

  static VideoPlayerController of(BuildContext context) {
    final videoPLayerControllerProvider = context
        .dependOnInheritedWidgetOfExactType<VideoPlayerControllerProvider>()!;
    return videoPLayerControllerProvider.controller;
  }

  Future<void> selectLegibleMediaGroup() async {
    if (Platform.isIOS) {
      if (value.isPip) {
        await VideoPlayerPlatform.instance.selectLegibleMediaGroup(
          textureId,
          subtitlesController.selectedSubtitlesSourceIndex,
        );
      } else {
        await VideoPlayerPlatform.instance.selectLegibleMediaGroup(
          textureId,
          null,
        );
      }
    }
  }

  Future<void> _create() async {
    _textureId =
        await VideoPlayerPlatform.instance.create(bufferingConfiguration);
    tracksController.textureId = _textureId;
    setPlaybackRate(initialPlayBackSpeedRate);
    _createCompleter.complete(null);

    void eventListener(PlatformEvent event) {
      if (_isDisposed) {
        return;
      }
      switch (event.eventType) {
        case PlatformEventType.initialized:
          value = value.copyWith(
            eventType: VideoPlayerEventType.initialized,
            duration: event.duration,
            size: event.size,
          );
          _initializeCompleter.complete(null);
          break;
        case PlatformEventType.isPlayingChanged:
          value = value.copyWith(
            eventType: VideoPlayerEventType.isPlayingChanged,
            isPlaying: event.isPlaying,
          );
          break;
        case PlatformEventType.positionChanged:
          value = value.copyWith(
            eventType: VideoPlayerEventType.positionChanged,
            position: event.position,
          );
          break;
        case PlatformEventType.bufferChanged:
          value = value.copyWith(
            eventType: VideoPlayerEventType.bufferChanged,
            buffered: event.buffered,
          );
          break;
        case PlatformEventType.pipChanged:
          value = value.copyWith(
            eventType: VideoPlayerEventType.pipChanged,
            isPip: event.isPip,
          );
          if (Platform.isIOS) {
            selectLegibleMediaGroup();
          }
          break;
        case PlatformEventType.muteChanged:
          value = value.copyWith(
            eventType: VideoPlayerEventType.muteChanged,
            isMuted: event.isMuted,
          );
          break;
        case PlatformEventType.ended:
          value = value.copyWith(
            eventType: VideoPlayerEventType.ended,
          );
          exitFullscreen();
          break;
        default:
          break;
      }
    }

    void errorListener(Object object) {
      if (object is PlatformException) {
        final PlatformException e = object;
        value = value.copyWith(
          eventType: VideoPlayerEventType.error,
          errorDescription: e.message,
        );
      } else {
        value = value.copyWith(
          eventType: VideoPlayerEventType.error,
          errorDescription: object.toString(),
        );
      }
      if (!_initializeCompleter.isCompleted) {
        _initializeCompleter.completeError(object);
      }
    }

    _eventSubscription = VideoPlayerPlatform.instance
        .eventStreamFor(textureId)
        .listen(eventListener, onError: errorListener);
  }

  @override
  void dispose() async {
    await _createCompleter.future;
    if (!_isDisposed) {
      _isDisposed = true;
      await _eventSubscription?.cancel();
      await VideoPlayerPlatform.instance.dispose(textureId);
    }
    super.dispose();
  }

  /// Set data source for playing a video from obtained from
  /// the network.
  Future<void> setNetworkDataSource(
    String url, {
    Duration? startPosition,
    List<VideoPlayerSubtitlesSource>? subtitles,
    Map<String, String?>? headers,
    VideoPlayerNotificationConfiguration? notificationConfiguration,
    bool disableRemoteControl = false,
  }) {
    return _setDataSource(
      VideoPlayerDataSource(
        sourceType: VideoPlayerDataSourceType.network,
        url: url,
        startPosition: startPosition,
        subtitles: subtitles,
        headers: headers,
        notificationConfiguration: notificationConfiguration,
        disableRemoteControl: disableRemoteControl,
      ),
    );
  }

  Future<void> setOfflineDataSource(
    String offlineKey, {
    Duration? startPosition,
    List<VideoPlayerSubtitlesSource>? subtitles,
    Map<String, String?>? headers,
    VideoPlayerNotificationConfiguration? notificationConfiguration,
  }) {
    return _setDataSource(
      VideoPlayerDataSource(
        sourceType: VideoPlayerDataSourceType.offline,
        offlineKey: offlineKey,
        startPosition: startPosition,
        subtitles: subtitles,
        headers: headers,
        notificationConfiguration: notificationConfiguration,
      ),
    );
  }

  Future<void> _setDataSource(VideoPlayerDataSource dataSource) async {
    if (_isDisposed) {
      return;
    }
    bufferingConfiguration = dataSource.bufferingConfiguration;
    value = VideoPlayerValue();
    if (!_createCompleter.isCompleted) await _createCompleter.future;
    _initializeCompleter = Completer<void>();

    await VideoPlayerPlatform.instance.setDataSource(textureId, dataSource);

    tracksController.reset();
    subtitlesController.reset();

    if (dataSource.sourceType == VideoPlayerDataSourceType.network) {
      if (Utils.isDataSourceHls(dataSource.url)) {
        _loadAbrManifest(dataSource);
      }
    }

    await _initializeCompleter.future;
    await VideoPlayerPlatform.instance.setAutoLoop(
      textureId,
      configuration.autoLoop,
    );
    if (configuration.autoFullscreen) {
      enterFullscreen();
    }
    if (configuration.autoPlay) {
      play();
    }
    if (dataSource.startPosition != null) {
      await seekTo(dataSource.startPosition);
    }
    return;
  }

  Future<void> _loadAbrManifest(VideoPlayerDataSource dataSource) async {
    final data = await Utils.getDataFromUrl(
      dataSource.url!,
      dataSource.headers,
    );
    if (data == null) return;

    final abrData = await AbrDataHolder.parse(dataSource.url!, data);

    tracksController.setTracksList(abrData.tracks ?? []);
    if (dataSource.subtitles != null) {
      subtitlesController.setSubtitlesSourceList(dataSource.subtitles ?? []);
    } else {
      subtitlesController.setAbrSubtitlesSourceList(abrData.subtitles ?? []);
    }
    subtitlesController.selectDefaultSource();

    if (subtitlesController.isSelectedNone) return;

    if (subtitlesController.selectedSubtitlesSource?.asmsIsSegmented == true) {
      return;
    }
    subtitlesController.loadAllSubtitleLines();
  }

  Future<void> play() async {
    if (!value.initialized || _isDisposed || value.isPlaying) return;
    await VideoPlayerPlatform.instance.play(textureId);
  }

  Future<void> pause() async {
    if (!value.initialized || _isDisposed || !value.isPlaying) return;
    await VideoPlayerPlatform.instance.pause(textureId);
  }

  Future<void> seekTo(Duration? position) async {
    if (!value.initialized || _isDisposed || position == null) {
      return;
    }
    Duration? positionToSeek = position;
    if (position > value.duration!) {
      positionToSeek = value.duration;
    } else if (position < const Duration()) {
      positionToSeek = const Duration();
    }

    if (positionToSeek != null) {
      await VideoPlayerPlatform.instance.seekTo(textureId, positionToSeek);
    }
  }

  void enterFullscreen() {
    if (!value.initialized || _isDisposed || value.isFullscreen) return;
    value = value.copyWith(
      eventType: VideoPlayerEventType.fullscreenChanged,
      isFullscreen: true,
    );
  }

  void expand() {
    if (!value.initialized ||
        _isDisposed ||
        !value.isFullscreen ||
        value.isExpanded) return;
    VideoPlayerPlatform.instance.expand(_textureId);
    value = value.copyWith(
      eventType: VideoPlayerEventType.expandChanged,
      isExpanded: true,
    );
  }

  void shrink() {
    if (!value.initialized ||
        _isDisposed ||
        !value.isFullscreen ||
        !value.isExpanded) return;
    VideoPlayerPlatform.instance.shrink(_textureId);
    value = value.copyWith(
      eventType: VideoPlayerEventType.expandChanged,
      isExpanded: false,
    );
  }

  void exitFullscreen() {
    if (!value.initialized || _isDisposed || !value.isFullscreen) return;
    VideoPlayerPlatform.instance.willExitFullscreen(_textureId);
    value = value.copyWith(
      eventType: VideoPlayerEventType.fullscreenChanged,
      isFullscreen: false,
    );
  }

  Future<bool> isPictureInPictureSupported() =>
      VideoPlayerPlatform.instance.isPictureInPictureSupported();

  Future<void> enablePictureInPicture() async {
    final bool isPipSupported = await isPictureInPictureSupported();
    if (!isPipSupported) return;
    await VideoPlayerPlatform.instance.enablePictureInPicture(textureId);
    if (Platform.isAndroid) {
      enterFullscreen();
    }
  }

  Future<void> disablePictureInPicture() =>
      VideoPlayerPlatform.instance.disablePictureInPicture(textureId);

  Future<void> setMuted(bool muted) =>
      VideoPlayerPlatform.instance.setMuted(textureId, muted);

  Future<void> setPlaybackRate(double rate) {
    value = value.copyWith(playbackRate: rate);
    return VideoPlayerPlatform.instance.setPlaybackRate(textureId, rate);
  }
}

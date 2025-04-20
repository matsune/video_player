import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/configurations/configurations.dart';
import 'package:video_player/controller/controller.dart';
import 'package:video_player/platform/platform.dart';
import 'package:video_player/utils.dart';

/// An implementation of [VideoPlayerPlatform] that uses method channels.
class MethodChannelVideoPlayer extends VideoPlayerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('video_player');

  @override
  Future<void> init() => methodChannel.invokeMethod('init');

  @override
  Future<void> dispose(int? textureId) => methodChannel.invokeMethod(
        'dispose',
        <String, dynamic>{'textureId': textureId},
      );

  @override
  Future<int?> create(
      VideoPlayerBufferingConfiguration bufferingConfiguration) async {
    final response = await methodChannel.invokeMethod(
      'create',
      <String, dynamic>{
        'minBufferMs': bufferingConfiguration.minBufferMs,
        'maxBufferMs': bufferingConfiguration.maxBufferMs,
        'bufferForPlaybackMs': bufferingConfiguration.bufferForPlaybackMs,
        'bufferForPlaybackAfterRebufferMs':
            bufferingConfiguration.bufferForPlaybackAfterRebufferMs,
      },
    );
    final map = Map<String, dynamic>.from(response);
    return map["textureId"] as int?;
  }

  EventChannel _eventChannelFor(int? textureId) =>
      EventChannel('video_player_channel/videoEvents$textureId');

  @override
  Stream<PlatformEvent> eventStreamFor(int? textureId) {
    return _eventChannelFor(textureId)
        .receiveBroadcastStream()
        .map((dynamic event) {
      late Map<dynamic, dynamic> map;
      if (event is Map) {
        map = event;
      }
      final eventType = platformEventTypeFromString(map["event"] as String);
      switch (eventType) {
        case PlatformEventType.initialized:
          double width = 0;
          double height = 0;

          try {
            if (map.containsKey("width")) {
              final num widthNum = map["width"] as num;
              width = widthNum.toDouble();
            }
            if (map.containsKey("height")) {
              final num heightNum = map["height"] as num;
              height = heightNum.toDouble();
            }
          } catch (exception) {
            Utils.log(exception.toString());
          }

          final Size size = Size(width, height);

          return PlatformEvent(
            eventType: eventType,
            duration: Duration(milliseconds: map['duration'] as int),
            size: size,
          );
        case PlatformEventType.isPlayingChanged:
          return PlatformEvent(
            eventType: eventType,
            isPlaying: map["isPlaying"] as bool,
          );
        case PlatformEventType.positionChanged:
          return PlatformEvent(
            eventType: eventType,
            position: Duration(milliseconds: map["position"] as int),
          );
        case PlatformEventType.bufferChanged:
          final values = map['bufferRange'] as List;
          return PlatformEvent(
            eventType: eventType,
            buffered: DurationRange(
              Duration(milliseconds: values[0]),
              Duration(milliseconds: values[1]),
            ),
          );
        case PlatformEventType.pipChanged:
          final isPip = map['isPip'] as bool;
          return PlatformEvent(
            eventType: eventType,
            isPip: isPip,
          );
        case PlatformEventType.muteChanged:
          final isMuted = map['isMuted'] as bool;
          return PlatformEvent(
            eventType: eventType,
            isMuted: isMuted,
          );
        case PlatformEventType.ended:
          return PlatformEvent(eventType: eventType);
        case PlatformEventType.error:
          throw PlayerException(
            errorDescription: map['error'] as String,
            invalid: map['invalid'] as bool? ?? false,
            code: map['code'] as int?,
          );
        case PlatformEventType.unknown:
          throw "Unknown event type";
      }
    });
  }

  @override
  Widget buildView(int? textureId, bool isFullscreen) {
    const viewType = "matsune.video_player/VideoPlayerView";
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        creationParamsCodec: const StandardMessageCodec(),
        creationParams: {'textureId': textureId!, 'isFullscreen': isFullscreen},
      );
    } else {
      final Map<String, dynamic> creationParams = <String, dynamic>{
        "textureId": textureId
      };
      return Texture(textureId: textureId!);
    }
  }

  Map<String, dynamic> getDataSourceDescription(
      VideoPlayerDataSource dataSource) {
    switch (dataSource.sourceType) {
      case VideoPlayerDataSourceType.network:
        return {
          'url': dataSource.url,
          'headers': dataSource.headers,
          'subtitles': dataSource.subtitles
              ?.map(
                (subtitle) => {
                  'name': subtitle.name,
                  'url': subtitle.urls?.first,
                },
              )
              .toList(),
          'title': dataSource.notificationConfiguration?.title,
          'author': dataSource.notificationConfiguration?.author,
          'imageUrl': dataSource.notificationConfiguration?.imageUrl,
          'notificationChannelName':
              dataSource.notificationConfiguration?.notificationChannelName,
          'activityName': dataSource.notificationConfiguration?.activityName,
          'disableRemoteControl': dataSource.disableRemoteControl,
        };
      case VideoPlayerDataSourceType.offline:
        return {
          'offlineKey': dataSource.offlineKey,
          'title': dataSource.notificationConfiguration?.title,
          'author': dataSource.notificationConfiguration?.author,
          'imageUrl': dataSource.notificationConfiguration?.imageUrl,
          'notificationChannelName':
              dataSource.notificationConfiguration?.notificationChannelName,
          'activityName': dataSource.notificationConfiguration?.activityName,
        };
    }
  }

  @override
  Future<void> setDataSource(
      int? textureId, VideoPlayerDataSource dataSource) async {
    final dataSourceDescription = getDataSourceDescription(dataSource);
    await methodChannel.invokeMethod<void>(
      'setDataSource',
      <String, dynamic>{
        'textureId': textureId,
        'dataSource': dataSourceDescription,
      },
    );
    return;
  }

  @override
  Future<void> setAutoLoop(int? textureId, bool autoLoop) =>
      methodChannel.invokeMethod(
        'setAutoLoop',
        <String, dynamic>{
          'textureId': textureId,
          'autoLoop': autoLoop,
        },
      );

  @override
  Future<void> play(int? textureId) => methodChannel.invokeMethod(
        'play',
        <String, dynamic>{'textureId': textureId},
      );

  @override
  Future<void> pause(int? textureId) => methodChannel.invokeMethod(
        'pause',
        <String, dynamic>{'textureId': textureId},
      );

  @override
  Future<void> seekTo(int? textureId, Duration position) {
    return methodChannel.invokeMethod<void>(
      'seekTo',
      <String, dynamic>{
        'textureId': textureId,
        'position': position.inMilliseconds,
      },
    );
  }

  @override
  Future<void> willExitFullscreen(int? textureId) {
    return methodChannel.invokeMethod<void>(
      'willExitFullscreen',
      <String, dynamic>{
        'textureId': textureId,
      },
    );
  }

  @override
  Future<bool> isPictureInPictureSupported() async {
    final response =
        await methodChannel.invokeMethod('isPictureInPictureSupported');
    final map = Map<String, dynamic>.from(response);
    return map["isPictureInPictureSupported"] as bool;
  }

  @override
  Future<void> enablePictureInPicture(int? textureId) {
    return methodChannel.invokeMethod<void>(
      'enablePictureInPicture',
      <String, dynamic>{
        'textureId': textureId,
      },
    );
  }

  @override
  Future<void> disablePictureInPicture(int? textureId) {
    return methodChannel.invokeMethod<void>(
      'disablePictureInPicture',
      <String, dynamic>{
        'textureId': textureId,
      },
    );
  }

  @override
  Future<void> setMuted(int? textureId, bool muted) {
    return methodChannel.invokeMethod<void>(
      'setMuted',
      <String, dynamic>{
        'textureId': textureId,
        'muted': muted,
      },
    );
  }

  @override
  Future<void> setPlaybackRate(int? textureId, double rate) {
    return methodChannel.invokeMethod<void>(
      'setPlaybackRate',
      <String, dynamic>{
        'textureId': textureId,
        'rate': rate,
      },
    );
  }

  @override
  Future<void> setTrackParameters(
      int? textureId, int? width, int? height, int? bitrate) {
    return methodChannel.invokeMethod<void>(
      'setTrackParameters',
      <String, dynamic>{
        'textureId': textureId,
        'width': width,
        'height': height,
        'bitrate': bitrate,
      },
    );
  }

  @override
  Future<void> selectLegibleMediaGroup(int? textureId, int? index) {
    return methodChannel.invokeMethod<void>(
      'selectLegibleMediaGroup',
      <String, dynamic>{
        'textureId': textureId,
        'index': index,
      },
    );
  }

  @override
  Stream<PlatformDownloadEvent> downloadEventStream() {
    return const EventChannel('video_player_channel/downloadEvents')
        .receiveBroadcastStream()
        .map((dynamic event) {
      late Map<dynamic, dynamic> map;
      if (event is Map) {
        map = event;
      }
      final eventType =
          platformDownloadEventTypeFromString(map["event"] as String);
      switch (eventType) {
        case PlatformDownloadEventType.progress:
          return PlatformDownloadEvent(
            eventType: eventType,
            key: map["key"] as String?,
            progress: map["progress"] as double,
          );
        case PlatformDownloadEventType.finished:
          return PlatformDownloadEvent(
            eventType: eventType,
            key: map["key"] as String?,
          );
        case PlatformDownloadEventType.canceled:
          return PlatformDownloadEvent(
            eventType: eventType,
            key: map["key"] as String?,
          );
        case PlatformDownloadEventType.paused:
          return PlatformDownloadEvent(
            eventType: eventType,
            key: map["key"] as String?,
          );
        case PlatformDownloadEventType.resumed:
          return PlatformDownloadEvent(
            eventType: eventType,
            key: map["key"] as String?,
          );
        case PlatformDownloadEventType.error:
          return PlatformDownloadEvent(
            eventType: eventType,
            key: map["key"] as String?,
            error: map["error"] as String,
          );
        case PlatformDownloadEventType.unknown:
          throw "Unknown event type";
      }
    });
  }

  @override
  Future<void> downloadOfflineAsset({
    required String key,
    required String url,
    Map<String, String?>? headers,
  }) async {
    await methodChannel.invokeMethod(
      'downloadOfflineAsset',
      <String, dynamic>{
        'key': key,
        'url': url,
        'headers': headers,
      },
    );
  }

  @override
  Future<void> pauseDownload(String key) async {
    await methodChannel.invokeMethod(
      'pauseDownload',
      <String, dynamic>{'key': key},
    );
  }

  @override
  Future<void> resumeDownload(String key) async {
    await methodChannel.invokeMethod(
      'resumeDownload',
      <String, dynamic>{'key': key},
    );
  }

  @override
  Future<void> cancelDownload(String key) async {
    await methodChannel.invokeMethod(
      'cancelDownload',
      <String, dynamic>{'key': key},
    );
  }

  @override
  Future<void> deleteOfflineAsset(String key) async {
    methodChannel.invokeMethod('deleteOfflineAsset', <String, dynamic>{
      'key': key,
    });
  }

  @override
  Future<List<Download>> getDownloads() async {
    final res = await methodChannel.invokeMethod<List<dynamic>>(
          'getDownloads',
          null,
        ) ??
        [];
    return res.map((e) {
      final map = Map<String, dynamic>.from(e);
      return Download(
        key: map["key"],
        state: platformDownloadStateFromString(map["state"] as String)!,
      );
    }).toList();
  }

  @override
  Future<void> shrink(int? textureId) async {
    await methodChannel.invokeMethod(
      'shrink',
      <String, dynamic>{'textureId': textureId},
    );
  }

  @override
  Future<void> expand(int? textureId) async {
    await methodChannel.invokeMethod(
      'expand',
      <String, dynamic>{'textureId': textureId},
    );
  }

  @override
  Future<double> getCurrentVideoResolution(int? textureId) async {
    return await methodChannel.invokeMethod(
      'getCurrentVideoResolution',
      <String, dynamic>{'textureId': textureId},
    );
  }

  @override
  Future<double> getCurrentVideoFrameRate(int? textureId) async {
    return await methodChannel.invokeMethod(
      'getCurrentVideoFrameRate',
      <String, dynamic>{'textureId': textureId},
    );
  }
}

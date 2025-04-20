import AVKit
import Flutter
import UIKit

typealias DataSource = [String: Any]

enum FlutterMethod: String {
    case `init`
    case create
    case isPictureInPictureSupported
    case setDataSource
    case setAutoLoop
    case play
    case pause
    case seekTo
    case dispose
    case willExitFullscreen
    case enablePictureInPicture
    case disablePictureInPicture
    case setMuted
    case setPlaybackRate
    case setTrackParameters
    case selectLegibleMediaGroup
    // download
    case downloadOfflineAsset
    case pauseDownload
    case resumeDownload
    case cancelDownload
    case deleteOfflineAsset
    case getDownloads
    case shrink
    case expand
    case getCurrentVideoResolution
    case getCurrentVideoFrameRate
}

typealias TextureId = Int

enum DownloadState: String {
    case running
    case suspended
    case completed
}

extension FlutterError {
    fileprivate static func unknownMethod(message: String? = nil, details: Any? = nil) -> FlutterError {
        FlutterError(code: "UNKNOWN_METHOD", message: message, details: details)
    }

    fileprivate static func invalidArgs(message: String? = nil, details: Any? = nil) -> FlutterError {
        FlutterError(code: "INVLIAD_ARGS", message: message, details: details)
    }

    fileprivate static func assetNotFound(message: String? = nil, details: Any? = nil) -> FlutterError {
        FlutterError(code: "ASSET_NOT_FOUND", message: message, details: details)
    }

    fileprivate static func keyNotFound(message: String? = nil, details: Any? = nil) -> FlutterError {
        FlutterError(code: "KEY_NOT_FOUND", message: message, details: details)
    }
}

public class VideoPlayerPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_player", binaryMessenger: registrar.messenger())
        let instance = VideoPlayerPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.register(instance, withId: "matsune.video_player/VideoPlayerView")
    }

    private var nextTextureId: Int = 1
    private let registrar: FlutterPluginRegistrar
    private let messenger: FlutterBinaryMessenger
    private var players: [TextureId: VideoPlayer] = [:]
    private var dataSources: [TextureId: DataSource] = [:]
    private let remoteControlManager: RemoteControlManager
    private let downloader: Downloader

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        self.messenger = registrar.messenger()
        self.remoteControlManager = RemoteControlManager()
        self.downloader = Downloader(binaryMessanger: messenger)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        players.values.forEach { $0.onDetachFromEngine() }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let method = FlutterMethod(rawValue: call.method) else {
            result(FlutterError.unknownMethod(message: call.method))
            return
        }
        switch method {
        case .`init`:
            players.forEach { $0.value.dispose() }
            players.removeAll()
            result(nil)
        case .create:
            let textureId = createVideoPlayer()
            result(["textureId": textureId])
        case .isPictureInPictureSupported:
            result([
                "isPictureInPictureSupported": AVPictureInPictureController.isPictureInPictureSupported()
            ])
        case .downloadOfflineAsset,
             .pauseDownload,
             .resumeDownload,
             .cancelDownload,
             .deleteOfflineAsset,
             .getDownloads:
            let args = call.arguments as? [String: Any] ?? [:]
            handleDownloadMethods(method: method, args: args, result: result)
        default:
            guard let args = call.arguments as? [String: Any],
                    let textureId = args["textureId"] as? Int,
                    let player = players[textureId] else {
                result(FlutterError.invalidArgs(message: "invalid textureId"))
                return
            }
            handlePlayerMethods(
                method: method,
                args: args,
                textureId: textureId,
                player: player,
                result: result
            )
        }
    }

    private func handlePlayerMethods(
        method: FlutterMethod,
        args: [String: Any],
        textureId: TextureId,
        player: VideoPlayer,
        result: @escaping FlutterResult
    ) {
        switch method {
        case .setDataSource:
            player.clear()

            let dataSource = args["dataSource"] as! DataSource
            dataSources[textureId] = dataSource

            if let disableRemoteControl = dataSource["disableRemoteControl"] as? Bool {
                player.disableRemoteControl = disableRemoteControl
            }
            if let key = dataSource["offlineKey"] as? String {
                guard let path = DownloadPathManager.assetPath(forKey: key)
                else {
                    result(FlutterError.assetNotFound())
                    return
                }
                let assetURL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(path)
                player.setDataSource(url: assetURL, headers: nil)
            } else {
                guard let urlString = dataSource["url"] as? String,
                    let url = URL(string: urlString)
                else {
                    result(FlutterError.invalidArgs(message: "requires valid url"))
                    return
                }
                let headers = dataSource["headers"] as? [String: String]
                if let subtitles = dataSource["subtitles"] as? [[String: Any]] {
                    let proxySubtitles: [HlsProxyServer.Subtitle] = subtitles.compactMap {
                        guard let name = $0["name"] as? String,
                              let urlString = $0["url"] as? String,
                              let url = URL(string: urlString) else {
                            return nil
                        }
                        return .init(name: name, url: url, language: $0["language"] as? String)
                    }
                    if let proxyURL = player.proxyServer.m3u8ProxyURL(url, headers: headers, subtitles: proxySubtitles) {
                        player.setDataSource(url: proxyURL, headers: headers)
                        result(nil)
                        return
                    }
                    player.waitProxyServerReady { isReady in
                        if isReady {
                            if let proxyURL = player.proxyServer.m3u8ProxyURL(url, headers: headers, subtitles: proxySubtitles) {
                                player.setDataSource(url: proxyURL, headers: headers)
                            }
                        }
                        result(nil)
                    }
                    return
                } else {
                    player.setDataSource(url: url, headers: headers)
                }
            }
            result(nil)
        case .setAutoLoop:
            let autoLoop = args["autoLoop"] as! Bool
            player.autoLoop = autoLoop
            result(nil)
        case .play:
            player.play()
            if !player.disableRemoteControl {
                let dataSource = dataSources[textureId]
                let title = dataSource?["title"] as? String
                let author = dataSource?["author"] as? String
                let imageUrl = dataSource?["imageUrl"] as? String
                remoteControlManager.setupRemoteNotification(
                    textureId: textureId,
                    player: player,
                    title: title,
                    author: author,
                    imageUrl: imageUrl
                )
            }
            result(nil)
        case .pause:
            player.pause()
            result(nil)
        case .seekTo:
            let position = args["position"] as! Int64
            player.seekTo(millis: position) {
                result(nil)
            }
        case .dispose:
            if !player.disableRemoteControl {
                remoteControlManager.disposePlayer(textureId: textureId, player: player)
            }
            players.removeValue(forKey: textureId)
            player.dispose()
            if players.isEmpty {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
            }
            result(nil)
        case .willExitFullscreen:
            player.setPlayerViewActive(player.playerView)
            result(nil)
        case .enablePictureInPicture:
            player.enablePictureInPicture()
            result(nil)
        case .disablePictureInPicture:
            player.disablePictureInPicture()
            result(nil)
        case .setMuted:
            let isMuted = args["muted"] as! Bool
            player.isMuted = isMuted
            result(nil)
        case .setPlaybackRate:
            let rate = args["rate"] as! Float
            player.playbackRate = rate
            result(nil)
        case .setTrackParameters:
            let width = args["width"] as! Int
            let height = args["height"] as! Int
            let bitrate = args["bitrate"] as! Double
            player.setTrackParameters(width: width, height: height, bitrate: bitrate)
            result(nil)
        case .selectLegibleMediaGroup:
            let index = args["index"] as? Int
            player.selectLegibleMediaGroup(at: index)
            result(nil)
        case .shrink:
            player.shrink()
            result(nil)
        case .expand:
            player.expand()
            result(nil)
        case .getCurrentVideoResolution:
            let resolution = player.getCurrentVideoResolution()
            result(resolution)
        case .getCurrentVideoFrameRate:
            let frameRate = player.getCurrentVideoFrameRate()
            result(frameRate)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleDownloadMethods(
        method: FlutterMethod,
        args: [String: Any],
        result: @escaping FlutterResult
    ) {
        switch method {
        case .downloadOfflineAsset:
            guard let key = args["key"] as? String,
                let urlString = args["url"] as? String,
                let url = URL(string: urlString)
            else {
                result(FlutterError.invalidArgs(message: "requires key and valid url"))
                return
            }
            downloader.startDownload(
                key: key,
                url: url,
                headers: args["headers"] as? [String: String]
            )
            result(nil)
        case .pauseDownload:
            guard let key = args["key"] as? String
            else {
                result(FlutterError.invalidArgs(message: "requires key"))
                return
            }
            downloader.pauseDownload(key: key) { task in
                if task == nil {
                    result(FlutterError.keyNotFound())
                    return
                }
                result(nil)
            }
        case .resumeDownload:
            guard let key = args["key"] as? String
            else {
                result(FlutterError.invalidArgs(message: "requires key"))
                return
            }
            downloader.resumeDownload(key: key) { task in
                if task == nil {
                    result(FlutterError.keyNotFound())
                    return
                }
                result(nil)
            }
        case .cancelDownload:
            guard let key = args["key"] as? String
            else {
                result(FlutterError.invalidArgs(message: "requires key"))
                return
            }
            downloader.cancelDownload(key: key) { task in
                if task == nil {
                    result(FlutterError.keyNotFound())
                    return
                }
                result(nil)
            }
        case .deleteOfflineAsset:
            guard let key = args["key"] as? String
            else {
                result(FlutterError.invalidArgs(message: "requires key"))
                return
            }
            downloader.deleteOfflineAsset(key: key)
            result(nil)
        case .getDownloads:
            DownloadPathManager.sync()
            let items = DownloadPathManager.read()
            let downloadedKeys: [String] = Array(items.filter { $0.value["path"] != nil }.keys)
            let downloadings = items.filter { $0.value["path"] == nil }
            downloader.getAllDownloadTasks { tasks in
                var downloads: [[String: Any]] = []
                downloads = downloadedKeys.map { ["key": $0, "state": DownloadState.completed.rawValue] }
                downloadings.forEach {
                    let key = $0.key
                    let url = $0.value["url"]
                    if let task = tasks
                        .filter({ $0.state != .canceling })
                        .first(where: { $0.urlAsset.url.absoluteString == url }) {
                        let state: DownloadState
                        switch task.state {
                        case .running:
                            state = .running
                        case .suspended:
                            state = .suspended
                        case .completed:
                            state = .completed
                        default:
                            fatalError("unreachable")
                        }
                        downloads.append(["key": key, "state": state.rawValue])
                    } else {
                        // still downloading but download task not found
                        DownloadPathManager.remove(key)
                    }
                }
                result(downloads)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// returns: texture id
    private func createVideoPlayer() -> TextureId {
        let textureId = nextTextureId
        nextTextureId += 1
        let eventChannel = FlutterEventChannel(
            name: "video_player_channel/videoEvents\(textureId)",
            binaryMessenger: messenger
        )
        players[textureId] = VideoPlayer(textureId: textureId, eventChannel: eventChannel)
        return textureId
    }
}

extension VideoPlayerPlugin: FlutterPlatformViewFactory {
    public func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
        -> FlutterPlatformView
    {
        guard let args = args as? [String: Any],
            let textureId = args["textureId"] as? Int,
            let player = players[textureId]
        else {
            fatalError()
        }
        let isFullscreen = args["isFullscreen"] as? Bool
        if isFullscreen == true {
            player.setPlayerViewActive(player.fullscreenPlayerView)
        } else {
            player.setPlayerViewActive(player.playerView)
        }
        return player
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

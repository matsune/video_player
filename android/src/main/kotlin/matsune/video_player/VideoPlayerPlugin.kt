package matsune.video_player

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.LongSparseArray
import androidx.annotation.RequiresApi
import androidx.media3.datasource.cache.*
import androidx.media3.exoplayer.offline.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

class VideoPlayerPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private val videoPlayers = LongSparseArray<VideoPlayer>()
    private val dataSources = LongSparseArray<Map<String, Any?>>()
    private var flutterState: FlutterState? = null
    private var activity: Activity? = null
    private var pipListener = PipListener()
    private var currentNotificationTextureId: Long? = null

    private val isAndroidHigherM: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M

    private val isAndroidHigherO: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    private val isPictureInPictureSupported: Boolean
        get() = isAndroidHigherO && activity?.packageManager?.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) ==
            true

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterState = FlutterState(
            binding.applicationContext,
            binding.binaryMessenger,
            binding.textureRegistry,
        )
        flutterState?.startListening(this)

        if (Downloader.eventChannel == null) {
            val eventChannel = EventChannel(flutterState?.binaryMessenger, DOWNLOAD_EVENTS_CHANNEL)
            Downloader.setupEventChannel(eventChannel)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        disposeAllPlayers()
        flutterState?.stopListening()
        flutterState = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}

    override fun onDetachedFromActivity() {}

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (flutterState == null) {
            result.error(ERR_CODE_PLUGIN_NOT_ATTACHED, null, null)
            return
        }
        val flutterState = flutterState!!
        when (call.method) {
            METHOD_INIT -> {
                disposeAllPlayers()
                result.success(null)
            }
            METHOD_CREATE -> {
                val textureId = createPlayer(flutterState, call)
                result.success(mapOf("textureId" to textureId))
            }
            METHOD_IS_PICTURE_IN_PICTURE_SUPPORTED -> {
                result.success(mapOf("isPictureInPictureSupported" to isPictureInPictureSupported))
            }
            METHOD_DOWNLOAD_OFFLINE_ASSET,
            METHOD_DELETE_OFFLINE_ASSET,
            METHOD_PAUSE_DOWNLOAD,
            METHOD_RESUME_DOWNLOAD,
            METHOD_CANCEL_DOWNLOAD,
            METHOD_GET_DOWNLOADS -> {
                onDownloadMethodCall(flutterState, call, result)
            }
            else -> {
                val textureId = (call.argument<Any>("textureId") as Number?)?.toLong()
                if (textureId == null) {
                    result.error(ERR_CODE_INVALID_TEXTURE_ID, "textureId is null", null)
                    return
                }
                val player = videoPlayers[textureId]
                if (player == null) {
                    result.error(
                        ERR_CODE_INVALID_TEXTURE_ID,
                        "No video player associated with texture id $textureId",
                        null
                    )
                    return
                }
                onPlayerMethodCall(flutterState, call, result, textureId, player)
            }
        }
    }

    private fun disposeAllPlayers() {
        for (i in 0 until videoPlayers.size()) {
            videoPlayers.valueAt(i).dispose()
        }
        videoPlayers.clear()
        dataSources.clear()
    }

    private fun createPlayer(flutterState: FlutterState, call: MethodCall): Long {
        val textureEntry = flutterState.textureRegistry.createSurfaceTexture()
        val textureId = textureEntry.id()
        val eventChannel =
            EventChannel(flutterState.binaryMessenger, EVENTS_CHANNEL + textureId)
        var customDefaultLoadControl = CustomDefaultLoadControl()
        if (call.hasArgument("minBufferMs") &&
            call.hasArgument("maxBufferMs") &&
            call.hasArgument("bufferForPlaybackMs") &&
            call.hasArgument("bufferForPlaybackAfterRebufferMs")
        ) {
            customDefaultLoadControl =
                CustomDefaultLoadControl(
                    call.argument("minBufferMs"),
                    call.argument("maxBufferMs"),
                    call.argument("bufferForPlaybackMs"),
                    call.argument("bufferForPlaybackAfterRebufferMs")
                )
        }
        val player =
            VideoPlayer(
                flutterState.applicationContext,
                eventChannel,
                textureEntry,
                customDefaultLoadControl,
            )
        videoPlayers.put(textureId, player)
        return textureId
    }

    private fun onDownloadMethodCall(
        flutterState: FlutterState,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val context = flutterState.applicationContext
        when (call.method) {
            METHOD_DOWNLOAD_OFFLINE_ASSET -> {
                val key = call.argument<String>("key")!!
                val url = call.argument<String>("url")!!
                val headers: Map<String, String>? = call.argument<Map<String, String>>("headers")
                Downloader.startDownload(context, key, url, headers)
                result.success(null)
            }
            METHOD_DELETE_OFFLINE_ASSET -> {
                val key = call.argument<String>("key")!!
                Downloader.removeDownload(context, key)
                result.success(null)
            }
            METHOD_PAUSE_DOWNLOAD -> {
                val key = call.argument<String>("key")!!
                Downloader.pauseDownload(context, key)
                result.success(null)
            }
            METHOD_RESUME_DOWNLOAD -> {
                val key = call.argument<String>("key")!!
                Downloader.resumeDownload(context, key)
                result.success(null)
            }
            METHOD_CANCEL_DOWNLOAD -> {
                val key = call.argument<String>("key")!!
                Downloader.cancelDownload(context, key)
                result.success(null)
            }
            METHOD_GET_DOWNLOADS -> {
                val keys = Downloader.getDownloadKeys(context)
                val res = mutableListOf<Map<String, Any>>()
                keys.forEach {
                    val key = it
                    val download = Downloader.getDownloadByKey(context, key)
                    when (download?.state) {
                        Download.STATE_COMPLETED -> {
                            res.add(mapOf("key" to key, "state" to DOWNLOAD_STATE_COMPLETED))
                        }
                        Download.STATE_DOWNLOADING, Download.STATE_QUEUED, Download.STATE_RESTARTING -> {
                            res.add(mapOf("key" to key, "state" to DOWNLOAD_STATE_RUNNING))
                        }
                        Download.STATE_STOPPED -> {
                            res.add(mapOf("key" to key, "state" to DOWNLOAD_STATE_SUSPENDED))
                        }
                        else -> {}
                    }
                }
                result.success(res)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun onPlayerMethodCall(
        flutterState: FlutterState,
        call: MethodCall,
        result: MethodChannel.Result,
        textureId: Long,
        player: VideoPlayer
    ) {
        when (call.method) {
            METHOD_SET_DATA_SOURCE -> {
                setDataSource(call, textureId, player)
                result.success(null)
            }
            METHOD_SET_AUTO_LOOP -> {
                val autoLoop = call.argument("autoLoop") as? Boolean
                player.setAutoLoop(autoLoop!!)
                result.success(null)
            }
            METHOD_PLAY -> {
                if (isAndroidHigherM && !player.disableRemoteControl) {
                    setupNotification(flutterState.applicationContext, textureId, player)
                }
                player.play()
                result.success(null)
            }
            METHOD_PAUSE -> {
                player.pause()
                result.success(null)
            }
            METHOD_SEEK_TO -> {
                val location = (call.argument("position") as Number?)!!.toInt()
                player.seekTo(location)
                result.success(null)
            }
            METHOD_DISPOSE -> {
                dispose(player, textureId)
                result.success(null)
            }
            METHOD_WILL_EXIT_FULLSCREEN -> {}
            METHOD_ENABLE_PICTURE_IN_PICTURE -> {
                if (isAndroidHigherO) {
                    if (activity == null) {
                        result.error(ERR_CODE_NO_ACTIVITY, null, null)
                        return
                    }
                    enablePictureInPicture(flutterState.applicationContext, activity!!, player)
                }
                result.success(null)
            }
            METHOD_DISABLE_PICTURE_IN_PICTURE -> {
                disablePictureInPicture(player)
                result.success(null)
            }
            METHOD_SET_MUTED -> {
                player.isMuted = call.argument("muted")!!
                result.success(null)
            }
            METHOD_SET_PLAYBACK_RATE -> {
                val rate = (call.argument("rate") as Number?)!!.toFloat()
                player.playbackSpeed = rate
                result.success(null)
            }
            METHOD_SET_TRACK_PARAMETERS -> {
                val width: Int = if (call.argument<Any>("width") is Number) {
                    call.argument<Number>("width")!!.toInt()
                } else {
                    0
                }
                val height = if (call.argument<Any>("height") is Number) {
                    call.argument<Number>("height")!!.toInt()
                } else {
                    0
                }
                val bitrate = if (call.argument<Any>("bitrate") is Number) {
                    call.argument<Number>("bitrate")!!.toInt()
                } else {
                    0
                }
                player.setTrackParameters(width, height, bitrate)
                result.success(null)
            }
            METHOD_EXPAND -> {}
            METHOD_SHRINK -> {}
            METHOD_GET_CURRENT_VIDEO_RESOLUTION -> {
                val resolution: Double = player.getCurrentVideoResolution()
                result.success(resolution)
            }
            METHOD_GET_CURRENT_VIDEO_FRAME_RATE -> {
                val resolution: Double = player.getCurrentVideoFrameRate()
                result.success(resolution)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun setupNotification(context: Context, textureId: Long, player: VideoPlayer) {
        if (textureId == currentNotificationTextureId) {
            return
        }
        val dataSource = dataSources[textureId]
        currentNotificationTextureId = textureId
        removeOtherNotificationListeners()
        val title = DataSourceUtils.getParameter(dataSource, "title", "")
        val author = DataSourceUtils.getParameter<String?>(dataSource, "author", null)
        val imageUrl = DataSourceUtils.getParameter<String?>(dataSource, "imageUrl", null)
        val notificationChannelName =
            DataSourceUtils.getParameter<String?>(dataSource, "notificationChannelName", null)
        val activityName =
            DataSourceUtils.getParameter(dataSource, "activityName", "MainActivity")
        player.setupPlayerNotification(
            context,
            title,
            author,
            imageUrl,
            notificationChannelName,
            activityName
        )
    }

    private fun removeOtherNotificationListeners() {
        for (index in 0 until videoPlayers.size()) {
            videoPlayers.valueAt(index).disposeRemoteNotifications()
        }
    }

    private fun setDataSource(call: MethodCall, textureId: Long, player: VideoPlayer) {
        val dataSource = call.argument<Map<String, Any?>>("dataSource")!!
        dataSources.put(textureId, dataSource)
        val disableRemoteControl = DataSourceUtils.getParameter<Boolean>(dataSource, "disableRemoteControl", false)
        player.disableRemoteControl = disableRemoteControl
        val offlineKey = DataSourceUtils.getParameter<String?>(dataSource, "offlineKey", null)
        if (offlineKey != null) {
            player.setOfflineDataSource(offlineKey)
        } else {
            val headers: Map<String, String> =
                DataSourceUtils.getParameter(dataSource, "headers", HashMap())
            val url = DataSourceUtils.getParameter(dataSource, "url", "")
            player.setNetworkDataSource(url, headers)
        }
    }

    private fun dispose(player: VideoPlayer, textureId: Long) {
        pipListener.stopPipHandler()
        player.dispose()
        videoPlayers.remove(textureId)
        dataSources.remove(textureId)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun enablePictureInPicture(context: Context, activity: Activity, player: VideoPlayer) {
        player.setupMediaSession(context)
        activity.enterPictureInPictureMode(PictureInPictureParams.Builder().build())
        pipListener.startPictureInPictureListenerTimer(activity, player)
    }

    private fun disablePictureInPicture(player: VideoPlayer) {
        pipListener.stopPipHandler()
        activity?.moveTaskToBack(false)
        player.disposeMediaSession()
    }

    private class FlutterState(
        val applicationContext: Context,
        val binaryMessenger: BinaryMessenger,
        val textureRegistry: TextureRegistry,
    ) {
        private val methodChannel: MethodChannel = MethodChannel(binaryMessenger, CHANNEL)

        fun startListening(methodCallHandler: MethodCallHandler?) {
            methodChannel.setMethodCallHandler(methodCallHandler)
        }

        fun stopListening() {
            methodChannel.setMethodCallHandler(null)
        }
    }

    companion object {
        private var nextTextureId: Long = 0
        fun getNextTextureId(): Long {
            return ++nextTextureId
        }

        private const val VIEW_TYPE_ID = "matsune.video_player/VideoPlayerView"

        const val TAG = "VideoPlayerPlugin"
        private const val CHANNEL = "video_player"
        private const val EVENTS_CHANNEL = "video_player_channel/videoEvents"
        private const val DOWNLOAD_EVENTS_CHANNEL = "video_player_channel/downloadEvents"

        private const val ERR_CODE_PLUGIN_NOT_ATTACHED = "PLUGIN_NOT_ATTACHED"
        private const val ERR_CODE_INVALID_TEXTURE_ID = "INVALID_TEXTURE_ID"
        private const val ERR_CODE_NO_ACTIVITY = "NO_ACTIVITY"

        private const val METHOD_INIT = "init"
        private const val METHOD_CREATE = "create"
        private const val METHOD_IS_PICTURE_IN_PICTURE_SUPPORTED = "isPictureInPictureSupported"
        private const val METHOD_SET_DATA_SOURCE = "setDataSource"
        private const val METHOD_SET_AUTO_LOOP = "setAutoLoop"
        private const val METHOD_PLAY = "play"
        private const val METHOD_PAUSE = "pause"
        private const val METHOD_SEEK_TO = "seekTo"
        private const val METHOD_DISPOSE = "dispose"
        private const val METHOD_WILL_EXIT_FULLSCREEN = "willExitFullscreen"
        private const val METHOD_ENABLE_PICTURE_IN_PICTURE = "enablePictureInPicture"
        private const val METHOD_DISABLE_PICTURE_IN_PICTURE = "disablePictureInPicture"
        private const val METHOD_SET_MUTED = "setMuted"
        private const val METHOD_SET_PLAYBACK_RATE = "setPlaybackRate"
        private const val METHOD_SET_TRACK_PARAMETERS = "setTrackParameters"
        private const val METHOD_DOWNLOAD_OFFLINE_ASSET = "downloadOfflineAsset"
        private const val METHOD_DELETE_OFFLINE_ASSET = "deleteOfflineAsset"
        private const val METHOD_PAUSE_DOWNLOAD = "pauseDownload"
        private const val METHOD_RESUME_DOWNLOAD = "resumeDownload"
        private const val METHOD_CANCEL_DOWNLOAD = "cancelDownload"
        private const val METHOD_GET_DOWNLOADS = "getDownloads"
        private const val METHOD_EXPAND = "expand"
        private const val METHOD_SHRINK = "shrink"
        private const val METHOD_GET_CURRENT_VIDEO_RESOLUTION = "getCurrentVideoResolution"
        private const val METHOD_GET_CURRENT_VIDEO_FRAME_RATE = "getCurrentVideoFrameRate"

        private const val DOWNLOAD_STATE_RUNNING = "running"
        private const val DOWNLOAD_STATE_SUSPENDED = "suspended"
        private const val DOWNLOAD_STATE_COMPLETED = "completed"
    }
}

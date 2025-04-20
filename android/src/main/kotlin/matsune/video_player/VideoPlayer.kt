package matsune.video_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import android.view.Surface
import androidx.annotation.RequiresApi
import androidx.lifecycle.Observer
import androidx.media3.common.*
import androidx.media3.common.C.AUDIO_CONTENT_TYPE_MOVIE
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.*
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.trackselection.AdaptiveTrackSelection
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import androidx.media3.ui.PlayerNotificationManager
import androidx.media3.ui.PlayerNotificationManager.BitmapCallback
import androidx.media3.ui.PlayerNotificationManager.MediaDescriptionAdapter
import androidx.work.*
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import java.util.*
import io.flutter.view.TextureRegistry.SurfaceTextureEntry

class VideoPlayer(
    private val context: Context,
    private val eventChannel: EventChannel,
    private val textureEntry: SurfaceTextureEntry,
    private val customDefaultLoadControl: CustomDefaultLoadControl
) {

    private val loadControl: LoadControl
    private val exoPlayer: ExoPlayer
    private val eventSink = QueuingEventSink()
    private val bandwidthMeter = DefaultBandwidthMeter.Builder(context).build()
    private val trackSelector = DefaultTrackSelector(context, AdaptiveTrackSelection.Factory())
    private var surface: Surface? = null
    private var isInitialized = false
    private var lastSendBufferedPosition = 0L
    private var mediaSession: MediaSessionCompat? = null

    private var handler = Handler(Looper.getMainLooper())
    private val runnable: Runnable
    private val bufferingRunnable: Runnable

    private var playerNotificationManager: PlayerNotificationManager? = null
    private var refreshHandler: Handler? = null
    private var refreshRunnable: Runnable? = null
    private var exoPlayerEventListener: Player.Listener? = null
    private var bitmap: Bitmap? = null
    private val workManager: WorkManager
    private val workerObserverMap: HashMap<UUID, Observer<WorkInfo?>>
    var disableRemoteControl: Boolean = false
    private var isBufferingRunnableStarted = false

    var isMuted: Boolean
        get() = exoPlayer.volume == 0f
        set(value) {
            exoPlayer.volume = if (value) 0f else 1f
        }

    private val position: Long
        get() = exoPlayer.currentPosition

    private val duration: Long
        get() = exoPlayer.duration

    var playbackSpeed: Float
        get() = exoPlayer.playbackParameters.speed
        set(value) {
            exoPlayer.setPlaybackSpeed(value)
        }

    init {
        loadControl =
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(
                    this.customDefaultLoadControl.minBufferMs,
                    this.customDefaultLoadControl.maxBufferMs,
                    this.customDefaultLoadControl.bufferForPlaybackMs,
                    this.customDefaultLoadControl.bufferForPlaybackAfterRebufferMs
                )
                .build()
        exoPlayer =
            ExoPlayer.Builder(context)
                .setTrackSelector(trackSelector)
                .setLoadControl(loadControl)
                .setBandwidthMeter(bandwidthMeter)
                .build()
        setupVideoPlayer(eventChannel, textureEntry)
        workManager = WorkManager.getInstance(context)
        workerObserverMap = HashMap()
        runnable =
            object : Runnable {
                override fun run() {
                    if (exoPlayer.isPlaying) {
                        sendPositionChanged()
                    }
                    handler.postDelayed(this, 200)
                }
            }
        bufferingRunnable =
            object : Runnable {
                override fun run() {
                    val bufferedPosition = exoPlayer.bufferedPosition
                    if (bufferedPosition != lastSendBufferedPosition) {
                        val range: List<Number?> = listOf(0, bufferedPosition)
                        sendEvent(EVENT_BUFFER_CHANGED, mapOf("bufferRange" to range))
                        lastSendBufferedPosition = bufferedPosition
                    }
                    handler.postDelayed(this, 200)
                }
            }
    }

    fun dispose() {
        disposeMediaSession()
        disposeRemoteNotifications()
        handler.removeCallbacks(bufferingRunnable)
        isBufferingRunnableStarted = false
        handler.removeCallbacks(runnable)
        if (isInitialized) {
            exoPlayer.stop()
        }
        eventChannel.setStreamHandler(null)
        textureEntry.release()
        surface?.release()
        exoPlayer.release()
    }

    private fun setupVideoPlayer(eventChannel: EventChannel, textureEntry: SurfaceTextureEntry) {
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(o: Any?, sink: EventSink) {
                    eventSink.setDelegate(sink)
                }

                override fun onCancel(o: Any?) {
                    eventSink.setDelegate(null)
                }
            }
        )
        surface = Surface(textureEntry.surfaceTexture())
        exoPlayer.setVideoSurface(surface)
        exoPlayer.setAudioAttributes(
            AudioAttributes.Builder().setContentType(AUDIO_CONTENT_TYPE_MOVIE).build(),
            true
        )
        exoPlayer.addListener(
            object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    when (playbackState) {
                        Player.STATE_BUFFERING -> {
                            // no-op
                        }
                        Player.STATE_READY -> {
                            if (!isInitialized) {
                                setInitialized()
                                return
                            }
                        }
                        Player.STATE_ENDED -> {
                            pause()
                            sendEvent(EVENT_ENDED)
                        }
                        Player.STATE_IDLE -> {
                            // no-op
                        }
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    var invalid = false;

                    when (val cause = error.cause) {
                        is HttpDataSource.InvalidResponseCodeException -> {
                            val responseCode = cause.responseCode
                            if (responseCode == 403) {
                                invalid = true
                            }
                        }
                    }

                    sendEvent(
                        EVENT_ERROR,
                        mapOf("error" to error.localizedMessage, "invalid" to invalid)
                    )
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    if (isPlaying) {
                        handler.post(runnable)

                        if (!isBufferingRunnableStarted) {
                            handler.post(bufferingRunnable)
                            isBufferingRunnableStarted = true
                        }
                    } else {
                        handler.removeCallbacks(runnable)
                    }
                    sendEvent(EVENT_IS_PLAYING_CHANGED, mapOf("isPlaying" to isPlaying))
                }

                override fun onVolumeChanged(volume: Float) {
                    sendEvent(EVENT_MUTE_CHANGED, mapOf("isMuted" to (volume == 0f)))
                }
            }
        )
    }

    private fun setInitialized() {
        if (isInitialized) return
        isInitialized = true

        val event: MutableMap<String, Any> = HashMap()
        event["duration"] = duration
        if (exoPlayer.videoFormat != null) {
            val videoFormat = exoPlayer.videoFormat
            var width = videoFormat?.width
            var height = videoFormat?.height
            val rotationDegrees = videoFormat?.rotationDegrees
            // Switch the width/height if video was taken in portrait mode
            if (rotationDegrees == 90 || rotationDegrees == 270) {
                width = exoPlayer.videoFormat?.height
                height = exoPlayer.videoFormat?.width
            }
            width?.let { event["width"] = it }
            height?.let { event["height"] = it }
        }
        sendEvent(EVENT_INITIALIZED, event)
    }

    private fun sendEvent(event: String, params: Map<String, Any>? = null) {
        val result: MutableMap<String, Any> = params?.toMutableMap() ?: HashMap()
        result["event"] = event
        eventSink.success(result)
    }

    private fun sendPositionChanged() {
        sendEvent(EVENT_POSITION_CHANGED, mapOf("position" to exoPlayer.currentPosition + 250))
    }

    fun setAutoLoop(value: Boolean) {
        exoPlayer.repeatMode = if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF;
    }

    fun setNetworkDataSource(uri: String, headers: Map<String, String>) {
        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
            .setTransferListener(bandwidthMeter)
        val mediaSourceFactory = HlsMediaSource.Factory(dataSourceFactory)
        val mediaItem = MediaItem.fromUri(uri)
        val mediaSource = mediaSourceFactory.createMediaSource(mediaItem)
        setMediaSource(mediaSource)
    }

    fun setOfflineDataSource(offlineKey: String) {
        val download = Downloader.getDownloadByKey(context, offlineKey)!!
        val dataSourceFactory = Downloader.getDataSourceFactory(context)
        val mediaSourceFactory = HlsMediaSource.Factory(dataSourceFactory)
        val mediaItem = download.request.toMediaItem()
        val mediaSource = mediaSourceFactory.createMediaSource(mediaItem)
        setMediaSource(mediaSource)
    }

    private fun setMediaSource(mediaSource: MediaSource) {
        isInitialized = false
        exoPlayer.setMediaSource(mediaSource)
        exoPlayer.prepare()
    }

    fun play() {
        exoPlayer.play()
    }

    fun pause() {
        exoPlayer.pause()
    }

    fun seekTo(location: Int) {
        exoPlayer.seekTo(location.toLong())
        sendPositionChanged()
    }

    fun setTrackParameters(width: Int, height: Int, bitrate: Int) {
        val parametersBuilder = trackSelector.buildUponParameters()
        if (width != 0 && height != 0) {
            parametersBuilder.setMaxVideoSize(width, height)
        }
        if (bitrate != 0) {
            parametersBuilder.setMaxVideoBitrate(bitrate)
        }
        if (width == 0 && height == 0 && bitrate == 0) {
            parametersBuilder.clearVideoSizeConstraints()
            parametersBuilder.setMaxVideoBitrate(Int.MAX_VALUE)
        }
        trackSelector.setParameters(parametersBuilder)
    }

    fun onPictureInPictureStatusChanged(isPip: Boolean) {
        sendEvent(EVENT_PIP_CHANGED, mapOf("isPip" to isPip))
    }

    fun getCurrentVideoResolution(): Double {
        val currentTracks = exoPlayer.currentTracks
        for (group in currentTracks.groups) {
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                if (format.sampleMimeType?.startsWith("video") == true) {
                    return format.height.toDouble()
                }
            }
        }
        return 0.0
    }

    fun getCurrentVideoFrameRate(): Double {
        val videoFormat = exoPlayer.videoFormat
        return videoFormat?.frameRate?.toDouble() ?: 0.0
    }

    @RequiresApi(Build.VERSION_CODES.M)
    fun setupMediaSession(context: Context): MediaSessionCompat {
        mediaSession?.release()
        val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
        val pendingIntent =
            PendingIntent.getBroadcast(
                context,
                0,
                mediaButtonIntent,
                PendingIntent.FLAG_IMMUTABLE
            )
        val mediaSession = MediaSessionCompat(context, TAG, null, pendingIntent)
        mediaSession.setCallback(object : MediaSessionCompat.Callback() {
            override fun onSeekTo(pos: Long) {
                seekTo(pos.toInt())
            }
        })
        mediaSession.isActive = true
        this.mediaSession = mediaSession
        return mediaSession
    }

    fun disposeMediaSession() {
        if (mediaSession != null) {
            mediaSession?.release()
        }
        mediaSession = null
    }

    @RequiresApi(Build.VERSION_CODES.M)
    fun setupPlayerNotification(
        context: Context,
        title: String,
        author: String?,
        imageUrl: String?,
        notificationChannelName: String?,
        activityName: String
    ) {
        val mediaDescriptionAdapter: MediaDescriptionAdapter =
            object : MediaDescriptionAdapter {
                override fun getCurrentContentTitle(player: Player): String {
                    return title
                }

                override fun createCurrentContentIntent(player: Player): PendingIntent? {
                    val packageName = context.applicationContext.packageName
                    val notificationIntent = Intent()
                    notificationIntent.setClassName(packageName, "$packageName.$activityName")
                    notificationIntent.flags =
                        (Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    return PendingIntent.getActivity(
                        context,
                        0,
                        notificationIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                }

                override fun getCurrentContentText(player: Player): String? {
                    return author
                }

                override fun getCurrentLargeIcon(
                    player: Player,
                    callback: BitmapCallback
                ): Bitmap? {
                    if (imageUrl == null) {
                        return null
                    }
                    if (bitmap != null) {
                        return bitmap
                    }
                    val imageWorkRequest =
                        OneTimeWorkRequest.Builder(ImageWorker::class.java)
                            .addTag(imageUrl)
                            .setInputData(
                                Data.Builder().putString("url", imageUrl).build()
                            )
                            .build()
                    workManager.enqueue(imageWorkRequest)
                    val workInfoObserver = Observer { workInfo: WorkInfo? ->
                        try {
                            if (workInfo != null) {
                                val state = workInfo.state
                                if (state == WorkInfo.State.SUCCEEDED) {
                                    val outputData = workInfo.outputData
                                    val filePath = outputData.getString("filePath")
                                    // Bitmap here is already processed and it's very small, so
                                    // it won't
                                    // break anything.
                                    bitmap = BitmapFactory.decodeFile(filePath)
                                    bitmap?.let { bitmap -> callback.onBitmap(bitmap) }
                                }
                                if (state == WorkInfo.State.SUCCEEDED ||
                                    state == WorkInfo.State.CANCELLED ||
                                    state == WorkInfo.State.FAILED
                                ) {
                                    val uuid = imageWorkRequest.id
                                    val observer = workerObserverMap.remove(uuid)
                                    if (observer != null) {
                                        workManager
                                            .getWorkInfoByIdLiveData(uuid)
                                            .removeObserver(observer)
                                    }
                                }
                            }
                        } catch (exception: Exception) {
                            Log.e(TAG, "Image select error: $exception")
                        }
                    }
                    val workerUuid = imageWorkRequest.id
                    workManager
                        .getWorkInfoByIdLiveData(workerUuid)
                        .observeForever(workInfoObserver)
                    workerObserverMap[workerUuid] = workInfoObserver
                    return null
                }
            }
        var playerNotificationChannelName = notificationChannelName
        if (notificationChannelName == null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val importance = NotificationManager.IMPORTANCE_LOW
                val channel =
                    NotificationChannel(
                        DEFAULT_NOTIFICATION_CHANNEL,
                        DEFAULT_NOTIFICATION_CHANNEL,
                        importance
                    )
                channel.description = DEFAULT_NOTIFICATION_CHANNEL
                val notificationManager = context.getSystemService(NotificationManager::class.java)
                notificationManager.createNotificationChannel(channel)
                playerNotificationChannelName = DEFAULT_NOTIFICATION_CHANNEL
            }
        }

        playerNotificationManager =
            PlayerNotificationManager.Builder(
                context,
                NOTIFICATION_ID,
                playerNotificationChannelName!!
            )
                .setMediaDescriptionAdapter(mediaDescriptionAdapter)
                .build()

        playerNotificationManager?.apply {
            exoPlayer.let {
                setPlayer(ForwardingPlayer(exoPlayer))
                setUseNextAction(false)
                setUsePreviousAction(false)
                setUseStopAction(false)
            }
            val mediaSession = setupMediaSession(context)
            setMediaSessionToken(mediaSession.sessionToken)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            refreshHandler = Handler(Looper.getMainLooper())
            refreshRunnable = Runnable {
                val playbackState: PlaybackStateCompat =
                    if (exoPlayer.isPlaying) {
                        PlaybackStateCompat.Builder()
                            .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                            .setState(PlaybackStateCompat.STATE_PLAYING, position, 1.0f)
                            .build()
                    } else {
                        PlaybackStateCompat.Builder()
                            .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                            .setState(PlaybackStateCompat.STATE_PAUSED, position, 1.0f)
                            .build()
                    }
                mediaSession?.setPlaybackState(playbackState)
                refreshHandler?.postDelayed(refreshRunnable!!, 1000)
            }
            refreshHandler?.postDelayed(refreshRunnable!!, 0)
        }
        exoPlayerEventListener =
            object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    mediaSession?.setMetadata(
                        MediaMetadataCompat.Builder()
                            .putLong(
                                MediaMetadataCompat.METADATA_KEY_DURATION,
                                duration
                            )
                            .build()
                    )
                }
            }
        exoPlayerEventListener?.let { exoPlayerEventListener ->
            exoPlayer.addListener(exoPlayerEventListener)
        }
        exoPlayer.seekTo(0)
    }

    fun disposeRemoteNotifications() {
        exoPlayerEventListener?.let { exoPlayerEventListener ->
            exoPlayer.removeListener(exoPlayerEventListener)
        }
        if (refreshHandler != null) {
            refreshHandler?.removeCallbacksAndMessages(null)
            refreshHandler = null
            refreshRunnable = null
        }
        if (playerNotificationManager != null) {
            playerNotificationManager?.setPlayer(null)
        }
        bitmap = null
    }

    companion object {
        private const val TAG = "VideoPlayer"

        private const val EVENT_INITIALIZED = "initialized"
        private const val EVENT_IS_PLAYING_CHANGED = "isPlayingChanged"
        private const val EVENT_POSITION_CHANGED = "positionChanged"
        private const val EVENT_BUFFER_CHANGED = "bufferChanged"
        private const val EVENT_PIP_CHANGED = "pipChanged"
        private const val EVENT_MUTE_CHANGED = "muteChanged"
        private const val EVENT_ENDED = "ended"
        private const val EVENT_ERROR = "error"

        private const val DEFAULT_NOTIFICATION_CHANNEL = "VIDEO_PLAYER_NOTIFICATION"
        private const val NOTIFICATION_ID = 10000
    }
}

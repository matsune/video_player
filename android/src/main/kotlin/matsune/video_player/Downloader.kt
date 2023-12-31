package matsune.video_player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.database.DatabaseProvider
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.offline.*
import androidx.media3.exoplayer.scheduler.Requirements
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.IOException
import java.net.CookieHandler
import java.net.CookieManager
import java.net.CookiePolicy
import java.util.concurrent.Executors

object Downloader {
    private var dataSourceFactory: DataSource.Factory? = null
    private var httpDataSourceFactory: DataSource.Factory? = null
    private var databaseProvider: DatabaseProvider? = null
    private var downloadDirectory: File? = null
    private var downloadCache: Cache? = null
    private var downloadManager: DownloadManager? = null
    private var downloadIndex: DownloadIndex? = null
    private var downloadHelpers: HashMap<Uri, DownloadHelper> = hashMapOf()

    private val handler = Handler(Looper.getMainLooper())
    private val runnableMap: HashMap<Uri, Runnable> = hashMapOf()

    var eventChannel: EventChannel? = null
        private set
    private val eventSink = QueuingEventSink()

    fun setupEventChannel(channel: EventChannel) {
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink.setDelegate(sink)
            }

            override fun onCancel(arguments: Any?) {
                eventSink.setDelegate(null)
            }
        })
        eventChannel = channel
    }

    private fun sendEvent(event: String, params: Map<String, Any>? = null) {
        val result: MutableMap<String, Any> = params?.toMutableMap() ?: HashMap()
        result["event"] = event
        eventSink.success(result)
    }

    private fun buildRenderersFactory(context: Context): RenderersFactory {
        return DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
    }

    private fun getHttpDataSourceFactory(headers: Map<String, String>?): DataSource.Factory {
        if (httpDataSourceFactory == null) {
            val cookieManager = CookieManager()
            cookieManager.setCookiePolicy(CookiePolicy.ACCEPT_ORIGINAL_SERVER)
            CookieHandler.setDefault(cookieManager)
            httpDataSourceFactory = DefaultHttpDataSource.Factory().apply {
                headers?.let {
                    setDefaultRequestProperties(it)
                }
            }
        }
        return httpDataSourceFactory!!
    }

    private fun getDownloadManager(context: Context): DownloadManager {
        ensureDownloadManagerInitialized(context)
        return downloadManager!!
    }

    private fun getDownloadCache(context: Context): Cache {
        if (downloadCache == null) {
            val downloadContentDirectory =
                File(getDownloadDirectory(context), DOWNLOAD_CONTENT_DIRECTORY)
            downloadCache = SimpleCache(
                downloadContentDirectory, NoOpCacheEvictor(), getDatabaseProvider(context)
            )
        }
        return downloadCache!!
    }

    fun getDataSourceFactory(context: Context): DataSource.Factory {
        if (dataSourceFactory == null) {
            val upstreamFactory = DefaultDataSource.Factory(
                context,
                getHttpDataSourceFactory(null)
            )
            dataSourceFactory = buildReadOnlyCacheDataSource(
                upstreamFactory,
                getDownloadCache(context)
            )
        }
        return dataSourceFactory!!
    }

    fun buildReadOnlyCacheDataSource(
        upstreamFactory: DataSource.Factory, cache: Cache
    ): CacheDataSource.Factory? {
        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setCacheWriteDataSinkFactory(null)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    private fun getDatabaseProvider(context: Context): DatabaseProvider {
        if (databaseProvider == null) {
            databaseProvider = StandaloneDatabaseProvider(context)
        }
        return databaseProvider!!
    }

    private fun getDownloadDirectory(context: Context): File {
        if (downloadDirectory == null) {
            downloadDirectory = context.getExternalFilesDir( /* type= */null)
            if (downloadDirectory == null) {
                downloadDirectory = context.filesDir
            }
        }
        return downloadDirectory!!
    }

    private fun ensureDownloadManagerInitialized(context: Context) {
        if (downloadManager == null) {
            downloadManager = DownloadManager(
                context,
                getDatabaseProvider(context),
                getDownloadCache(context),
                getHttpDataSourceFactory(null),
                Executors.newFixedThreadPool( /* nThreads= */6)
            )
            downloadIndex = downloadManager?.downloadIndex
            downloadManager?.resumeDownloads()
            downloadManager?.addListener(object : DownloadManager.Listener {
                override fun onDownloadChanged(
                    downloadManager: DownloadManager,
                    download: Download,
                    finalException: Exception?
                ) {
                    when (download.state) {
                        Download.STATE_DOWNLOADING -> {
                            startDownloadTimer(context, download)
                        }
                        Download.STATE_COMPLETED -> {
                            stopDownloadTimer(download)
                            downloadHelpers.remove(download.request.uri)?.release()
                            val key = getKeyByDownloadId(context, download.request.id)!!
                            sendEvent(DOWNLOAD_EVENT_FINISHED, mapOf("key" to key))
                        }
                        Download.STATE_FAILED -> {
                            stopDownloadTimer(download)
                            downloadHelpers.remove(download.request.uri)?.release()
                        }
                        else -> {
                            stopDownloadTimer(download)
                        }
                    }
                }

                override fun onDownloadRemoved(
                    downloadManager: DownloadManager,
                    download: Download
                ) {
                    stopDownloadTimer(download)
                    downloadHelpers.remove(download.request.uri)?.release()
                }
            })
        }
    }

    fun startDownload(context: Context, key: String, url: String, headers: Map<String, String>?) {
        val prefs = context.getSharedPreferences(PREFERENCES_KEY, Context.MODE_PRIVATE).edit()
        val downloadManager = getDownloadManager(context)
        val downloadHelper = DownloadHelper.forMediaItem(
            context,
            MediaItem.fromUri(url),
            buildRenderersFactory(context),
            getHttpDataSourceFactory(headers)
        )
        downloadHelper.prepare(object : DownloadHelper.Callback {
            override fun onPrepared(helper: DownloadHelper) {
                val request = helper.getDownloadRequest(null)
                downloadHelpers[request.uri] = helper
                downloadManager.addDownload(request)
                // save uri for key
                prefs?.putString(key, request.id)
                prefs?.apply()
            }

            override fun onPrepareError(helper: DownloadHelper, e: IOException) {
                Log.e("DownloadUtil", "onPrepareError", e)
            }
        })
    }

    private fun startDownloadTimer(context: Context, download: Download) {
        val runnable = object : Runnable {
            override fun run() {
                // maybe called after download completed so check download is still going here
                if (downloadHelpers.containsKey(download.request.uri)) {
                    val progress = download.percentDownloaded / 100
                    val key = getKeyByDownloadId(context, download.request.id)!!
                    sendEvent(DOWNLOAD_EVENT_PROGRESS, mapOf("key" to key, "progress" to progress))
                    handler.postDelayed(this, 1000)
                } else {
                    stopDownloadTimer(download)
                }
            }
        }
        handler.post(runnable)
        runnableMap[download.request.uri] = runnable
    }

    private fun stopDownloadTimer(download: Download) {
        runnableMap.remove(download.request.uri)?.let {
            handler.removeCallbacks(it)
        }
    }

    fun removeDownload(context: Context, key: String) {
        ensureDownloadManagerInitialized(context)
        val prefs = context.getSharedPreferences(PREFERENCES_KEY, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        prefs.getString(key, "")?.let {
            downloadManager?.removeDownload(it)
        }
        editor.remove(key)
        editor.apply()
    }

    fun getDownloadKeys(context: Context): List<String> {
        ensureDownloadManagerInitialized(context)
        val prefs = context.getSharedPreferences(PREFERENCES_KEY, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        for (entry in prefs.all) {
            val key = entry.key
            val id = entry.value as String
            val download = downloadIndex?.getDownload(id)
            when (download?.state) {
                Download.STATE_COMPLETED, Download.STATE_DOWNLOADING, Download.STATE_QUEUED, Download.STATE_RESTARTING, Download.STATE_STOPPED -> {}
                else -> {
                    editor.remove(key)
                }
            }
        }
        editor.apply()
        return prefs.all.keys.toList()
    }

    fun getDownloadByKey(context: Context, key: String): Download? {
        val prefs = context.getSharedPreferences(PREFERENCES_KEY, Context.MODE_PRIVATE)
        return prefs.getString(key, "")?.let { downloadIndex?.getDownload(it) }
    }

    fun getKeyByDownloadId(context: Context, id: String): String? {
        val prefs = context.getSharedPreferences(PREFERENCES_KEY, Context.MODE_PRIVATE)
        for (entry in prefs.all) {
            if (entry.value == id) {
                return entry.key
            }
        }
        return null
    }

    fun pauseDownload(context: Context, key: String) {
        getDownloadByKey(context, key)?.let {
            downloadManager?.setStopReason(it.request.id, DOWNLOAD_STOP_REASON_PAUSE)
            stopDownloadTimer(it)
            sendEvent(DOWNLOAD_EVENT_PAUSED, mapOf("key" to key))
        }
    }

    fun resumeDownload(context: Context, key: String) {
        getDownloadByKey(context, key)?.let {
            downloadManager?.setStopReason(it.request.id, Download.STOP_REASON_NONE)
            startDownloadTimer(context, it)
            sendEvent(DOWNLOAD_EVENT_RESUMED, mapOf("key" to key))
        }
    }

    fun cancelDownload(context: Context, key: String) {
        getDownloadByKey(context, key)?.let {
            downloadManager?.removeDownload(it.request.id)
            stopDownloadTimer(it)
            sendEvent(DOWNLOAD_EVENT_CANCELED, mapOf("key" to key))
        }
    }

    private const val PREFERENCES_KEY = "video_player_preferences"

    private const val DOWNLOAD_CONTENT_DIRECTORY = "downloads"

    private const val DOWNLOAD_EVENT_PROGRESS = "progress"
    private const val DOWNLOAD_EVENT_FINISHED = "finished"
    private const val DOWNLOAD_EVENT_CANCELED = "canceled"
    private const val DOWNLOAD_EVENT_PAUSED = "paused"
    private const val DOWNLOAD_EVENT_RESUMED = "resumed"
    private const val DOWNLOAD_EVENT_ERROR = "error"

    private const val DOWNLOAD_STOP_REASON_PAUSE = 1
}
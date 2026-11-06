package com.example.noir_player

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Runs yt-dlp on the phone (through youtubedl-android) for Discover: finds a
 * song's YouTube video, gives a stream link for playing it and downloads its
 * audio. The phone asks YouTube itself, so the links work on its own
 * connection and there's no API key or quota.
 *
 * Methods on "noir/ytdlp":
 *  - resolve(target): yt-dlp's JSON for the best audio of `target` (a
 *    "ytsearch1:..." query or a video URL), as a string.
 *  - download(target, dir, id, mp3): saves the audio into `dir` as `<id>.mp3`
 *    (or `<id>.m4a` when FFmpeg can't convert) and returns its path. Progress
 *    goes to the "noir/ytdlp/progress" event channel as {id, progress}.
 *  - cancel(id), update(), version().
 */
class YtDlpChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val executor = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val initLock = Any()

    @Volatile private var ready = false
    @Volatile private var ffmpegReady = false
    @Volatile private var events: EventChannel.EventSink? = null

    init {
        MethodChannel(messenger, "noir/ytdlp").setMethodCallHandler(this)
        EventChannel(messenger, "noir/ytdlp/progress").setStreamHandler(this)
        // Unpacking Python takes a few seconds the first time: do it early.
        executor.execute {
            try {
                ensureInit()
                refreshInBackground()
            } catch (_: Throwable) {
            }
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "resolve" -> run(result) {
                val target = call.argument<String>("target") ?: error("no target")
                resolve(target)
            }
            "download" -> run(result) {
                download(
                    target = call.argument<String>("target") ?: error("no target"),
                    dir = call.argument<String>("dir") ?: error("no dir"),
                    id = call.argument<String>("id") ?: error("no id"),
                    mp3 = call.argument<Boolean>("mp3") ?: true,
                )
            }
            "cancel" -> run(result) {
                val id = call.argument<String>("id") ?: error("no id")
                YoutubeDL.getInstance().destroyProcessById(id)
            }
            "update" -> run(result) {
                ensureInit()
                val status = YoutubeDL.getInstance().updateYoutubeDL(context)
                markUpdated()
                status?.name
            }
            "version" -> run(result) {
                ensureInit()
                YoutubeDL.getInstance().versionName(context)
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [work] off the main thread and answers on it. */
    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                val message = e.message ?: e.toString()
                main.post { result.error("ytdlp", message, null) }
            }
        }
    }

    private fun ensureInit() {
        synchronized(initLock) {
            if (ready) return
            YoutubeDL.getInstance().init(context)
            ffmpegReady = try {
                FFmpeg.getInstance().init(context)
                true
            } catch (_: Throwable) {
                false
            }
            ready = true
        }
    }

    // -- Keeping yt-dlp current ----------------------------------------------
    // YouTube changes often and the yt-dlp bundled in the app ages quickly, so
    // it updates itself from yt-dlp's GitHub releases: before the first use,
    // and then about once a day in the background.

    private val prefs by lazy {
        context.getSharedPreferences("noir_ytdlp", Context.MODE_PRIVATE)
    }

    private fun lastUpdated() = prefs.getLong("updatedAt", 0L)

    private fun markUpdated() {
        prefs.edit().putLong("updatedAt", System.currentTimeMillis()).apply()
    }

    private fun updateNow() {
        try {
            YoutubeDL.getInstance().updateYoutubeDL(context)
            markUpdated()
        } catch (_: Throwable) {
            // Offline or GitHub unreachable: keep the current yt-dlp.
        }
    }

    private fun refreshInBackground() {
        if (System.currentTimeMillis() - lastUpdated() > DAY_MS) {
            executor.execute { updateNow() }
        }
    }

    private fun ensureFresh() {
        ensureInit()
        if (lastUpdated() == 0L) updateNow() else refreshInBackground()
    }

    // -- Requests -------------------------------------------------------------

    private fun baseRequest(target: String) = YoutubeDLRequest(target).apply {
        addOption("-f", AUDIO_FORMAT)
        addOption("--no-playlist")
        addOption("--no-warnings")
        addOption("--socket-timeout", "15")
    }

    private fun resolve(target: String): String {
        ensureFresh()
        val request = baseRequest(target).apply { addOption("--dump-json") }
        val response = YoutubeDL.getInstance().execute(request)
        return response.out.lineSequence().firstOrNull { it.trimStart().startsWith("{") }
            ?: error("No matching YouTube video was found.")
    }

    private fun download(target: String, dir: String, id: String, mp3: Boolean): String {
        ensureFresh()
        File(dir).mkdirs()
        val convert = mp3 && ffmpegReady
        return try {
            downloadOnce(target, dir, id, convert)
        } catch (e: YoutubeDL.CanceledException) {
            throw e
        } catch (e: Throwable) {
            // Converting needs FFmpeg, which fails on some phones: keep the
            // original audio (.m4a) instead of failing the download.
            if (!convert) throw e
            downloadOnce(target, dir, id, false)
        }
    }

    private fun downloadOnce(target: String, dir: String, id: String, convert: Boolean): String {
        val request = baseRequest(target).apply {
            addOption("-o", "$dir/$id.%(ext)s")
            addOption("--no-part")
            addOption("--no-mtime")
            addOption("--force-overwrites")
            if (convert) {
                addOption("-x")
                addOption("--audio-format", "mp3")
                addOption("--audio-quality", "0")
            }
            addOption("--print", "after_move:filepath")
        }
        val response = YoutubeDL.getInstance().execute(
            request,
            processId = id,
            redirectErrorStream = false,
        ) { progress, _, _ ->
            val sink = events ?: return@execute
            main.post { sink.success(mapOf("id" to id, "progress" to progress.toDouble())) }
        }
        val path = response.out.lineSequence().map { it.trim() }
            .lastOrNull { it.startsWith("/") }
        if (path == null || !File(path).exists()) error("yt-dlp saved no file.")
        return path
    }

    companion object {
        /** m4a (AAC) first: plays everywhere; anything else as a fallback. */
        private const val AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio/best"
        private const val DAY_MS = 24L * 60 * 60 * 1000
    }
}

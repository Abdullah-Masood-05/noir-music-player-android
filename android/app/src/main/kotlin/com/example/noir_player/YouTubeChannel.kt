package com.example.noir_player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.Call
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.localization.ContentCountry
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.AudioTrackType
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.streams.Mp4DashReader
import org.schabi.newpipe.streams.Mp4FromDashWriter
import us.shandian.giga.io.FileStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Collections
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Discover's YouTube access on Android, through NewPipe Extractor
 * (https://github.com/TeamNewPipe/NewPipeExtractor): finds a song's video,
 * gives its audio stream and downloads it. The phone asks YouTube itself, so
 * there's no API key, no quota and nothing to unpack.
 *
 * Methods on "noir/youtube":
 *  - resolve(query | videoId): the best audio of the first matching song, as
 *    {videoId, title, durationMs, url, headers, contentLength, mime, ext}.
 *  - download(url, headers, contentLength, path, id): saves the stream to
 *    `path` in ranged chunks. Progress goes to "noir/youtube/progress" as
 *    {id, received, total}.
 *  - finish(input, output, title, artist, cover): turns YouTube's DASH M4A
 *    into a normal one (NewPipe's muxer) with the tags and cover inside.
 *  - cancel(id).
 */
class YouTubeChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val executor = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val downloader = NewPipeDownloader.create()
    private val downloads = ConcurrentHashMap<String, Download>()

    @Volatile private var events: EventChannel.EventSink? = null

    private class Download {
        @Volatile var cancelled = false
        val calls: MutableSet<Call> = Collections.newSetFromMap(ConcurrentHashMap())
    }

    init {
        val locale = Locale.getDefault()
        val country = locale.country.takeIf { it.length == 2 } ?: "US"
        NewPipe.init(
            downloader,
            Localization.fromLocale(locale),
            ContentCountry(country),
        )
        MethodChannel(messenger, "noir/youtube").setMethodCallHandler(this)
        EventChannel(messenger, "noir/youtube/progress").setStreamHandler(this)
        executor.execute { removeYtDlpLeftovers() }
    }

    /**
     * Test builds used yt-dlp, which unpacked Python, yt-dlp and FFmpeg (about
     * 125 MB) into the app's storage. Nothing uses them now: free the space.
     */
    private fun removeYtDlpLeftovers() {
        try {
            listOf(
                File(context.noBackupFilesDir, "youtubedl-android"),
                File(context.cacheDir, "ytdlp"),
            ).filter { it.exists() }.forEach { it.deleteRecursively() }
            for (prefs in listOf("youtubedl-android", "noir_ytdlp")) {
                val file = File(context.applicationInfo.dataDir, "shared_prefs/$prefs.xml")
                if (file.exists()) file.delete()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Couldn't remove yt-dlp's old files", e)
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
                resolve(call.argument<String>("query"), call.argument<String>("videoId"))
            }
            "download" -> run(result) {
                download(
                    url = call.argument<String>("url") ?: error("no url"),
                    headers = call.argument<Map<String, String>>("headers") ?: emptyMap(),
                    knownLength = call.argument<Number>("contentLength")?.toLong() ?: -1L,
                    path = call.argument<String>("path") ?: error("no path"),
                    id = call.argument<String>("id") ?: error("no id"),
                )
            }
            "finish" -> run(result) {
                finish(
                    input = call.argument<String>("input") ?: error("no input"),
                    output = call.argument<String>("output") ?: error("no output"),
                    title = call.argument<String>("title"),
                    artist = call.argument<String>("artist"),
                    cover = call.argument<ByteArray>("cover"),
                )
            }
            "cancel" -> run(result) {
                val id = call.argument<String>("id") ?: error("no id")
                downloads[id]?.let { job ->
                    job.cancelled = true
                    job.calls.forEach { it.cancel() }
                }
                null
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
                val message = describe(e)
                Log.e(TAG, message, e)
                main.post { result.error(errorCode(e), message, null) }
            }
        }
    }

    private fun errorCode(e: Throwable): String {
        var t: Throwable? = e
        while (t != null) {
            if (t is CancelledException) return "cancelled"
            t = t.cause.takeIf { it !== t }
        }
        return "youtube"
    }

    /** The error's own text and its causes, so nothing shows as a bare class name. */
    private fun describe(e: Throwable): String {
        val parts = mutableListOf<String>()
        var t: Throwable? = e
        while (t != null && parts.size < 4) {
            val msg = t.message?.trim()
            parts += if (msg.isNullOrEmpty()) t.javaClass.simpleName else "${t.javaClass.simpleName}: $msg"
            t = t.cause.takeIf { it !== t }
        }
        return parts.joinToString(" <- ")
    }

    // -- Finding and resolving ------------------------------------------------

    private fun resolve(query: String?, videoId: String?): Map<String, Any?> {
        val id = videoId ?: search(query ?: error("no query or videoId"))
        val extractor = ServiceList.YouTube.getStreamExtractor(
            "https://www.youtube.com/watch?v=$id",
        )
        extractor.fetchPage()
        val audio = pickAudio(extractor.audioStreams)
            ?: throw IOException("No playable audio was found for this song.")
        val url = audio.content
        val length = audio.itagItem?.contentLength?.takeIf { it > 0 }
            ?: Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.get(1)?.toLongOrNull()
            ?: -1L
        val m4a = audio.format == MediaFormat.M4A
        return mapOf(
            "videoId" to id,
            "title" to extractor.name,
            "durationMs" to extractor.length * 1000,
            "url" to url,
            "headers" to streamHeaders(url),
            "contentLength" to length,
            "mime" to if (m4a) "audio/mp4" else "audio/webm",
            "ext" to if (m4a) "m4a" else "webm",
        )
    }

    /**
     * The video id of the best match for [query]: YouTube Music's songs first
     * (the official audio, without video intros), any video otherwise.
     */
    private fun search(query: String): String {
        for (filter in listOf(
            YoutubeSearchQueryHandlerFactory.MUSIC_SONGS,
            YoutubeSearchQueryHandlerFactory.VIDEOS,
        )) {
            val found = try {
                val search = ServiceList.YouTube.getSearchExtractor(query, listOf(filter), "")
                search.fetchPage()
                search.initialPage.items.filterIsInstance<StreamInfoItem>().firstOrNull()
            } catch (e: Exception) {
                if (filter == YoutubeSearchQueryHandlerFactory.VIDEOS) throw e
                Log.w(TAG, "YouTube Music search failed, trying videos", e)
                null
            } ?: continue
            return ServiceList.YouTube.streamLHFactory.getId(found.url)
        }
        throw IOException("No matching YouTube video was found.")
    }

    /**
     * The song's own audio (not a dubbed or described track) as a direct
     * stream: M4A (AAC) first since it plays and tags everywhere, then the
     * highest bitrate.
     */
    private fun pickAudio(streams: List<AudioStream>): AudioStream? {
        val usable = streams.filter {
            it.isUrl && it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP
        }
        val own = usable.filter {
            it.audioTrackType != AudioTrackType.DUBBED &&
                it.audioTrackType != AudioTrackType.DESCRIPTIVE
        }.ifEmpty { usable }
        val original = own.filter { it.audioTrackType == AudioTrackType.ORIGINAL }.ifEmpty { own }
        return original.filter { it.format == MediaFormat.M4A }
            .ifEmpty { original }
            .maxByOrNull { it.averageBitrate }
    }

    /**
     * The headers YouTube expects for a stream link, depending on which of
     * its apps it was made for (the same rules as NewPipe's player).
     */
    private fun streamHeaders(url: String): Map<String, String> {
        val headers = mutableMapOf<String, String>()
        headers["User-Agent"] = when {
            YoutubeParsingHelper.isAndroidStreamingUrl(url) ->
                YoutubeParsingHelper.getAndroidUserAgent(null)
            YoutubeParsingHelper.isIosStreamingUrl(url) ->
                YoutubeParsingHelper.getIosUserAgent(null)
            YoutubeParsingHelper.isVisionOsStreamingUrl(url) ->
                YoutubeParsingHelper.getVisionOsUserAgent(null)
            else -> NewPipeDownloader.USER_AGENT
        }
        if (YoutubeParsingHelper.isWebStreamingUrl(url) ||
            YoutubeParsingHelper.isWebEmbeddedPlayerStreamingUrl(url)
        ) {
            headers["Origin"] = "https://www.youtube.com"
            headers["Referer"] = "https://www.youtube.com"
            headers["Sec-Fetch-Dest"] = "empty"
            headers["Sec-Fetch-Mode"] = "cors"
            headers["Sec-Fetch-Site"] = "cross-site"
        }
        return headers
    }

    // -- Downloading ----------------------------------------------------------

    private class CancelledException : IOException("Download cancelled")

    /**
     * Saves the stream at [url] to [path] in 1 MiB ranges, [PARALLEL] at a
     * time. YouTube serves short ranges at full speed (one long request gets
     * slowed to playback speed), and several at once fill the connection.
     */
    private fun download(
        url: String,
        headers: Map<String, String>,
        knownLength: Long,
        path: String,
        id: String,
    ): String {
        val job = Download()
        downloads[id] = job
        val file = File(path)
        file.parentFile?.mkdirs()
        file.delete()
        try {
            val total = if (knownLength > 0) knownLength else streamLength(url, headers, job)
            val received = AtomicLong(0)
            val lastReport = AtomicLong(0)
            val nextChunk = AtomicLong(0)
            val requestNumber = AtomicInteger(0)
            val failure = AtomicReference<Throwable?>(null)
            val chunks = (total + CHUNK - 1) / CHUNK

            RandomAccessFile(file, "rw").use { out ->
                out.setLength(total)
                val workers = (0 until minOf(PARALLEL.toLong(), chunks).toInt()).map {
                    Thread {
                        val buffer = ByteArray(64 * 1024)
                        while (failure.get() == null) {
                            val index = nextChunk.getAndIncrement()
                            if (index >= chunks) break
                            val from = index * CHUNK
                            val to = minOf(from + CHUNK, total) - 1
                            try {
                                fetchChunk(url, headers, from, to, requestNumber, job, buffer) { offset, n ->
                                    synchronized(out) {
                                        out.seek(offset)
                                        out.write(buffer, 0, n)
                                    }
                                    val sum = received.addAndGet(n.toLong())
                                    val now = System.currentTimeMillis()
                                    val last = lastReport.get()
                                    if (now - last >= 150 && lastReport.compareAndSet(last, now)) {
                                        report(id, sum, total)
                                    }
                                }
                            } catch (e: Throwable) {
                                failure.compareAndSet(null, e)
                                job.calls.forEach { it.cancel() }
                            }
                        }
                    }.apply { start() }
                }
                workers.forEach { it.join() }
            }
            failure.get()?.let { throw it }
            if (job.cancelled) throw CancelledException()
            report(id, total, total)
            return path
        } catch (e: Throwable) {
            file.delete()
            if (job.cancelled) throw CancelledException()
            throw e
        } finally {
            downloads.remove(id)
        }
    }

    /**
     * Fetches bytes [from]..[to] (inclusive), retrying twice, and hands each
     * piece to [write] with its file offset.
     */
    private fun fetchChunk(
        url: String,
        headers: Map<String, String>,
        from: Long,
        to: Long,
        requestNumber: AtomicInteger,
        job: Download,
        buffer: ByteArray,
        write: (offset: Long, n: Int) -> Unit,
    ) {
        var position = from
        var attempt = 0
        while (position <= to) {
            if (job.cancelled) throw CancelledException()
            try {
                val request = streamRequest(url, headers, position, to, requestNumber.getAndIncrement())
                val call = downloader.client.newCall(request)
                job.calls.add(call)
                try {
                    call.execute().use { response ->
                        if (response.code != 206) {
                            throw IOException("HTTP ${response.code} from YouTube")
                        }
                        val body = response.body ?: throw IOException("Empty answer from YouTube")
                        body.byteStream().use { input ->
                            while (position <= to) {
                                if (job.cancelled) throw CancelledException()
                                val want = minOf(buffer.size.toLong(), to - position + 1).toInt()
                                val n = input.read(buffer, 0, want)
                                if (n < 0) break
                                write(position, n)
                                position += n
                            }
                        }
                    }
                } finally {
                    job.calls.remove(call)
                }
                if (position <= to) throw IOException("YouTube stopped sending audio")
            } catch (e: CancelledException) {
                throw e
            } catch (e: IOException) {
                if (job.cancelled) throw CancelledException()
                // HTTP refusals won't change on a retry; dropped connections may.
                if (++attempt > 2 || e.message?.startsWith("HTTP 4") == true) throw e
                Thread.sleep(500L * attempt)
            }
        }
    }

    /** The stream's size, from the answer to a one-byte request. */
    private fun streamLength(url: String, headers: Map<String, String>, job: Download): Long {
        val call = downloader.client.newCall(streamRequest(url, headers, 0, 0, 0))
        job.calls.add(call)
        try {
            call.execute().use { response ->
                return response.header("Content-Range")?.substringAfterLast('/')?.toLongOrNull()
                    ?.takeIf { it > 0 }
                    ?: throw IOException("YouTube didn't give the audio's size")
            }
        } finally {
            job.calls.remove(call)
        }
    }

    private fun report(id: String, received: Long, total: Long) {
        val sink = events ?: return
        main.post {
            sink.success(mapOf("id" to id, "received" to received, "total" to total))
        }
    }

    /**
     * One ranged request for a stream link, the way NewPipe's player asks:
     * a POST with a tiny body and a request number, which YouTube's own apps
     * send too.
     */
    private fun streamRequest(
        url: String,
        headers: Map<String, String>,
        start: Long,
        end: Long,
        requestNumber: Int,
    ): Request {
        val target = if (url.contains("/videoplayback") && !url.contains("&rn=")) {
            "$url&rn=$requestNumber"
        } else {
            url
        }
        return Request.Builder()
            .url(target)
            .post(POST_BODY.toRequestBody())
            .apply { headers.forEach { (k, v) -> header(k, v) } }
            .header("Range", "bytes=$start-$end")
            .header("Accept-Encoding", "identity")
            .build()
    }

    // -- Finishing the file ---------------------------------------------------

    /**
     * Writes [input] (as YouTube sent it) to [output] as a normal M4A with the
     * title, artist and cover inside. YouTube's M4A is "fragmented" for
     * streaming, which some players and the media library read badly; NewPipe's
     * muxer rebuilds it. Anything that isn't fragmented is copied as it is.
     */
    private fun finish(
        input: String,
        output: String,
        title: String?,
        artist: String?,
        cover: ByteArray?,
    ): String {
        val src = File(input)
        val dst = File(output)
        dst.parentFile?.mkdirs()
        dst.delete()
        if (!isDash(src)) {
            src.copyTo(dst, overwrite = true)
            return output
        }
        val source = FileStream(src)
        val out = FileStream(dst)
        try {
            val muxer = Mp4FromDashWriter(source)
            muxer.setMainBrand(0x4D344120) // "M4A "
            muxer.setUserData(M4aTags.udta(title, artist, cover))
            muxer.parseSources()
            muxer.selectTracks(0)
            muxer.build(out)
        } catch (e: Throwable) {
            out.close()
            dst.delete()
            throw e
        } finally {
            source.close()
            out.close()
        }
        return output
    }

    /** Whether [file] is a DASH (fragmented) MP4, like NewPipe's M4aNoDash check. */
    private fun isDash(file: File): Boolean {
        val stream = FileStream(file)
        return try {
            val reader = Mp4DashReader(stream)
            reader.parse()
            when (reader.brands.firstOrNull()) {
                0x64617368, 0x69736F35 -> true // "dash", "iso5"
                else -> false
            }
        } catch (_: Throwable) {
            false
        } finally {
            stream.close()
        }
    }

    companion object {
        private const val TAG = "NoirYouTube"
        private const val CHUNK = 1024L * 1024
        private const val PARALLEL = 4
        private val POST_BODY = byteArrayOf(0x78, 0)
    }
}

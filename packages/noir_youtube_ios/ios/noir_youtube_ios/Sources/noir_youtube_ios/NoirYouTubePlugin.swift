import AVFoundation
import Flutter
import UIKit
#if canImport(YouTubeKit)
import YouTubeKit
#endif

/// The iOS side of Noir Player's "noir/youtube" channel.
///
/// YouTubeKit (MIT, https://github.com/alexeichhorn/YouTubeKit) finds a
/// video's audio on the phone, and AVFoundation rebuilds a downloaded file as
/// a normal M4A with its tags. Searching and downloading happen in Dart
/// (lib/core/services/youtube_native.dart).
public class NoirYouTubePlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "noir/youtube", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(NoirYouTubePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "resolve":
            #if !canImport(YouTubeKit)
            // Built with CocoaPods only (see the podspec): no YouTubeKit.
            result(FlutterError(code: "youtube", message: "This build can't reach YouTube itself.", details: nil))
            return
            #else
            guard let videoID = args["videoId"] as? String, !videoID.isEmpty else {
                result(FlutterError(code: "youtube", message: "No matching YouTube video was found.", details: nil))
                return
            }
            run(result) { try await Self.resolve(videoID: videoID) }
            #endif

        case "finish":
            guard let input = args["input"] as? String, let output = args["output"] as? String else {
                result(FlutterError(code: "youtube", message: "finish: no input or output", details: nil))
                return
            }
            let title = args["title"] as? String
            let artist = args["artist"] as? String
            let cover = (args["cover"] as? FlutterStandardTypedData)?.data
            run(result) {
                try await Self.finish(input: input, output: output, title: title, artist: artist, cover: cover)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Runs [work] off the main thread and answers on it.
    private func run(_ result: @escaping FlutterResult, _ work: @escaping () async throws -> Any?) {
        Task {
            do {
                let value = try await work()
                DispatchQueue.main.async { result(value) }
            } catch {
                let message = Self.describe(error)
                DispatchQueue.main.async {
                    result(FlutterError(code: "youtube", message: message, details: nil))
                }
            }
        }
    }

    // MARK: - Resolve

    #if canImport(YouTubeKit)

    /// The best audio of [videoID]: M4A (AAC) when there is one, highest
    /// bitrate. Answered in the same shape as the Android side.
    static func resolve(videoID: String) async throws -> [String: Any] {
        let video = YouTube(videoID: videoID, methods: [.local])
        let streams = try await video.streams
        let audio = streams.filter { $0.includesAudioTrack && !$0.includesVideoTrack }
        let m4a = audio.filter { $0.fileExtension == .m4a }
        let pool = m4a.isEmpty ? audio : m4a
        guard let pick = pool.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) else {
            throw Failure("No playable audio was found for this song.")
        }
        // A video with an ad before it only serves its streams once the ad
        // would have ended; asking earlier gets HTTP 403.
        try await pick.waitUntilAvailable()

        let query = URLComponents(url: pick.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }

        var map: [String: Any] = [
            "videoId": videoID,
            "url": pick.url.absoluteString,
            "headers": headers(forClient: param("c")),
            "contentLength": Int(param("clen") ?? "") ?? -1,
            "mime": pick.fileExtension == .m4a ? "audio/mp4" : "audio/webm",
            "ext": pick.fileExtension == .m4a ? "m4a" : "webm",
            // Fetched with plain GETs, not NewPipe's POSTs.
            "post": false,
        ]
        if let seconds = Double(param("dur") ?? ""), seconds > 0 {
            map["durationMs"] = Int(seconds * 1000)
        }
        return map
    }

    /// The headers YouTube expects for a stream link from [client] (the
    /// link's "c" parameter): the user agent of the app that asked for it.
    static func headers(forClient client: String?) -> [String: String] {
        let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15"
        switch client?.uppercased() {
        case "VISIONOS":
            return ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"]
        case "TVHTML5":
            return ["User-Agent": "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1"]
        case "IOS":
            return ["User-Agent": "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"]
        case let name? where name.hasPrefix("ANDROID"):
            return ["User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"]
        default:
            return [
                "User-Agent": safari,
                "Origin": "https://www.youtube.com",
                "Referer": "https://www.youtube.com/",
            ]
        }
    }

    #endif

    // MARK: - Finish

    /// Rewrites the downloaded [input] (YouTube's fragmented "DASH" M4A) as a
    /// normal M4A at [output] with the title, artist and cover inside. The
    /// audio is copied, not re-encoded.
    static func finish(input: String, output: String, title: String?, artist: String?, cover: Data?) async throws -> String {
        // AVFoundation goes by the file extension: give it an .m4a name.
        let source = URL(fileURLWithPath: output).deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".src.m4a")
        let files = FileManager.default
        do {
            try files.linkItem(atPath: input, toPath: source.path)
        } catch {
            try files.copyItem(atPath: input, toPath: source.path)
        }
        defer { try? files.removeItem(at: source) }

        let target = URL(fileURLWithPath: output)
        try? files.removeItem(at: target)

        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure("Couldn't rebuild the song file.")
        }
        export.outputURL = target
        export.outputFileType = .m4a

        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, dataType: String? = nil) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            items.append(item)
        }
        if let title, !title.isEmpty { add(.iTunesMetadataSongName, title as NSString) }
        if let artist, !artist.isEmpty { add(.iTunesMetadataArtist, artist as NSString) }
        if let cover, !cover.isEmpty {
            let png = cover.starts(with: [0x89, 0x50, 0x4E, 0x47])
            add(.iTunesMetadataCoverArt, cover as NSData,
                dataType: (png ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String)
        }
        export.metadata = items

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else {
            try? files.removeItem(at: target)
            throw export.error ?? Failure("Couldn't rebuild the song file.")
        }
        return output
    }

    // MARK: - Errors

    /// The error as text the Dart side recognises (see friendlyYouTubeError).
    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        #if canImport(YouTubeKit)
        if let kit = error as? YouTubeKitError {
            // Names like "videoAgeRestricted" or "videoRegionBlocked".
            return "YouTubeKitError.\(kit.rawValue)"
        }
        #endif
        if let url = error as? URLError {
            return "URLError \(url.code.rawValue): \(url.localizedDescription)"
        }
        let text = String(describing: error)
        return text.isEmpty ? error.localizedDescription : text
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

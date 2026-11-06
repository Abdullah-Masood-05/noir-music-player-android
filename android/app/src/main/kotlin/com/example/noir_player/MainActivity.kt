package com.example.noir_player

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // yt-dlp for Discover (play and download).
        YtDlpChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}

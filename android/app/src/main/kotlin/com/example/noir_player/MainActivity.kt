package com.example.noir_player

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // YouTube for Discover (find, play and download), via NewPipe Extractor.
        YouTubeChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}

# youtubedl-android (yt-dlp on the phone) reads yt-dlp's JSON with Jackson and
# loads its native helpers by name: keep its classes as they are.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.**

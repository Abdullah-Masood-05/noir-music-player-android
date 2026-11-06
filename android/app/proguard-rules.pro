# youtubedl-android (yt-dlp on the phone). Its own ProGuard rules apply only
# when the library itself is built, not to apps using it, so they're repeated
# here.
#
# commons-compress unpacks Python, yt-dlp and FFmpeg on first launch. Its zip
# reader registers its "extra field" classes by name, which breaks once R8
# renames them (the Discover error "J2.f" was ExtraFieldUtils failing to load).
-keep class com.yausername.** { *; }
-keep class org.apache.commons.compress.** { *; }
-keep class org.apache.commons.io.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-dontwarn org.apache.commons.compress.**
-dontwarn org.apache.commons.io.**
-dontwarn com.fasterxml.jackson.**

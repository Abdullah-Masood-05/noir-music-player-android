# CocoaPods description of Noir Player's iOS YouTube plugin.
#
# The real build uses Swift Package Manager (Package.swift next to this
# folder's sources), because YouTubeKit is only published as a Swift package.
# Flutter still wants a podspec on machines without Swift Package Manager
# support (Linux, Windows), so this one exists. Built with CocoaPods alone,
# the plugin compiles without YouTubeKit and Discover uses the server instead.
Pod::Spec.new do |s|
  s.name             = 'noir_youtube_ios'
  s.version          = '1.0.0'
  s.summary          = "Noir Player's iOS side of the noir/youtube channel."
  s.homepage         = 'https://github.com/Abdullah-Masood-05/noir-music-player-android'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Noir Player' => 'noreply@github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'noir_youtube_ios/Sources/noir_youtube_ios/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end

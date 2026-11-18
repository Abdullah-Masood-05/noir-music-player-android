# Noir Player's changes to audio_service

This is [audio_service](https://pub.dev/packages/audio_service) 0.18.19 from pub.dev
(the `example/` and `test/` folders left out), with two files changed so lock-screen
and media-panel buttons reach the app on OnePlus, Oppo and Vivo phones
(https://github.com/ryanheise/audio_service/issues/1115, still open upstream):

- `android/src/main/java/com/ryanheise/audioservice/AudioService.java`: PLAY maps to
  its real key code, media-button intents are handled directly, and the seek
  actions are also offered as notification actions.
- `android/src/main/java/com/ryanheise/audioservice/MediaButtonReceiver.java`: media
  buttons go straight to the running session.

To update: take the new release, drop in these two files, and check that upstream
didn't change them (if it did, merge by hand).

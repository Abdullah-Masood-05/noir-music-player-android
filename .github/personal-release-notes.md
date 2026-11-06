> [!WARNING]
> **Personal test build — not an official Noir Player release.** For the normal app, download the latest release instead.

This build exists only to show Noir Player in **OnePlus / OPPO Live Alerts** (the "dynamic island" pill) on OxygenOS / ColorOS 15, where the system only shows music apps whose package name is on its built-in allowlist.

**What's different from the normal app**
- It uses the package name `com.blueocean.huoledj`, which belongs to an unrelated music app on that allowlist. Noir Player is not affiliated with that app.
- It installs **next to** the normal Noir Player as a separate app called **Noir Player Live**, with its own library scan, playlists and settings.
- Built from branch [`personal/oneplus-live-alerts`](https://github.com/Abdullah-Masood-05/noir-music-player-android/tree/personal/oneplus-live-alerts) (same code as Noir Player plus the package name and app label).

**Known caveats**
- If the app that really owns `com.blueocean.huoledj` is installed, this build can't be installed (and vice versa).
- Google Play Protect may warn about it because the package name belongs to another developer.
- OnePlus can change its allowlist at any time, so the pill may stop appearing after a system update. OxygenOS 16 shows any music player as a Live Alert, so this build isn't needed there.
- It doesn't receive in-place updates from the normal Noir Player releases.

**This build:** Noir Player {version}. Discover now reaches YouTube with NewPipe Extractor (the library behind the NewPipe app) instead of yt-dlp, so the app is much smaller (about 21 MB instead of 63 MB for arm64) and songs start faster. Songs are found on YouTube Music first, downloads show real progress and are saved as M4A with the cover, title and artist inside, and a downloaded song you delete loses its tick. The space yt-dlp took in the previous test build is freed on first launch. It updates the previous Noir Player Live build in place — same package name and signing key.

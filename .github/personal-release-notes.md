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

**This build:** Noir Player {version}. The progress bar in the notification, on the lock screen and in Live Alerts now works for Discover songs, a Discover song that fails to load is retried once and explains why if it still fails, and a song resumed after YouTube (or another app) paused it plays with sound again. It updates the previous Noir Player Live build in place — same package name and signing key.

# Marquee (working title)

An original Apple Vision Pro app (visionOS 26) for watching movies and TV from your own Plex Media Server. It's written from scratch with Apple's frameworks (SwiftUI, AVKit/AVFoundation, RealityKit) and Plex's public web APIs. It has **no third-party dependencies**.

> Not affiliated with Plex, Inc.

## Build on your Mac (first time)

You need Xcode, an Apple Vision Pro paired with Xcode, and [Homebrew](https://brew.sh).

1. Open **Terminal** and go to the project folder (the folder that holds `project.yml`):
   ```sh
   cd ~/Developer/<repo-name>
   ```
2. Install XcodeGen (one time only):
   ```sh
   brew install xcodegen
   ```
3. Generate the Xcode project:
   ```sh
   xcodegen
   ```
4. Open it:
   ```sh
   open Theater.xcodeproj
   ```
5. In Xcode, click the blue **Theater** project icon at the top of the left sidebar. Select the **Theater** target, open the **Signing & Capabilities** tab, and choose your team in the **Team** menu.
6. In the toolbar at the top, pick your **Apple Vision Pro** as the run destination, then press **⌘R**.

Run `xcodegen` again whenever files are added or `project.yml` changes (after a `git pull`).

## Renaming the app

Edit the two lines marked "Rename the app here" in `project.yml` (`APP_DISPLAY_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`). Then run `xcodegen` again.

## Layout

| Folder | What's inside |
| --- | --- |
| `Sources/App` | App entry point, scenes, and the account/server session |
| `Sources/Plex` | plex.tv sign-in (PIN), server discovery, server API, models, and the Keychain |
| `Sources/Views` | Home, libraries, show/season/episode, detail, search, settings |
| `Sources/Player` | AVPlayer playback, direct play vs. transcode decision, and controls |
| `Sources/Theater` | Theater modes and immersive environments |
| `Resources` | Info.plist additions, privacy manifest, and asset catalog |

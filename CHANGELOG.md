# CHANGELOG
> N=new feature, E=error fix, F=fine-tune, R=refactor, I=infrastructure, T=tag

## Unreleased
- N: Build the theme list from assets/colors.json, so a palette is data rather than code
- N: Build the language list from the _language_name section of locales.json, names included
- E: Show language codes as-is instead of running them through lw(), which printed (( EN ))
- E: Load translations by the code used in locales.json, so Ukrainian is found at all
- E: Rebuild the home screen on a language or theme change; a const widget kept the old strings
- I: Enable core library desugaring, required by flutter_local_notifications
- I: Align plugin subprojects on JVM target 17 without touching the already evaluated app project
- I: Rework the build scripts after BikeTracker: 10 builds and bumps without needing a clean tree, 11/12 install, 20 tags, 21 pushes, 22 uploads, 99 makes the .apkx
- I: Pin every subproject to JVM target 17, so plugins without compileOptions stop breaking the build
- I: Pin receive_sharing_intent to 1.8.1, since 1.9.0 breaks the Gradle build with a kotlin {} block and no Kotlin plugin
- I: Drop the 32-bit armeabi-v7a build, keep arm64 and x86_64 only
- I: Sign release builds with the shared release key instead of the debug one, enable minify and shrink with keep rules
- N: Retry button re-sends only the files that failed, finding the device by id so a new IP still works
- N: Drag and drop files and folders onto the desktop window
- N: Android side: foreground service with wake and Wi-Fi locks, background receiving, share menu, accept prompt as a notification
- N: Sending files and folders with streamed upload, per-file CRC32 and automatic resend of a corrupted file
- N: Receive server writing to .easysend-part and renaming only after the checksum matches
- N: UDP discovery on the local subnet, manual devices by IP polled over HTTP
- N: Single-screen UI: pick, device list, one byte-based progress bar, port-busy banner, settings
- I: Project scaffold on Flutter 3.41 with EN/RU/UA localization, launcher icons and build scripts

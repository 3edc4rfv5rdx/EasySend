# CHANGELOG
> N=new feature, E=error fix, F=fine-tune, R=refactor, I=infrastructure, T=tag

## Unreleased
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

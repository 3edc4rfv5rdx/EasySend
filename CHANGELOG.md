# CHANGELOG
> N=new feature, E=error fix, F=fine-tune, R=refactor, I=infrastructure, T=tag

## Unreleased
- N: Android side: foreground service with wake and Wi-Fi locks, background receiving, share menu, accept prompt as a notification
- N: Sending files and folders with streamed upload, per-file CRC32 and automatic resend of a corrupted file
- N: Receive server writing to .easysend-part and renaming only after the checksum matches
- N: UDP discovery on the local subnet, manual devices by IP polled over HTTP
- N: Single-screen UI: pick, device list, one byte-based progress bar, port-busy banner, settings
- I: Project scaffold on Flutter 3.41 with EN/RU/UA localization, launcher icons and build scripts

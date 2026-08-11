# Checks to run on real hardware

Things that cannot be settled by reading the code or by a test on the desktop.
Each one says what to do, what to watch, and what the answer decides.

## Multicast lock ownership (from `tofix2.md` finding 11)

`MainActivity.kt` holds the `WifiManager.MulticastLock` and releases it in
`onDestroy()`. With `Receive in background` on, the foreground service keeps the
process alive while the Activity can be destroyed at any time — after which the
lock is gone, but `DiscoveryService` is still running and still believes it
holds one. Whether that actually stops multicast and broadcast datagrams from
arriving is device-dependent: some ROMs deliver them without the lock at all.

**Check.** Two phones, or a phone and the desktop build. On the phone: switch
`Receive in background` on, put the app in the background, then get the Activity
destroyed (Developer options → "Don't keep activities", or push it out of memory
with other apps). From the other device, open EasySend and watch whether the
phone is still in the list after a minute, and whether a transfer to it still
starts. Repeat with the Activity alive as the control.

**What it decides.** If the phone disappears from the list, the lock has to move
into `TransferService` (or the Application object) and be tied to whether
discovery is running rather than to the Activity's lifetime. If it stays
visible, the finding is not real on this hardware and should be recorded as
such — and the lock can arguably be dropped altogether.

**Note while testing.** The `/api/v1/info` poll of a manually added device does
not need multicast, so a manual entry will keep working either way. Judge by
automatic discovery only.

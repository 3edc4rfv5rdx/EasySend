# Checks to run on real hardware

Things that cannot be settled by reading the code or by a test on the desktop.
Each one says what to do, what to watch, and what the answer decides.

## Multicast lock ownership (from `tofix2.md` finding 11)

`MainActivity.kt` holds the `WifiManager.MulticastLock` and releases it in
`onDestroy()`. With `Receive in background` on, the foreground service keeps the
process alive while the Activity can be destroyed at any time — after which the
lock is gone, but `DiscoveryService` is still running and still believes it
holds one. Whether that actually stops datagrams from arriving is
device-dependent: some ROMs deliver them without the lock at all.

**What the lock actually governs.** Receiving, not sending. A phone without it
keeps broadcasting its own announce every five seconds and therefore stays in
everyone else's list; what it loses is hearing other devices — their announces,
and the `query` a newcomer sends to be answered at once. Finding 11 says the
phone "quietly disappears from every other device's list", and that is the wrong
way round. Judge the run by whether the phone **answers a newcomer's query** and
whether its own device list stays populated, not by whether other devices can
see it.

**Not on the emulator.** The lock turns off multicast filtering in a real Wi-Fi
chipset. An emulator's Wi-Fi is virtual and behind NAT, broadcast and multicast
do not reach the host's LAN from it, and `createMulticastLock` there is close to
a no-op — so it would report success whether or not the lock is held.

**Not from this desktop either.** Established 2026-08-11: this machine has no
Wi-Fi hardware at all, only wired Ethernet on `192.168.54.0/24`, while the phone
is on Wi-Fi at `192.168.204.0/24`. Broadcast and multicast do not cross a
router, so no probe from here can reach the phone's segment. Unicast is routed
between the two, which is exactly why the misleading half still works — see
below.

**Both devices must be on the same Wi-Fi.** Two phones, or a phone and a laptop
running the Linux build on that network.

**The trap.** A manually added device is polled over `/api/v1/info`, which is
plain unicast HTTP and needs no multicast whatever. Two devices that "see each
other" that way prove nothing here. On 2026-08-11 the phone was saved on the
desktop as `manual: true, trusted: true`, and twelve seconds of listening on
`239.255.53.53:15353` from the desktop produced only the desktop's own
announces — none from the phone. Before judging anything, remove the manual
entry and confirm the device appears by discovery alone.

**Check.** On the phone: switch `Receive in background` on, put the app in the
background, then get the Activity destroyed (Developer options → "Не сохранять
объекты Activity" / "Don't keep activities"). From the other device, open
EasySend fresh so it sends a `query`, and watch whether the phone answers it
within a few seconds and appears without being added by hand. Repeat with the
Activity alive as the control.

**What makes the run valid.** The point is an Activity that is dead while the
process is alive. If the process went too, the server and discovery went with it
and the result says nothing about the lock. The sign to watch is the ongoing
"Ready to receive" notification: no notification, no valid run. "Don't keep
activities" forces the destruction immediately instead of waiting for the system
to want the memory; turn it back off afterwards, since it applies to every app
and makes anything else tested alongside it behave oddly. Do not confuse it with
"приостановить исполнение кэшированных приложений", which freezes cached
processes instead and would spoil the run.

**What it decides.** If the phone stops answering queries while the Activity is
dead, the lock has to move into `TransferService` (or the Application object)
and be tied to whether discovery is running rather than to the Activity's
lifetime. If it keeps answering, the finding is not real on this hardware and
should be recorded as such — and the lock can arguably be dropped altogether.

### What was already established on 2026-08-11

With build 0.2.260811+66 on a Samsung SM-A366B, driven over adb:

- The process survives the Activity being destroyed: same pid before and after
  HOME, Activity records in `dumpsys activity activities` dropping from 17 to 9.
- `Receive in background` was **off** during that run, and the HTTP server
  stopped answering the moment the app left the screen — which is the behaviour
  SPEC 7 specifies for that switch, not a defect. Nothing about background
  operation can be judged until the switch is on.
- Returning to the foreground brought the server back in the same process, so
  the resume path works on real hardware.

Still open: everything that needs the two devices on one Wi-Fi.

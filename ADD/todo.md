# Checks to run on real hardware

Things that cannot be settled by reading the code or by a test on the desktop.
Each one says what to do, what to watch, and what the answer decides.

## + Multicast lock ownership (from `tofix2.md` finding 11)

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

**A competing explanation, to rule out first.** `MainActivity` is a plain
`FlutterActivity` with no cached engine, and such an activity creates its own
`FlutterEngine` and destroys it in `onDestroy`. If that is what happens, the
Dart isolate dies with the Activity and takes the HTTP server and discovery with
it, while `TransferService` stays alive showing "Ready to receive" — a
notification promising a receive that nothing is listening for, which would be a
worse defect than the lock and would look exactly the same from the other
device. This is reasoning from the class in use, not something observed: the run
on 2026-08-11 had background receiving off and so could not tell.

Ask it first, and by unicast, which needs no multicast at all: with the Activity
dead, does `curl http://<phone>:15353/api/v1/info` still answer? No answer means
the engine, not the lock, and nothing about multicast can be concluded until
that is fixed.

**The lock has already been moved.** As of 2026-08-11 it lives in
`EasySendApplication` and is released only when discovery says it has stopped,
so this run confirms a fix rather than choosing between guesses. The ownership
was wrong on its own terms — Dart asked once and never again while `onDestroy`
gave the lock back — and that is true whatever any single device does.

**Read the result asymmetrically.** Both phones here are Samsung, which is one
Wi-Fi chipset and one ROM family. If discovery works with the Activity dead,
that confirms the fix on this hardware and nothing more; it is **not** grounds
for deciding the lock was unnecessary and removing it, because another chipset
may well filter multicast where this one does not. Only the positive direction
generalizes: if it turns out to be needed here, it is needed everywhere.

**What it decides.** Three outcomes:

- Answers `/info` and appears by itself on a device that has never seen it: the
  fix works, close finding 11 as confirmed.
- Answers `/info` but never appears until added by hand: the lock was not the
  whole story. Check that discovery is actually running in that state at all
  (announces leaving the phone), before looking further at the chipset.
- Does not answer `/info` at all: it is the engine, not the lock. That is a new
  finding of its own — background receiving does not work at all once the
  Activity is gone, and the fix is a cached `FlutterEngine` that outlives it.

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

### Settled on 2026-08-12 — first outcome, the fix works

Build 0.2.260812+75 on both phones, A = SM-A366B on USB, B = Galaxy A12 on the
same Wi-Fi (`odrex19`, WPA2, 192.168.0.0/24). `Receive in background` on, HOME
pressed, Activity destroyed by "Don't keep activities".

- The Activity was really gone while the process lived: its history record read
  `app=null` with pid 11707 still running `EasySendApplication`.
- In that state `netstat` showed `0.0.0.0:15353` listening on **both** TCP and
  UDP, and `/api/v1/info` answered over an `adb forward` — so the competing
  explanation is ruled out. The cached `FlutterEngine` keeps the isolate, the
  server and discovery alive without an Activity.
- B, launched from cold so that it sent a `query`, listed `A36` in under a
  second — faster than the 5 s announce period, so A *heard* the query and
  answered it. That is reception, which is what the lock governs.

Finding 11 is confirmed on this hardware. Read it asymmetrically, as set out
above: reception was exercised on the A36 only — the A12 acted as the newcomer
and said nothing about its own multicast path — so this is one data point and
**not** grounds for removing the lock. A mirrored run with the phones swapped
would give the second.

Two things noticed in passing, neither blocking. `myPrint` is silent in release
by design (finding 17 in `tofix2.md`), so on a real build the only diagnostics
are adb-side: `netstat`, `dumpsys activity activities`, `adb forward` + `curl`.
And `net_discovery.dart:90` asks for `reusePort` on Android, where bionic has no
`SO_REUSEPORT`: Dart prints `Dart Socket ERROR ... not supported on this
platform` to logcat and ignores the option, the bind succeeds regardless.

Two traps worth repeating for the next run. Guest Wi-Fi with client isolation
(here `odrex_free`) leaves both phones in one /22 and still unable to ARP each
other — check `ping` between them before blaming the app. And "Don't keep
activities" must be switched back off afterwards; it was restored to 0 at the
end of this run.

### The mirrored run, same day — a defect, not a confirmation

The run above destroyed the Activity with "Don't keep activities" and left the
task in Recents. That is one of two ways a user loses the screen, and only that
one is covered by the result above.

Swapping the phones exposed the other. On the A12 (SM-A127F, Exynos 850,
Android 13) the same global setting is ignored by the ROM — it was already on in
Developer options, and neither `settings put` nor a 0->1 cycle made the Activity
finish — so the run used the path finding 11 itself prescribes: swipe the app out
of Recents. With `Receive in background` on, that leaves the process alive, the
service `isForeground=true` and the notification reading "Готов принимать",
while 15353 is closed on both protocols and `/api/v1/info` is silent. Stable, no
self-recovery: reopening the app draws a perfectly normal UI that still listens
on nothing and finds no devices, and only `am force-stop` plus a fresh start
brings the sockets back. The cause turned out to be `_exitApp` and the app's own
✕ button, not the ROM or the chipset — see finding 5 in `ADD/tofix3.md`. Fixed
the same day; a build carrying the fix still needs a run on hardware.

So the lock could not be exercised on the A12 at all — there was no receiver
left to hear anything — and the second chipset remains unmeasured. The finding
is written up under finding 5 in `ADD/tofix3.md`.

Still open: whether swiping out of Recents does the same on the A366B. Until
that is known, treat the A366B result as covering Activity destruction only.

### + Settled on 2026-08-13 — the A366B survives the swipe

Build 0.2.260813+85 on the A366B, driven over adb. `Receive in background`
switched on from a cold state (it had been off), HOME, then the card swiped out
of Recents.

- Same process before and after: pid 10650 both times.
- `TransferService` still `isForeground=true`, `types=0x40000000`
  (`FOREGROUND_SERVICE_TYPE_SPECIAL_USE`), and the ongoing notification id=1 on
  `easysend_transfer` still posted with one action — Exit only, which is what
  SPEC prescribes when no transfer is running.
- `netstat` showed `0.0.0.0:15353` listening on **both** TCP and UDP, and
  `/api/v1/info` answered over an `adb forward` with the real device record
  (`"name":"A36","version":"0.2.260813"`).

So the notification is telling the truth on this phone: the receiver really is
listening after the card is gone. That is the state the A12 failed in on
2026-08-12, before finding 5 in `ADD/tofix3.md` was fixed; this run confirms the
fix on the A366B. The A12 has not been re-run on a build carrying it.

Not covered by this run: the multicast path was not exercised — the second phone
was not on the network and this desktop cannot reach the phone's segment — so
this says nothing new about finding 11. Only unicast readiness was measured.

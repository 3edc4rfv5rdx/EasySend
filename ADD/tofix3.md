# EasySend deep code audit — 2026-08-11

This audit treats `README.md`, `SPEC.md`, the executable tests, the locked
Flutter/Android toolchain, and current runtime code as the product contract. It
does not repeat the resolved findings in `ADD/tofix1.md` or `ADD/tofix2.md`.

## System model and invariants

- `HomeScreen` owns lifecycle coordination, selection state, and network
  start/stop intent. `ReceiveServer`, `SendService`, `DiscoveryService`, and
  `ManualPoller` own their respective mutable workflows.
- A send is prepare -> sequential upload -> verify per file -> finish. A receive
  reserves one slot before parsing/consent and permits only one active operation
  in its explicit phase machine.
- Untrusted UDP and HTTP input crosses into global device state, consent UI, and
  filesystem writes. Settings cross a persistence boundary through an atomic
  replacement queue. Android crosses a process/Activity boundary through a
  foreground `Service` and one `MethodChannel`.
- Critical invariants are: verified user files are never deleted as temporary
  files; a receive never overwrites a name that became occupied; Move deletes
  only the exact source that was sent and obeys the cancellation promise; every
  bounded control exchange terminates; streaming remains bounded by
  backpressure; discovery describes a receiver that is actually ready; and an
  Android background listener outlives the Activity without violating platform
  service limits.

## Verification of the fixes — 2026-08-13

All seventeen findings were re-read against the code as it stands today, not
against the commit messages that claim them. Each heading names the commit that
closed it. The evidence is the current expression, cited per finding below.

Three of them were closed in the shape stated here, and a narrower failure
window survives the repair. Those windows are written up as separate findings in
`ADD/tofix4.md`, and neither file should be read without the other:

- Finding 1 -> `tofix4` finding 1. The suffix heuristic became a marker
  directory (`file_helpers.dart:22-24`), and the marker itself is forgeable by a
  transferred folder that contains the same bytes.
- Finding 2 -> `tofix4` finding 2. `_verify` now re-runs `uniquePath()` and
  `ensureSafeDestination()` before publishing (`net_server.dart:723-746`), but
  the publication is still a check-then-rename sequence with no exclusive claim.
- Finding 4 -> `tofix4` finding 3. The source is fingerprinted with SHA-256
  before deletion (`net_sender.dart:351-378`), which binds the bytes but not the
  filesystem object; a replacement installed after the last check is still
  deleted by path.

Evidence for the rest, in the current code:

- 3: `net_sender.dart:127-141` — sources are deleted after `_sendOneByOne`
  returns and only for `item.done`, with `_cancelled` checked first.
- 5: `MainActivity.kt:161` — `provideFlutterEngine` returns the Application's
  cached engine, so the isolate outlives the Activity.
- 6: `TransferService.kt:244` — `onTimeout` is implemented; the manifest declares
  `dataSync|specialUse` with `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`. Confirmed on
  hardware the same day: the running service reports `types=0x40000000`.
- 7: `settings_screen.dart:295` and `home_screen.dart:390` — the switch and the
  resume path both refuse to enable background receiving without permission.
- 8: `net_server.dart:137`, `net_sender.dart:72` — both sides bound a control
  body by `protocolBodyTotalTimeoutSec` as well as per-event.
- 9: `net_server.dart:43-48` — every chunk is awaited through `flush()`, which
  couples the socket read to the disk.
- 10: `net_discovery.dart:203-257` — `_reconcileInterfaces()` runs on each tick
  and joins and leaves as interfaces come and go.
- 11: `net_discovery.dart:326-369` — transient devices, new peers per window and
  new peers per source are all capped.
- 12: `globals.dart:497-506` — `SerialQueue.add` catches, logs and keeps the
  tail runnable, which is what the poisoning depended on.
- 13: `settings_screen.dart:131`, `settings_helpers.dart:87` — both paths go
  through the shared `validateDeviceName`/`isValidDeviceName`.
- 14: `net_sender.dart:130-133, 185-208` — the finish response decides between
  `done` and `partial` and is logged when it fails.
- 15: `home_screen.dart:425-433` — discovery starts only when
  `receiveServer.start()` reported readiness.
- 16: `models.dart:214, 259` — progress is stated as one monotonic invariant
  shared by both sides.
- 17: `10-MakeRelease.sh:114-179` — collection and renaming happen before the
  version bump is committed.

## Findings

### 1. P0 [FIXED 8b13120] — A valid file whose name ends in `.easysend-part` is deleted on the next startup

**Affected components:** `lib/file_helpers.dart` (`partSuffix`,
`cleanupOrphanParts`, `sweepOrphanPartsOnce`), `lib/net_server.dart` upload and
verify finalization, `test/session_recovery_test.dart`.

**Current behavior and reproduction:** Send and verify a legitimate file named
`report.easysend-part`. Its upload temporary is
`report.easysend-part.easysend-part`, and verification renames that to the valid
final name `report.easysend-part`. Restart EasySend. `cleanupOrphanParts()` walks
the receive tree and deletes every regular file for which
`entity.path.endsWith(partSuffix)` is true, so it deletes the completed file.
The existing recovery test calls every suffix-matching file an orphan and does
not cover a verified final file with that legal name.

**Root cause:** Temporary ownership is encoded only by a filename suffix that is
also legal in a wire manifest and as a final user filename. Startup recovery has
no session marker, ledger, directory, or other evidence that a matching file was
actually created as an incomplete EasySend write.

**Required outcome:** Recovery must delete only incomplete files owned by
EasySend. Any legal incoming filename, including names ending in one or several
copies of `.easysend-part`, must survive verification and every later startup.

**Constraints:** Keep incomplete writes hidden behind non-final names; keep
crash recovery recursive and do not follow symlinks; do not weaken path
containment or CRC-before-finalization.

**Acceptance tests:** Transfer `a.easysend-part` and
`a.easysend-part.easysend-part`, restart/sweep, and assert both verified files
remain byte-for-byte intact. Create genuine interrupted temporaries at the root
and in a nested directory and assert they are removed. Place a similarly named
file beyond a symlink and assert it is untouched.

### 2. P0 [FIXED dcfc41e] — A file created after prepare can be silently overwritten at verify

**Affected components:** `lib/file_helpers.dart` (`buildDestinationPlan`,
`ensureSafeDestination`), `lib/net_server.dart` (`_prepare`, `_verify`).

**Current behavior and reproduction:** Prepare a manifest for `photo.jpg` when
that name is free. Before the upload is verified, create a regular
`photo.jpg` in the receive folder (for example, a browser download finishes
during the consent or transfer window). `_verify()` rechecks containment, but
`ensureSafeDestination()` permits a regular file as the final component; then
`part.rename(dest)` replaces the late file on platforms where rename-over-file
is supported. The promised `photo (1).jpg` collision behavior is applied only
at prepare time.

**Root cause:** The destination plan is an in-memory reservation, not an
exclusive filesystem claim. The final safety check rejects links and
directories but deliberately treats an occupied regular destination as safe,
and finalization has no no-clobber guarantee.

**Required outcome:** No receive finalization may replace a pre-existing or
late-created filesystem entry. A destination must either be exclusively
reserved for the session or atomically finalized with no-replace semantics;
when a late collision occurs, choose a fresh conflict name safely or fail that
file without touching either file.

**Constraints:** Preserve the current whole-manifest duplicate planning,
case-folding on Windows, symlink containment checks, temporary-file cleanup,
and the ` (n)` user-visible naming convention.

**Acceptance tests:** Prepare `same.txt`, create `same.txt` before verify, and
assert its contents remain unchanged while the incoming bytes either land at
`same (1).txt` or the file fails cleanly. Repeat with a collision created just
before finalization, a destination symlink, Windows case-only names, and two
manifest entries competing for the same late fallback.

### 3. P0 [FIXED 0336505] — Cancelling a multi-file Move has already deleted completed sources

**Affected components:** `README.md` Move promise, `SPEC.md` section 3.1,
`lib/net_sender.dart` (`_sendOneByOne`, `_deleteSource`, `cancel`),
`test/move_after_send_test.dart`.

**Current behavior and reproduction:** Start a two-file send with Delete
originals enabled. Let the first file upload and verify, then hold the second
upload and press Stop. `_sendOneByOne()` deletes the first source immediately at
lines 232-236, before the transfer reaches a terminal outcome. `cancel()` then
marks the transfer cancelled, but cannot restore that source. Both README and
SPEC explicitly promise that a cancelled transfer deletes nothing; the current
cancellation test covers only cancellation during the first file.

**Root cause:** Source deletion is committed per verified file while
cancellation is a transfer-level terminal outcome. The implementation applies
the partial-transfer rule before it knows whether the transfer will be partial
or cancelled.

**Required outcome:** A cancelled transfer must leave every original in place.
Successful files may still be deleted for `done` and `partial` outcomes, while
failed files and Retry sends remain non-destructive.

**Constraints:** Preserve file-level deletion for a non-cancelled partial
result, leave empty source directories, log every attempted deletion, clear the
Move checkbox after the batch, and never make Retry destructive.

**Acceptance tests:** Cancel during the first file, after one of two files is
verified, and after all files verify but before finish returns; every source
must remain. Complete a partial non-cancelled transfer and assert only verified
sources are deleted. Simulate deletion failure and assert it is logged without
changing the transfer's delivery facts.

### 4. P0 [FIXED 82fcc39] — Move can delete a replacement file that was never sent

**Affected components:** `lib/net_sender.dart` (`_sendFile`, `_deleteSource`),
Move tests.

**Current behavior and reproduction:** Send a source with Move enabled. After
the upload body has been read but while the receiver's verify response is held,
rename the original away and create different content at the same source path.
When verify succeeds, `_deleteSource()` calls `deleteQuietly(File(source))` by
path only and deletes the replacement. That replacement's bytes were never
sent or verified.

**Root cause:** The pre-send stat validates only type and size, and the later
delete does not prove that the path still names the same filesystem object that
was streamed. A pathname is reused as if it were stable file identity across
multiple asynchronous network round trips.

**Required outcome:** Move must delete only the exact source object whose bytes
were sent. If the path disappears, is replaced, or no longer matches the sent
object at commit time, preserve what is there and report a clear per-file
failure to delete.

**Constraints:** Do not reject ordinary in-place unchanged files, do not delete
the replacement as cleanup, and keep the rest of a non-cancelled batch moving.
Use an identity check strong enough for the supported platform rather than size
alone.

**Acceptance tests:** Pause verify, replace the source with a same-size file,
resume, and assert the replacement survives. Repeat with a different-size
replacement, delete-and-recreate, and an unchanged source. Cover Linux/Android
and Windows identity semantics or isolate the platform-specific implementation
behind a tested contract.

### 5. P1 [FIXED b914d55] — Destroying `MainActivity` destroys the Dart server while the foreground notification stays alive

**Affected components:** `android/.../MainActivity.kt`,
`android/.../TransferService.kt`, `android/.../EasySendApplication.kt`, Flutter
engine ownership, `lib/home_screen.dart`, `ADD/todo.md`.

**Current behavior and reproduction:** Enable Receive in background, enable
Android Developer options -> Don't keep activities, then leave EasySend. The
native `TransferService` can keep the process and "Ready to receive"
notification alive, but `MainActivity` is a plain `FlutterActivity`: it neither
provides nor launches with a cached engine. In the locked Flutter embedding,
`FlutterActivity.shouldDestroyEngineWithHost()` therefore returns true and
`FlutterActivityAndFragmentDelegate.onDestroyView()` calls
`flutterEngine.destroy()`. The Dart isolate, `HttpServer`, UDP socket, and
timers disappear with it, so `/api/v1/info` stops answering behind a notification
that says the receiver is ready.

**Root cause:** The foreground service and multicast lock have process lifetime,
but every network component lives in an engine whose owner has Activity
lifetime. Keeping the native process alive does not keep an Activity-owned
Flutter engine alive.

**Required outcome:** When background receiving is enabled, the engine/isolate
that owns networking must outlive Activity destruction and reattach safely when
the UI returns. Activity-bound plugins and MethodChannel handlers must not retain
a destroyed Activity or be registered twice.

**Constraints:** Keep background receiving off by default; when it is off,
leaving the foreground must still stop networking. Preserve the single network
state machine, notification actions, multicast-lock lifetime, and current
process model unless a different model is deliberately implemented end to end.

**Acceptance tests:** With Don't keep activities enabled and the switch on,
destroy the Activity while the process/notification remain; `/info`, discovery,
trusted receive, and unknown-sender Accept/Decline must work. Reopen repeatedly
and assert one engine owner, one server, one discovery timer, and no duplicated
channel callbacks. With the switch off, the same lifecycle must stop the port.
Add a third case: **swipe the app out of Recents** with the switch on. The two
paths behave differently on hardware and only the first one is fixed.

**Hardware verification 2026-08-12, build 0.2.260812+75 — half fixed.** The fix
in b914d55 (`shouldDestroyEngineWithHost() = false`, engine owned by
`EasySendApplication`) holds for Activity destruction but not for task removal.

Path one, "Don't keep activities", on SM-A366B: the Activity record read
`app=null` while the process stayed alive, `0.0.0.0:15353` kept listening on
both TCP and UDP, and `/api/v1/info` answered over `adb forward`. A second phone
started cold listed this one in under a second — inside the 5 s announce period,
so the `query` was heard and answered. This path is fixed.

Path two, swiping out of Recents, on SM-A127F (Exynos 850, Android 13), switch
on: the process survives (same pid 27 minutes later), `TransferService` reports
`isForeground=true`, and the notification still reads "Готов принимать" — but
15353 is gone from `netstat` on both protocols and `/api/v1/info` does not
answer. The state is stable and does not recover on its own.

**Reopening the app does not fix it.** Launched again from the launcher, the
same process draws its normal UI — header, sections, buttons, all responsive —
while 15353 stays closed and the device list reads "Устройства не найдены". So
the user is shown a working screen that receives nothing and finds nobody. Only
`am force-stop` followed by a fresh start restores it: a new pid comes up with
both sockets listening and `/api/v1/info` answering.

**Cause found, and it is not the chipset — it is `_exitApp`.** The app's own ✕
button (`lib/home_screen.dart:641`) calls `_exitApp`, which stopped
`receiveServer`, `discovery` and `manualPoller` directly, bypassing
`_networkDesired`, and then called `SystemNavigator.pop()`. Since b914d55 the
engine belongs to `EasySendApplication` and outlives the Activity, so all that
Dart state survives the exit with the flag still `true` — and
`_setNetworkDesired` (line 291) returns early whenever the requested value
equals the current one. Reopening the app raises `resumed`, asks for `true`,
gets an early return, and never rebinds. Only a new process recovers. The
foreground service was not stopped either, which is why "Готов принимать" hung
over closed sockets. Before b914d55 the engine died with the Activity, so
neither half could be observed; the engine fix made this path reachable.

Fixed the same day: `_exitApp` now clears `_networkDesired` and bumps the epoch
before stopping anything, and calls the new `AndroidService.stopService()` so
the service and its notification go down with the app. `flutter analyze` clean,
177 tests pass. Not covered by a test — `_exitApp` is a `State` method and no
seam reaches it; worth extracting if this area is touched again. Still to
confirm on hardware with a build that carries the fix.

Method note for whoever continues: do not judge the isolate by the absence of a
`1.ui` thread. On this build a healthy process shows only `1.raster`, `1.io` and
`dart:io EventHandler`, with no `1.ui` at all — the same list as the broken one.

Not yet reproduced on the A366B; that comparison is the next step. Exiting via
the app's own ✕ button is a third path and is also unmeasured.

Worth examining together with this: `_HomeScreenState.dispose()`
(`lib/home_screen.dart:233`) calls `receiveServer.stop()`, `discovery.stop()`
and `manualPoller.stop()` unconditionally, without consulting `Receive in
background`. That is a second, legitimate way for the network to fall over while
the process lives, should the widget tree ever be disposed under a live engine.
It does not explain the observation above — under it the isolate would survive
and `1.ui` would still be there.

### 6. P1 [FIXED c089dd7] — Android 15+ terminates the indefinite `dataSync` listener after six hours and this service does not handle the timeout

**Affected components:** `android/app/build.gradle.kts`, Android manifest,
`TransferService.kt`, Receive in background setting and documentation.

**Current behavior and reproduction:** This project takes Flutter's
`targetSdkVersion` (36 in the locked toolchain), declares the always-on listener
as foreground service type `dataSync`, and leaves it running indefinitely while
Receive in background is enabled. Android 15+ permits background `dataSync`
foreground services only six total hours per 24 hours. It then calls
`Service.onTimeout(startId, fgsType)` and gives the service a few seconds to stop;
`TransferService` has no override, so the platform raises a fatal
`RemoteServiceException`. The exhausted quota also prevents another
`dataSync` start until the allowance resets or the app returns foreground.
This follows the current [Android foreground-service timeout documentation](https://developer.android.com/develop/background-work/services/fgs/timeout).

**Root cause:** A bounded, user-initiated transfer service type is also used as
an unbounded idle network listener, and the implementation predates/ignores the
target-SDK timeout contract.

**Required outcome:** The app must never crash or falsely claim indefinite
background readiness when the `dataSync` allowance expires. Adopt a
platform-compliant lifecycle for idle listening versus active transfers, handle
`onTimeout` deterministically, and revise the product promise if modern Android
cannot support an indefinite listener with the selected APIs.

**Constraints:** Do not silently keep a non-foreground socket after timeout;
release wake/Wi-Fi locks, reconcile Dart state and notification state, and leave
the app usable when brought back to the foreground.

**Acceptance tests:** On Android 15+, enable `FGS_INTRODUCE_TIME_LIMITS`, shorten
`data_sync_fgs_timeout_duration`, and exercise idle listening and an active
transfer. Assert no process crash/ANR, locks and notification are released or
transitioned correctly, the UI explains loss of background readiness, and a
foreground return restores the supported state.

### 7. P1 [FIXED 82d699d] — Denied notification permission leaves background consent enabled but unusable

**Affected components:** `lib/android_helpers.dart`
(`ensureNotificationPermission`, `askAcceptViaNotification`),
`lib/home_screen.dart` network startup, `lib/settings_screen.dart` background
switch.

**Current behavior and reproduction:** Deny notification permission on Android,
then enable Receive in background and send from an unknown device while the app
is off screen. `ensureNotificationPermission()` discards the permission result,
the setting remains enabled, and networking continues. The consent notification
is either not displayed or its `show()` call fails; the sender then waits for a
timeout/500 while the receiver offers no actionable prompt. The UI and ongoing
setting still say background receiving is available.

**Root cause:** Notification capability is treated as a best-effort startup
side effect even though it is a prerequisite for unknown-sender consent and for
the advertised Android background workflow.

**Required outcome:** Background receiving must have an explicit, truthful
capability state. If notification permission is absent, do not enable a mode
whose consent UI cannot be delivered; guide the user to grant permission or
clearly limit the mode, and turn a notification failure into a deterministic
protocol refusal rather than an uncaught request error.

**Constraints:** Trusted senders and foreground dialogs must keep their existing
behavior. Do not silently trust an unknown sender as a fallback.

**Acceptance tests:** Cover permission granted, denied, permanently denied, and
revoked after enablement. For each state, test the switch, idle service, unknown
sender, trusted sender, app return to foreground, and exactly one protocol
answer within the consent deadline.

### 8. P1 [FIXED 420c7fb] — Small control bodies can be drip-fed forever and hold both send and receive ownership

**Affected components:** `lib/net_server.dart` (`_readRequestText`,
`_preparing`), `lib/net_sender.dart` (`_readSmallBody`, `_prepare`), timeout
tests.

**Current behavior and reproduction:** Open `/prepare` and send one body byte
every four seconds. `Stream.timeout(protocolBodyTimeout)` is an inactivity
deadline refreshed by every byte, so `_preparing` remains true indefinitely and
all other prepares receive 409. In the other direction, return prepare headers
and drip a response byte faster than `headerTimeout`; `_readSmallBody()` has the
same per-event timeout and can keep `SendService.busy` for hours while remaining
under 64 KiB. Existing tests cover no headers and a body that stops, not a body
that makes meaningless periodic progress.

**Root cause:** Small bounded control exchanges use only sliding inactivity
deadlines. Their size cap bounds memory but not wall-clock ownership.

**Required outcome:** Give prepare request and response bodies a bounded total
deadline in addition to appropriate per-phase/inactivity limits. A peer cannot
retain `_preparing` or `_inFlight` indefinitely by dribbling bytes.

**Constraints:** Do not add a whole-transfer timeout to file uploads; healthy
large streams must continue to use progress-refreshed inactivity deadlines.

**Acceptance tests:** Drip request and response bytes just inside the inactivity
limit and assert a fixed upper bound, cleanup, and immediate successful reuse by
the next transfer. Keep existing large streamed upload and stalled-upload tests
passing.

### 9. P1 [FIXED 3f7309a] — The receiver has no disk backpressure and can buffer a large upload in memory

**Affected components:** `lib/net_server.dart` `_upload`, 4 GiB readiness
criterion, network tests.

**Current behavior and reproduction:** Receive a large file over a fast LAN onto
slow storage. `_upload()` consumes `req` with `await for`, calls
`sink.add(chunk)`, and does not await any sink completion until `sink.flush()`
after the entire request body. The network stream is therefore not coupled to
the file sink's consumption rate; if disk falls behind, `IOSink` queues pending
chunks and memory grows with the producer/consumer gap. The sender does apply
per-chunk backpressure with `await req.flush()`, but the receiver does not.

**Root cause:** CRC/progress processing manually breaks the natural
stream-to-sink backpressure chain without adding an awaited bounded write.

**Required outcome:** Bound receive memory independently of file size and disk
speed while retaining incremental CRC, size enforcement, cancellation, idle
timeouts, and progress. Network reads must pause when the disk writer is behind.

**Constraints:** Never buffer a whole file or retry in memory; keep temporary
file and cleanup semantics; a disk error must fail the current file and leave
the receiver reusable.

**Acceptance tests:** Use an injectable/controlled slow sink and send data much
faster than it can write; assert a small bounded number of chunks outstanding.
Also cover cancel while a write is blocked, disk-full/write failure, CRC, exact
declared length, and a multi-gigabyte logical stream.

### 10. P1 [FIXED a230831] — Discovery never joins a network interface that appears after startup

**Affected components:** `lib/net_discovery.dart` `DiscoveryService`, lifecycle
coordination, SPEC 5.2.

**Current behavior and reproduction:** Start EasySend while offline, then join
Wi-Fi without restarting the app. `start()` snapshots interfaces once, joins
multicast only on that list, and every later timer tick reuses the same list.
There is no interface-change listener or periodic reconciliation despite SPEC's
promise to announce on interface change. The socket may still send limited
broadcast through a new default route, but it neither joins nor sends the
primary multicast channel on the new interface. Switching Wi-Fi/VPN interfaces
has the same stale-membership problem.

**Root cause:** Interface membership is modeled as immutable service startup
configuration even though it is runtime network state.

**Required outcome:** Reconcile active IPv4 interfaces while discovery is
desired: join new interfaces, stop using removed ones, and immediately query and
announce after a meaningful change without duplicating sockets or timers.

**Constraints:** Keep the stable UDP discovery port, multicast TTL 1, limited
broadcast fallback, Android multicast lock ownership, custom HTTP ports, and
serialized lifecycle intent.

**Acceptance tests:** Start offline then connect; switch between two interfaces;
add/remove VPN and Wi-Fi; suspend/resume desktop; and rapidly flap interfaces.
Assert one listener/timer, correct membership set, immediate announce/query, and
discovery within the five-second readiness target.

### 11. P1 [FIXED 58adb2b] — Valid-looking UDP announces can grow the global device list without bound

**Affected components:** `lib/net_discovery.dart` (`_onEvent`, `_touchDevice`,
`_forgetStaleDevices`), `lib/models.dart` online state, home device list.

**Current behavior and reproduction:** From one LAN host, send thousands of
sub-4-KiB JSON packets with a fresh bounded `id`, name, platform, and port.
Every packet passes `validatedPeerInfo`; `_touchDevice()` performs a linear
`indexWhere`, appends a new global `Device`, and triggers a UI rebuild. There is
no cap or per-source rate limit. Expiry does not run until the five-second timer
and retains entries for roughly eighty seconds, so a short burst produces
quadratic lookup work, a huge widget list, and memory/CPU denial of service.
The unauthenticated identity limitation does not require accepting unbounded
resource use.

**Root cause:** Per-packet field limits exist, but there is no collection-level
resource invariant for transient discovered peers.

**Required outcome:** Bound transient discovery state and update work under
untrusted or malfunctioning LAN traffic. Legitimate manual/trusted devices must
not be evicted or lose trust, and ordinary discovery must remain prompt.

**Constraints:** Do not pretend UDP identity is authenticated; keep query reply
behavior and the documented stale-device lifecycle.

**Acceptance tests:** Burst many unique IDs from one and several addresses,
refresh a stable legitimate peer during the burst, and assert bounded memory,
bounded update frequency, preserved manual/trusted records, and prompt recovery
after the burst. Reject or ignore unknown discovery message types as part of the
same protocol-shape coverage.

### 12. P1 [FIXED f626ce0] — One failed lifecycle transition permanently poisons every later network transition

**Affected components:** `lib/home_screen.dart` (`_networkTail`,
`_queueNetworkTransition`, `_applyNetworkState`), Android permission/multicast
channel calls.

**Current behavior and reproduction:** Cause one awaited lifecycle operation to
throw—for example, a transient plugin/channel failure while acquiring a
permission or releasing multicast. `_queueNetworkTransition()` stores
`_networkTail = _networkTail.then(...)` without catching the rejection. Every
later pause/resume/port transition attaches another `then` to the rejected
future, so its callback is skipped forever. The repository already introduced
`SerialQueue` specifically to prevent this failure in settings and service
sync, but the network lifecycle chain repeats the old pattern.

**Root cause:** Serialized desired-state reconciliation stores failures as queue
state and has no finally/recovery boundary.

**Required outcome:** Every queued transition must run after a previous failure,
log/report that failure, and reconcile to the latest epoch/desired state. A
failure must not cause overlapping starts as a recovery shortcut.

**Constraints:** Preserve epoch checks, deferred shutdown/rebind during active
transfers, and at most one transition in flight.

**Acceptance tests:** Inject one failure at every awaited phase (permission,
directory, server start/stop, discovery start/stop), then queue the opposite and
latest desired states. Assert serialization, no duplicated resources, and final
state matching the newest epoch.

### 13. P1 [FIXED 7c28b30] — The UI accepts device names that its own discovery and prepare protocols reject

**Affected components:** `lib/settings_screen.dart` `_editDeviceName`,
`lib/settings_helpers.dart` `_validSetting`, `lib/globals.dart`
`maxSenderNameBytes`/`validatedPeerInfo`, `lib/net_server.dart` prepare shape.

**Current behavior and reproduction:** Enter a device name of 86 CJK characters
(258 UTF-8 bytes). The edit path checks only non-empty; save does not apply
`_validSetting`, and even load validation permits up to 128 Dart code units.
Discovery peers reject names above `maxSenderNameBytes` (256 UTF-8 bytes), and
every `/prepare` from this device is rejected as `manifest-shape`. The device
therefore disappears from automatic discovery and cannot send until its name is
shortened; an even longer name is persisted and then silently rejected on the
next load, changing the visible device name.

**Root cause:** UI, persistence, UDP, and HTTP enforce different units and
limits, and write-time settings mutation bypasses schema validation.

**Required outcome:** One shared name validator must define the accepted
contract before saving. Every name accepted by settings must pass both wire
protocols; rejected input must remain editable with a localized, specific
message and must not mutate/persist the active identity record.

**Constraints:** Preserve international names, the fallback default device
name, and the deliberate bounded wire format. Do not truncate a user's name
silently.

**Acceptance tests:** Cover ASCII, Cyrillic, CJK, emoji/surrogate pairs, control
characters, exact byte boundary, one byte over, and very long input. Round-trip
accepted names through settings, discovery validation, and prepare; assert all
three agree.

### 14. P1 [FIXED fc535fa] — A receiver that rejects `finish` is reported as a completed send and remains busy

**Affected components:** `lib/net_sender.dart` (`send`, `_post`),
`lib/net_server.dart` `_finish`, transfer logs and recovery tests.

**Current behavior and reproduction:** Use a receiver that successfully uploads
and verifies every file but returns 409/500 to `/finish` without releasing its
session. `SendService.send()` awaits `_post()` but never inspects its status and
unconditionally marks the sender transfer `done` when no file failed. It does
not log the code or send best-effort cancel. The receiver can remain active/busy
until its inactivity deadline while the sender tells the user the transfer
finished successfully.

**Root cause:** `_post()` is used as a transport helper whose non-2xx result is
not elevated to a protocol outcome, and the terminal state is derived only from
per-file flags.

**Required outcome:** Terminal protocol responses must be validated. A rejected
or malformed finish cannot produce `done`; the sender must log the exact
response, make receiver cleanup best-effort, and leave both sides reusable with
a truthful outcome.

**Constraints:** Files already verified at the receiver remain successful
delivery facts; do not resend them merely because session finalization failed.
Keep cancel best-effort and bounded.

**Acceptance tests:** Return 200, 409, 500, timeout, disconnect, and an oversized
body from finish. Assert sender status/log, remote cleanup attempt, no stuck
sender ownership, and a subsequent transfer accepted by the receiver.

### 15. P1 [FIXED 93c0447] — A receiver is advertised even when its port or receive folder is unusable

**Affected components:** `lib/home_screen.dart` `_applyNetworkState`,
`lib/net_server.dart` `start`, `lib/net_discovery.dart`, port banner and storage
permission flow.

**Current behavior and reproduction:** Occupy the configured HTTP port, or make
the configured receive folder uncreatable/unwritable (including denied Android
storage permission). `ReceiveServer.start()` ignores `ensureRecvDir()`'s false
result and reports only bind failure; `_applyNetworkState()` ignores the bool
returned by `start()` and starts discovery regardless. Other devices therefore
see this receiver as online at a port it did not bind, or reach a server that
will reject every prepare with `receive folder unavailable`. Local sending can
work, but remote users receive a misleading selectable target.

**Root cause:** Discovery desired state is coupled to app foreground state, not
to receive readiness, and readiness does not include filesystem capability.

**Required outcome:** Advertise receive availability only when this process has
the configured HTTP listener and a usable receive root. Keep outgoing sending
available and show an actionable local banner for port, permission, and folder
failures; retry readiness after the user fixes the cause.

**Constraints:** Do not hide manual peers or disable outgoing sends. Preserve
the existing port-change deferral during active sessions and do not probe by
creating/deleting arbitrary user files repeatedly.

**Acceptance tests:** Cover occupied port, denied/revoked storage permission,
read-only/deleted receive folder, recovery after correction, and ordinary
startup. Inspect outgoing announces and `/info`: an unavailable receiver must
not be presented as a valid automatic target, and recovery must announce
promptly without an app restart.

### 16. P2 [FIXED 1099c9a] — Retry and failure progress diverges between sender and receiver and can move backwards

**Affected components:** `lib/net_sender.dart` `_sendOneByOne`/`_sendFile`,
`lib/net_server.dart` `_upload`/`_verify`, `TransferSession.noteProgress`,
transfer UI.

**Current behavior and reproduction:** Force CRC failure for the first of two
files, exhaust its retries, then successfully send the second. Each full failed
attempt advances `bytesDone`; the next attempt/current file resets its local
byte count and can make the bar and rolling speed go backwards. After giving up,
the sender increments `settled` by the failed file's size anyway, while the
receiver increments `settledBytes` only for verified files. The final partial
rows can therefore show different progress for the same transfer, contrary to
SPEC's same-on-both-sides promise.

**Root cause:** Attempt bytes, verified unique bytes, completed queue work, and
terminal success are represented by one `bytesDone` field with different
settlement rules on each side.

**Required outcome:** Define one progress invariant for both directions and
retries. The displayed bar must be monotonic, bounded, and comparable on both
sides; speed/ETA must not use negative deltas. Terminal partial state must still
make failed files obvious.

**Constraints:** Keep byte-weighted overall progress and one bar; do not count
files equally or hide current retry activity.

**Acceptance tests:** Exercise checksum retry success, exhausted retry followed
by success, failed last file, zero-byte files, and cancellation. Capture every
progress sample on both peers and assert the chosen monotonic/bounded semantics,
non-negative speed, and terminal agreement.

### 17. P2 [FIXED fa439af] — A post-build collection failure commits a new version without a complete release set

**Affected components:** `10-MakeRelease.sh`, release-version tests and artifact
naming.

**Current behavior and reproduction:** Let both Flutter build commands return
success, then make an expected output missing/unmovable or make the artifact
listing fail. The script sets `BUILD_SUCCEEDED=true` before the collect loop,
renaming, cleanup, artifact listing, and optional git version handling. The EXIT
trap therefore preserves the bumped `pubspec.yaml`/`globals.dart` even though
the requested named release artifacts were not collected successfully.

**Root cause:** The transaction's commit point means "Flutter returned zero",
while the script's actual deliverable is the verified, consistently named
artifact set plus synchronized version sources.

**Required outcome:** Define and enforce a release transaction commit point
after every required artifact exists under its final name and version sources
remain synchronized. Any earlier failure restores the version files and leaves
pre-existing artifacts/user changes intact.

**Constraints:** Do not roll back a genuinely completed published release;
preserve dirty-worktree safeguards, ABI choices, and the rule that Linux builds
do not increment the counter.

**Acceptance tests:** Stub build success with all outputs, each required output
missing in turn, rename failure, listing/verification failure, dirty tree, and
already-pushed HEAD. Assert version rollback/commit behavior and exact final
artifact names without invoking a real external release.

## Validation performed

- `./05-Lint.sh`: passed with no analyzer issues.
- `./06-Test.sh --reporter compact`: all 127 tests passed.
- Parsed every repository file outside generated/build trees; reconciled
  README, SPEC, changelog, both previous audit rounds, open hardware notes,
  Flutter/Dart sources, Kotlin service code, manifests, Gradle configuration,
  and release scripts.
- Checked locale data: every declared non-English key contains both Russian and
  Ukrainian strings; inspected code-localized call sites for mismatches.
- Confirmed the Activity-owned-engine destruction path against the locked
  Flutter embedding source and target SDK 36 against the locked Flutter Gradle
  extension.
- Confirmed the Android `dataSync` six-hour rule against current primary Android
  documentation.
- Rechecked `git status` and `git diff --check`; the audit created only this
  artifact.

## Areas not exercised

- No Android hardware/instrumentation run was performed, so multicast behavior,
  notification UI delivery, storage permission UX, Doze, and the shortened FGS
  timeout command remain acceptance work even where the platform/source trace
  establishes the defect.
- Windows runtime/path behavior and Linux AppImage packaging were inspected but
  not built or executed in this environment.
- Large-file memory behavior was established from the missing backpressure edge;
  no multi-gigabyte allocation profile was run.

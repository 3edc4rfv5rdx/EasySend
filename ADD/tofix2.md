# EasySend code-audit fixes, round two

Each section below is a standalone implementation prompt. Preserve the deliberate product constraints documented in `README.md` and `SPEC.md`: transfers remain local-network, plain HTTP, and unauthenticated in this version. Do not broaden a fix into TLS or account/authentication work. Add focused automated tests for every changed behavior, in the style of the existing suite under `test/`.

Every finding below was read against the current code at the commit that introduced `ADD/tofix1.md`. Where a finding depends on an assumption rather than on a code fact, the section says so in its own words.

## 1. P0 — FIXED - Never restart the receive server while it is serving a session

`_applyNetworkState()` in `lib/home_screen.dart` calls `await receiveServer.start()` on every transition into the desired-network state, and `ReceiveServer.start()` in `lib/net_server.dart` begins with `await stop()`, which cancels `_current` and deletes its `.easysend-part` file. Nothing on that path asks whether a transfer is already running.

On Android this is reached by simply reopening the app. `didChangeAppLifecycleState` calls `_setNetworkDesired(true)` on `resumed`, which queues `_applyNetworkState` with `restart: false`, which still lands on `start()` → `stop()`. The pause path deliberately refuses to tear the network down while a transfer runs (`if (sender.busy || xvTransfers.any((t) => t.isRunning)) return;`), so an incoming transfer survives being backgrounded and is then killed the moment the user comes back to watch it. With `Receive in background` switched on it is worse: the first branch of `didChangeAppLifecycleState` calls `_setNetworkDesired(true)` for *every* lifecycle state, so `inactive` followed by `paused` — what the lock screen produces — restarts the server twice in a row.

Make an already-running server on the correct port a no-op. `start()` should return true immediately when `_http != null`, `bindError == null` and the bound port equals `currentPort`, unless an explicit restart was requested; and a restart that would abort a live session must either be refused with a clear result or deferred until the session ends. Keep the port-change path (`_restartNetwork`) working, since that one has to rebind. While you are there, stop `didChangeAppLifecycleState` from re-arming the network on `inactive`, which is not a background state.

Add tests: `start()` twice in a row keeps the same `boundPort` and leaves an active session and its `.part` file untouched; a port change still rebinds; a simulated `resumed` transition during an active receive does not cancel it.

## 2. P0 — FIXED - A consent that resolves after the server stopped must not install a session

`_prepare()` in `lib/net_server.dart` holds `_preparing = true` across `_askAccept()`, which can await up to `acceptTimeoutSec`. `ReceiveServer.stop()` sets `_preparing = false` and closes the socket, but it cannot see the in-flight prepare because `_current` is still null. When the consent finally resolves, `_prepare()` adds a `TransferSession` to `xvTransfers`, assigns `_current`, and arms `_touch()` — on a server that was torn down, and on the *new* server object state if one was started meanwhile.

The result is a receiver that answers `409 busy` to every real transfer until the inactivity timer fires `receiveSessionTimeoutSec` later, plus a transfer row that sits `active` and then ends as `Connection timed out`. While it sits there, `isRunning` is true, so the Send button stays on `Stop`, `_applyNetworkState` refuses to stop the network, and `AndroidService` keeps the foreground service and the screen wakelock up.

This is not theoretical: the Android notification actions carry `showsUserInterface: true`, so answering `Accept` from the lock screen resumes the app, which triggers finding 1, which stops the server underneath the prepare that is waiting for that very answer. Fix both together.

Give the server a generation/epoch counter bumped by `stop()`. After `_askAccept()` returns, a prepare whose epoch is stale must decline: do not touch `xvTransfers`, do not assign `_current`, do not arm the timer, and answer (best effort) with a conflict status. Also stop `stop()` from clearing `_preparing` for a prepare it did not actually cancel — the flag exists to keep a second prepare out, and clearing it lets two consent prompts overlap.

Add tests: stop the server while a prepare is parked on consent, then let consent succeed, and assert `xvTransfers` is empty, `_current` is null and a fresh `prepare` on a newly started server returns 200 rather than 409.

## 3. P1 — FIXED - A malformed prepare answer must not strand the transfer in `pending`

`_prepare()` in `lib/net_sender.dart` reads `(json.decode(body) as Map)['sessionId'] as String?` and returns null when the cast yields null. On the `200` path nothing sets a status or an error, so `send()` returns with the transfer still at `TransferStatus.pending` — which `TransferSession.isRunning` reports as running, forever. That single row then keeps the Send button showing `Stop`, keeps `_applyNetworkState` from ever tearing the network down, and keeps the Android foreground service and screen wakelock held for the rest of the process's life. An empty-string `sessionId` is accepted just as readily and produces upload URLs the receiver rejects one by one.

Validate the answer: a `200` must carry a non-empty `sessionId` string of sane length, otherwise fail the transfer with a localized protocol error. More generally, make `send()` guarantee a terminal status: assert on exit that the transfer is no longer `pending`/`active`, and fail it with a described error if any path leaves it there.

Add fake-server tests for `200 {}`, `200 {"sessionId": ""}`, `200 {"sessionId": 42}` and a `200` with a non-object body. Each must leave exactly one transfer in a terminal state and `sender.busy` false.

## 4. P1 — Pin the receive directory to the session instead of reading the global

`ReceiveServer` reads the global `xvRecvDir` at four different moments: `start()`, `_prepare()`, `_upload()` and `_verify()`. `_editRecvFolder()` in `lib/settings_screen.dart` reassigns that global at any time, and `home_screen.dart` only restarts the network when the *port* changed. Change the folder while a receive is running and the destinations planned under the old root are then checked with `ensureSafeDestination(newRoot, oldDest)`, where `p.relative` produces a `../…` path and the check fails — the file dies with a bare `400` mid-transfer.

Store the receive root in `_Incoming` when the plan is built and use that value for every later `ensureSafeDestination`, `_cleanupParts` and rename in the same session. Additionally, have the settings screen refuse (or defer) a receive-folder change while a transfer is running, say so in a localized message, and make sure the newly chosen folder is created and validated as writable at the moment it is chosen rather than at the next receive.

Add tests: a session prepared under folder A completes correctly after `xvRecvDir` is reassigned to folder B mid-upload; the finished file lands in A; a new session then lands in B.

## 5. P1 — Bound the error-response drain in the manual poller

`_ask()` in `lib/net_discovery.dart` applies `timeout` to the connection, to `req.close()` and to the body stream of a `200` — but the non-200 branch does `await resp.drain<void>();` with no timeout at all. A peer that answers `500` and then never ends its body parks that await forever. `_pollAll()` holds `_polling = true` around it, so manual polling stops for the lifetime of the process and every manual device silently goes offline. The same `_ask()` is awaited by `verifyIdentity()` before an outgoing send, so a send to a manual device can hang with no cancel path.

Apply the same `timeout` to the error drain, and prefer `resp.detachSocket()`/destroy over draining an unbounded error body at all. Give `verifyIdentity()` its own overall deadline so a send can never hang longer than the identity check is worth.

Add a fake-server test for a non-200 response whose body never ends: `_pollAll` must return within a few seconds, `polling` must go back to false, and a subsequent poll of a healthy device must succeed.

## 6. P1 — Validate discovery payloads as strictly as HTTP protocol fields

`_onEvent()` in `lib/net_discovery.dart` takes `id`, `name`, `platform` and `port` straight out of a UDP datagram and hands them to `_touchDevice()`, which writes them into `xvDevices`. The HTTP side was hardened in the previous round (`maxProtocolIdBytes`, `maxSenderNameBytes`, `_senderPort` range check), and the UDP side never was. A datagram can therefore register a device with a 60 KB name, an `id` that is not a UUID at all, or a port of `0` or `999999` that no later code range-checks; if that device is later trusted, all of it is persisted into `settings.json`.

Apply the same limits the HTTP protocol uses: reject the packet unless `id` is a valid device id (`isValidDeviceId`, which already exists and is currently used only for the local identity), `name` and `platform` are within their byte budgets, and `port` is 1–65535. Reject oversized datagrams before decoding. Keep the existing self-id and loopback filters. Note that `_validDevice()` in `lib/settings_helpers.dart` already enforces a port range on load, so a device accepted over UDP today can be dropped silently at the next start — the two validators should agree.

Add tests over `_touchDevice`/the payload parser for an out-of-range port, an id that is not a UUID, an oversized name, and a well-formed packet that must still be accepted.

## 7. P2 — Poll manual devices concurrently, or stop judging them by a shared deadline

`_pollAll()` in `lib/net_discovery.dart` walks manual devices sequentially, each costing up to `manualPollTimeoutSec` when unreachable, while `Device.online` calls a manual device offline after `manualPollSec * 2` = 20 s. The timer's own re-entry guard then stretches the cycle further. With roughly five or more unreachable manual devices in the list, a healthy device polled late in the pass has its `lastSeen` refreshed less often than the window it is judged by, so it flickers between online and offline and cannot be selected as a target while it is grey.

This one rests on an arithmetic estimate of the pass duration, not on an observed failure: the exact threshold depends on how fast unreachable hosts fail on the platform. Verify the timing before choosing the fix.

Poll with bounded concurrency (all devices at once is fine at this scale) so one pass costs one timeout rather than N, or decouple the freshness window from the poll cycle so a slow pass cannot mark a live device offline. Keep the overlap guard.

Add a test with several dead addresses and one live fake server: the live device must stay `online` across three consecutive poll cycles.

## 8. P2 — A rejected future must not poison a serialization chain

Two places serialize async work by chaining onto a stored future: `AndroidService.sync()` (`_syncTail = _syncTail.then((_) => _syncNow())`) in `lib/android_helpers.dart` and `saveSettings()` (`_saveTail = _saveTail.then((_) => _saveSettingsNow())`) in `lib/settings_helpers.dart`. In both, one rejection makes the stored future permanently failed: every later `.then` skips its callback and returns another failed future, so the foreground service stops being updated and settings stop being written — silently, for the rest of the run, plus an unhandled async error each time.

`_syncNow()` is reachable: `_push()` and `_stop()` catch `PlatformException` only, while `invokeMethod` also throws `MissingPluginException` when the engine is being torn down or the channel is not yet wired. `_saveSettingsNow()` is better protected — only its own `finally` can throw — but the pattern is identical and should be fixed in one place.

Extract one shared serialization helper (per the project rule about shared code living in one file) that swallows and logs a failure instead of storing it: `_tail = _tail.then((_) => work()).catchError(log)`, returning a future the caller can still await. Use it for both chains, and while you are there make `_push`/`_stop` catch `PlatformException` and `MissingPluginException` alike.

Add tests: a sync whose platform call throws is followed by a sync that still reaches the channel; a `saveSettings` that fails once is followed by one that writes the file.

## 9. P2 — Enforce the manifest limits on the sending side

`_addPaths()` in `lib/home_screen.dart` accepts any number of files of any total size, while the receiver refuses more than `maxManifestFiles` (1000) or more than `maxDeclaredTransferBytes`, and refuses individual paths that fail `sanitizeRelPath` (depth over `maxPathDepth`, components over `maxPathComponentUtf8Bytes`, reserved Windows names, trailing dots or spaces). The sender learns none of this until `prepare`, where every one of those refusals arrives as `HTTP 400` and is shown to the user exactly like that. Picking a folder of 1500 files — well within what SPEC readiness criterion 4 implies — is a plain user action that ends in an unexplained failure.

Check the same limits when files are added, before anything is sent. Refuse the addition with a localized message naming the actual reason (too many files, name not portable, total too large), and either skip the offending entries or refuse the batch — pick one and be consistent with how duplicates are already handled. Reuse `sanitizeRelPath` and the `max*` constants rather than restating either. Consider raising `maxManifestFiles` if 1000 is simply too low for a real photo folder; that is a product decision, so state it rather than changing it silently.

Add tests: adding 1001 collected files is refused with a reason; a file whose relative path fails `sanitizeRelPath` never reaches the selection; a normal folder is unaffected.

## 10. P2 — Detect a source file that changed between picking and sending

`_sendFile()` in `lib/net_sender.dart` sets `req.contentLength = item.size` from the size captured by `collectFiles()` when the file was picked, then streams whatever `File(source).openRead()` currently holds. A file edited in between makes `dart:io` throw `HttpException` for content over or under the declared length; the throw is swallowed by the generic `catch (e)` and the file is quietly retried `maxResendAttempts` times before being marked failed with no reason the user can act on.

Re-stat the file immediately before sending it. If the size still matches the manifest, proceed; if it does not, fail that one file with a distinct localized reason ("file changed on disk") and do not burn the retries on it, because retrying cannot help. Leave the rest of the queue running, as SPEC 5.6.1 requires.

Add tests with a file truncated and a file extended between manifest construction and send: exactly one attempt per file, a distinct error, and the other files in the batch still delivered.

## 11. P2 — Move the multicast lock off the Activity

`MainActivity.kt` holds the `WifiManager.MulticastLock` and releases it in `onDestroy()`. With `Receive in background` on, the foreground service keeps the process alive while the Activity can be destroyed at any time — after which the lock is gone, but `DiscoveryService` is still running and still believes it holds it (`setDiscoveryMulticastEnabled(true)` was called once, at `start()`). Depending on the device, multicast and broadcast datagrams then stop being delivered, so the phone keeps its HTTP server up and quietly disappears from every other device's list.

How much this bites is device-dependent — some ROMs deliver multicast without the lock — so measure before and after on a real phone rather than trusting the change.

Hold the lock in `TransferService` (or in the Application object), tied to whether discovery is running rather than to the Activity's lifetime, and make `onDestroy` release it only when discovery is actually stopping. Keep the existing "held only while discovery runs" behaviour from SPEC 5.2 — the point is which component owns it, not how long.

Add an instrumentation-level or manual check: with background receiving on, swipe the app away, then confirm from another device that the phone still answers discovery.

## 12. P2 — A MethodChannel handler must not crash the app

The handlers in `MainActivity.configureFlutterEngine` call `startForegroundService()` and `startService()` without a `try`. Both throw from the background: `startService` raises `IllegalStateException` when the app is backgrounded and the service is not already running, and on Android 12+ `startForegroundService` raises `ForegroundServiceStartNotAllowedException` outside the allowed windows. An uncaught exception in a channel handler takes the process down. The Dart side only calls `stop` when it believes `_serviceUp`, but that belief survives a service the system already killed.

Wrap each handler body, answer `result.error(...)` on failure, and have `AndroidService._push`/`_stop` treat a failed call as "the service is not up" so the next attempt starts it rather than updating it. Do not swallow the failure silently — log it through the existing `myPrint` path.

Add a Dart-side test with a mocked channel that throws, asserting the service state machine recovers and the app keeps running.

## 13. P2 — Say something when Send is pressed while the previous send is still unwinding

`SendService.send()` returns `TransferStatus.failed` immediately when `_inFlight` is set, without creating a transfer, setting an error, or telling anyone. That path is reachable through the UI: `cancel()` sets the transfer's status to `cancelled` at once while `_inFlight` stays true until the cancelled future has unwound (which is deliberate, from the previous audit round). In that window `_running` is null, so the main button turns back into `Send`, and pressing it does nothing whatsoever — no message, no row, no reaction.

Either keep the button in its stopping state until `sender.busy` clears, or answer the press with a localized "still stopping" message. The first is better: the button already derives its label from state, and `sender.busy` is exactly that state.

Add a widget-level or logic-level test: while `busy` is true and the transfer reads `cancelled`, the main action does not silently no-op.

## 14. P2 — Resolve the fallback device id against the configured receive folder

`initIdentity()` in `lib/settings_helpers.dart` calls `_resolveDeviceId()` first and applies the stored `Receive folder` to `xvRecvDir` about thirty lines later. `_resolveDeviceId()` — and `writeExternalDeviceIdIfAbsent()` right after it — therefore read and write `.easysend-id` in the *default* downloads folder, even when the user has moved the receive folder elsewhere. SPEC 5.3 puts that file inside the receive folder, which is what makes it survive a reinstall in the place the user actually keeps EasySend's files.

Apply the stored receive folder before resolving the identity, or pass the intended folder into `_resolveDeviceId()` explicitly. Keep reading the old location as a fallback so an id already written there is not lost — this file exists precisely so that trust survives.

Add a test: with `Receive folder` set to a custom directory and no ANDROID_ID, the fallback id is written into that directory, and an id already present in the default location is still adopted.

## 15. P3 — Stop the per-chunk timer churn on the transfer hot path

Four allocations sit inside loops that run for every chunk of every file, or on every UI tick during a transfer:

- `_touch(session)` is called per chunk in `_upload()` (`lib/net_server.dart`), and each call cancels a `Timer` and allocates a new one — tens of thousands of timers for one large file. The `req.timeout(uploadIdleTimeout)` wrapper already detects a stalled upload, so the session deadline only needs refreshing at phase boundaries and on the existing 100 ms progress tick.
- `await req.flush().timeout(idleTimeout)` in `_sendFile()` (`lib/net_sender.dart`) allocates a timer per chunk for the same reason.
- `TransferSession.bytesTotal`, `doneCount` and `failedCount` fold over the whole file list on every access, and `_buildTransferTile` reads them several times per rebuild at roughly 10 rebuilds per second; with a 1000-file transfer that is tens of thousands of iterations per second for numbers that change once per file. Cache them and invalidate on change.
- `ensureSafeDestination()` (`lib/file_helpers.dart`) calls `Directory(baseDir).create(recursive: true)` and `resolveSymbolicLinks()` on every invocation, and it is invoked four times per file. The root can be resolved once per session (see finding 4, which already moves the root into `_Incoming`).

None of these is a correctness bug; the point is that a 4 GB transfer should not allocate a timer per 64 KB. Keep the idle-timeout semantics intact — a stalled upload must still be aborted within `networkIdleTimeoutSec`.

Add a timing-independent test where possible (for example, asserting the cached totals equal the folded ones after mutation) and keep the existing stalled-upload test passing.

## 16. P3 — Do not scan the whole receive folder on every server start

`ReceiveServer.start()` calls `cleanupOrphanParts(xvRecvDir)`, which walks the receive folder recursively. SPEC 7 asks for that at *startup*, to clear what a killed process left behind. As written it also runs on every port change and — until finding 1 is fixed — on every return to the foreground, over a folder that is the user's Downloads by default and may hold thousands of files.

Move the orphan sweep to application startup, once, and leave `start()` to bind the socket. If a sweep is still wanted after a folder change, run it explicitly there.

Add a test asserting the sweep runs once across two `start()` calls.

## 17. P3 — NOT REAL - Release logging is already stripped

The finding as first written claimed that `xvDebug = true` in `lib/globals.dart` ships the log into release builds, where `myPrint` would write paths, device names and peer addresses into logcat.

It did not. All three shipping scripts rewrote the flag to `false` for the duration of the build and restored whatever was in the file afterwards, so no released binary ever carried the log. The value checked into the repository was the one a local `flutter run` used, which is where it belonged.

The flag has since been removed anyway: `myPrint` follows `kDebugMode`, which says the same thing without three build scripts editing a source file while they build it. Behaviour is unchanged — releases are silent, `flutter run` and the tests print.

Nothing left to implement. Recorded so the next reader does not raise it again.

## 18. P3 — Create the accept dialog's timeout outside the builder

`showAcceptDialog()` in `lib/ui_helpers.dart` assigns `timer = Timer(...)` inside the `pageBuilder` passed to `showGeneralDialog`. That builder runs again whenever the route's content rebuilds — which is exactly what a language or theme change does, since `appRebuild` rebuilds the whole `MaterialApp`. Each rebuild starts another 30-second timer and drops the reference to the previous one, so the earliest of them pops the dialog and the transfer is declined ahead of its deadline.

Start the timer before `showFlatDialog`, cancel it in a `finally`, and let it complete the same future the buttons complete.

Add a test that rebuilds the app while the accept dialog is open and asserts exactly one pending timer and an unchanged deadline.

## 19. P3 — Flush the window bounds before exiting

`_scheduleWindowSave()` in `lib/home_screen.dart` debounces the save by 400 ms; `_exitApp()` calls `exit(0)` without cancelling that timer or writing what it was going to write. Move or resize the window and close it within 400 ms and the new geometry is lost — quietly, so it reads as the feature not working rather than as a race.

Write the pending bounds synchronously (or await the save) in `_exitApp` and in `dispose()` before shutting down. The same applies to `onWindowClose`.

Add a test around the debounce helper: a pending save that is flushed on exit produces the same stored string as one that fired on its own.

## 20. P3 — Decide what a backslash in a manifest path means

`sanitizeRelPath()` in `lib/file_helpers.dart` starts with `raw.replaceAll(r'\', '/')` on every platform, so a Linux file legitimately named `back\slash.txt` arrives as a directory `back` containing `slash.txt`. SPEC 5.7 says the backslash is *rejected* on Windows, not silently reinterpreted everywhere. The current behaviour is the safe direction — nothing escapes the receive folder — but it invents a folder structure the sender never had, and the sender-side `_targetKey` in `lib/home_screen.dart` performs the same substitution, so the two agree on the wrong answer.

Pick one rule and write it down in SPEC: either treat `\` as a separator (then say so, and keep both sides converting) or reject any component containing it (then a file with a backslash in its name is refused with a clear message, like the other non-portable names). Rejection matches the rest of `sanitizeRelPath`, which refuses rather than repairs.

Add tests for whichever rule is chosen, on both the sanitizer and the sender-side duplicate key.

## 21. P3 — Documentation drift

Two places where SPEC.md and the code disagree. Neither is a defect on its own; both mislead the next reader.

- SPEC 8 and SPEC 2 name the Ukrainian locale `uk`, while `assets/locales.json` keys it `ua` and `initialLanguageForLocale()` in `lib/settings_helpers.dart` maps the system's `uk` onto it. The code is self-consistent; the document is not. Either rename the locale key to the ISO code and drop the mapping, or correct SPEC.
- SPEC 4 lists "устройства, добавленные вручную" among the settings screen's contents. The settings screen shows only trusted devices; manual devices are listed and removed on the home screen. That is a reasonable UI decision, but SPEC still promises the other one.

Fix the documents (or the code, if the promise is worth keeping) in one pass, and do not let this become a UI redesign.

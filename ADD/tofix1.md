# EasySend code-audit fixes

Each section below is a standalone implementation prompt. Preserve the deliberate product constraints documented in `README.md` and `SPEC.md`: transfers remain local-network, plain HTTP, and unauthenticated in this version. Do not broaden a fix into TLS or account/authentication work. Add focused automated tests for every changed behavior.

## 1. P0 — FIXED - Prevent writes through symlinks outside the receive directory

Fix the receive-path containment check in `lib/file_helpers.dart` and its use in `lib/net_server.dart`. `resolveInside()` currently calls `p.normalize()` and `p.isWithin()` and describes that as canonicalization, but both are lexical operations. If the receive directory contains `link -> /outside`, a manifest path such as `link/stolen.bin` passes the check and `File.openWrite()` follows the symlink, writing outside the configured receive directory.

Implement filesystem-aware containment. Canonicalize the receive root, reject any existing symlink/reparse-point component below it, safely handle not-yet-created descendants, and revalidate at the point where directories/files are created so that a symlink swap cannot bypass the earlier `prepare` check. Keep normal nested directories working on Android, Linux, and Windows. If Dart APIs cannot provide an atomic no-follow open on every platform, document the residual race and use the strongest practical per-component validation immediately before creation/opening.

Add tests for `../`, absolute paths, a symlinked intermediate directory, a symlinked final path, and ordinary nested paths. The symlink cases must never create or modify a file outside the receive root.

## 2. P0 — FIXED - Reserve and validate every manifest destination as one atomic plan

Rework manifest validation in `lib/net_server.dart` and the name-allocation helpers in `lib/file_helpers.dart`. `_prepare()` calls `uniquePath()` for every file before any of the planned destinations exists, so two entries that resolve to the same path receive the same destination. This is reachable from the UI because `_targetKey` in `lib/home_screen.dart` treats the same relative path with a different size as distinct. On POSIX, the second verified rename can replace the first file while the transfer reports both files as done. Case-only collisions also collapse on Windows. File-versus-directory conflicts such as `a` and `a/b.txt` fail during upload.

Build the complete destination plan before asking the user to accept. Validate that file IDs are non-empty and unique. Reserve names in memory as they are allocated, using platform-appropriate path equality (case-insensitive on Windows), and account for sanitized-name collisions as well as files and `.easysend-part` files already on disk. Reject structurally impossible manifests where one file path is an ancestor of another, or define and test a deterministic safe renaming policy. Ensure retries for one file keep its originally reserved destination.

Also fix sender-side duplicate filtering so two selected files cannot silently target the same receiver path merely because their sizes differ. Add integration tests proving that duplicate IDs, identical paths, case-only paths, sanitized collisions, and file/directory prefix conflicts cannot overwrite a successfully received file or produce a false `done` result.

## 3. P0 — FIXED - Give the receive protocol an explicit concurrency-safe state machine

Refactor `ReceiveServer` in `lib/net_server.dart` around a single serialized session/file state machine. The current busy check happens before the asynchronous acceptance dialog, so two concurrent `prepare` requests can both pass, show overlapping prompts, receive success, and then overwrite `_current`. The routes also permit `finish`, `cancel`, repeated `upload`, or repeated `verify` while another request for the session is still executing. A verified file can therefore be uploaded again, counters can be incremented twice, and cleanup can race an open sink.

Reserve the receive slot before any `await` that can allow a second prepare through. Track states such as awaiting-consent, ready, uploading a specific file, awaiting-verification, finished, and cancelled. Reject out-of-order or duplicate operations with a consistent 409/400 response. Make receiver-side cancellation set the session cancellation flag before cleanup and wait for the active upload to close before deleting temporary files and releasing the slot. Make `finish` legal only when no upload/verification is in flight. Ensure every request completes exactly once even if the client disconnects.

Add concurrent HTTP tests for two prepares, cancel-during-upload, finish-during-upload, duplicate upload/verify, and requests belonging to an old session. Assert that only one session is accepted, no `.easysend-part` file survives, byte counters never exceed the manifest total, and no completed destination is modified by an invalid second request.

## 4. P0 — FIXED - Recover receive sessions after network failure, shutdown, and restart

Fix abandoned-session handling across `lib/net_server.dart`, `lib/net_sender.dart`, `lib/file_helpers.dart`, and app lifecycle code. If Wi-Fi drops or the sender crashes after `prepare`, the sender marks its local transfer failed but never releases the receiver. The receiver keeps `_current` active forever, rejects every later transfer as busy, and may retain a partial file. `ReceiveServer.stop()` closes sockets without aborting `_current`; restarting after a port change can therefore reopen the server in a permanently busy state. `SPEC.md` also requires orphan `.easysend-part` files to be removed at the next startup, but no startup cleanup exists.

Introduce a receive-session inactivity deadline that is refreshed by valid progress and aborts/cleans a stale session. On sender terminal errors, make a best-effort cancel call when a session ID exists. Make `ReceiveServer.stop()` explicitly abort the active session and await upload shutdown/cleanup before returning. On startup, recursively remove only files ending in the exact temporary suffix under the validated receive directory; never follow symlinks and never delete ordinary user files. Surface a meaningful cancelled/failed state in the transfer list.

Add tests for disconnect after prepare, disconnect mid-file, server restart during a session, port change during a session, and process-restart cleanup. A later sender must be able to prepare a new transfer without restarting the application.

## 5. P0 — FIXED - Make sender cancellation and serialization race-free

Refactor `SendService` in `lib/net_sender.dart` so one operation owns immutable per-send state until its future has completely unwound. Today `busy` is derived from the transfer status. `cancel()` immediately changes that status to `cancelled`, so a second send can start while the first `prepare` or upload is still awaiting I/O. The second call resets shared `_cancelled`, `_current`, `_peer`, and `_sessionId`; when the old call resumes it can send files into, or clear, the new session. Cancellation during the receiver's 30-second consent wait is the simplest reproduction.

Use a mutex/in-flight future or a per-operation context with a cancellation token. Do not report the service idle until the old operation has stopped producing requests and completed cleanup. Cancellation must actively abort pending HTTP work, including `prepare`, rather than merely changing UI state. A late response from an old operation must not mutate a newer transfer. Give each outgoing `TransferSession` its actual negotiated session ID or a separate stable local ID instead of leaving every outgoing ID empty.

Add tests with a controllable fake server for cancel-during-prepare followed immediately by send, cancel-during-upload followed by send, late prepare responses, and repeated Stop presses. Assert that requests and state never cross between sessions and that at most one `send()` owns the client at a time.

## 6. P0 — FIXED - Add bounded network timeouts without breaking large streamed files

Add phase-appropriate timeouts and abort behavior to `lib/net_sender.dart`, `lib/net_discovery.dart`, and `lib/net_server.dart`. The send client currently has no connection, response-header, consent, idle-upload, verify, finish, or cancel timeout. A peer that accepts a TCP connection and never answers can leave a transfer pending forever. The manual poller times out connection setup and response headers but not the response body; its periodic async callback has no overlap guard, so slow or malicious peers can accumulate polling passes.

Use short connection/header timeouts, the documented consent deadline plus a small transport margin for `prepare`, and inactivity timeouts rather than a fixed whole-transfer deadline for upload/download so a healthy multi-gigabyte transfer remains valid. Abort sockets/requests on cancellation or timeout, return localized high-level states while retaining useful OS detail, and ensure the receiver's stale-session cleanup is triggered. Serialize or guard `_pollAll`, bound the info response size, and apply a body timeout.

Add fake-server tests for no headers, a body that never finishes, a stalled upload, slow but continuously progressing upload, and overlapping timer ticks. `SPEC.md` readiness criterion 8 (Wi-Fi loss produces an error rather than a hang) must be demonstrably satisfied.

## 7. P0 — FIXED - Fix Android notification action handling while the app is backgrounded

Correct `lib/android_helpers.dart` to follow the action-delivery contract of `flutter_local_notifications` 19.5.x. The Accept and Decline `AndroidNotificationAction`s use the default `showsUserInterface: false`. On Android those actions are delivered to `onDidReceiveBackgroundNotificationResponse` in a separate Flutter engine when the UI is sleeping, but initialization registers only `onDidReceiveNotificationResponse`. Consequently the lock-screen/background buttons can do nothing and the request times out.

Choose a robust design and implement it end to end. Either make actions show the UI so they are handled on the main isolate, or register an `@pragma('vm:entry-point')` top-level background callback and bridge the answer safely to the live receive session. Do not attempt to complete the main-isolate `_askCompleter` directly from another isolate. Handle process/activity recreation, duplicate actions, notification dismissal, and timeout deterministically. Keep tapping the notification body behavior intentional and documented.

Add Android-level or plugin-boundary tests for Accept and Decline while resumed, backgrounded, screen-locked, and after activity recreation. Each request must receive exactly one answer within the 30-second protocol window.

## 8. P0 — FIXED - Redesign discovery so custom transfer ports can discover each other

Fix the discovery algorithm in `lib/net_discovery.dart` and update `SPEC.md` if the protocol contract changes. Each instance binds UDP to `currentPort` and broadcasts to that same port. If device A uses 15353 and device B uses 16000, A sends only to 15353 while B listens only on 16000, and vice versa. Including the TCP port inside a packet cannot help deliver a packet that was never received. This contradicts the settings UI and SPEC section 5.1, which say non-default ports are still discovered automatically.

Introduce a stable, well-known UDP discovery port independent of the configurable HTTP transfer port, or another interoperable mechanism with equivalent behavior. Keep the advertised transfer port in the payload. Define migration/compatibility behavior for existing builds and avoid binding conflicts when multiple interfaces are present. The UI should make clear which port is configurable.

Add two-process integration tests where peers use the same port and different transfer ports. Both must discover each other and send to the advertised HTTP port.

## 9. P1 — FIXED - Compute real broadcast targets instead of assuming every LAN is /24

Replace `_broadcastTargets()` in `lib/net_discovery.dart`. It rewrites every local IPv4 address to `x.y.z.255`, assuming a `/24`. That is not the directed broadcast address on `/16`, `/20`, `/23`, or many VPN/corporate networks, and limited broadcast is not guaranteed to be forwarded on every interface. Devices can therefore be in the same subnet and still fail readiness criterion 1.

Obtain interface prefix/netmask information using an appropriate maintained platform API/plugin or replace directed broadcast with a well-supported local multicast design. Calculate a target per active interface, handle multiple addresses and network changes, and deduplicate targets. Do not infer a netmask from private-address ranges. Add pure tests for broadcast calculation across common prefixes plus an integration test on a non-/24 virtual network.

## 10. P1 — FIXED - Never mark a manual device online when its IP now belongs to another device

Fix manual-device polling in `lib/net_discovery.dart`. `_pollAll()` accepts any successful `/info` response at the saved address, updates the stored device's name/platform/lastSeen, but never checks that `info['id']` equals `device.id`. After DHCP reassigns an address, EasySend can show the old entry as online and send selected files to a different device. This is an accidental identity mismatch that can be detected even though cryptographic authentication is intentionally out of scope.

Require a non-empty matching ID before refreshing a saved device. On mismatch, keep the original identity and trust record, mark it offline, show enough state for the user to edit/re-add its address, and never silently rebind trust. Immediately before a manual send, re-query `/info` and verify the selected ID to reduce the poll-to-send race. Validate manual address/port input instead of silently replacing an invalid explicit port with `currentPort`.

Add tests for matching ID, empty ID, changed ID after DHCP reassignment, malformed info JSON, and reassignment between the last poll and Send.

## 11. P1 — FIXED - Preserve folder structure when restoring the last sent batch

Fix the Restore feature in `lib/home_screen.dart`. `_lastSentPaths` stores every individual `FileItem.sourcePath`. `_restoreLastBatch()` passes those file paths back to `collectFiles()`, which assigns each file only its basename. Restoring a successfully sent folder therefore flattens its hierarchy, can discard same-named files as duplicates, and sends a different manifest from the original.

Store either the original user-selected roots or an immutable snapshot containing each source path and original relative path. Re-stat files on restore, retain directory-relative paths, report missing/changed files accurately, and avoid holding mutable `FileItem.done/failed` state from the completed transfer. Cover a folder with nested files, equal basenames in different subdirectories, a mix of standalone files and folders, and files removed between send and restore.

## 12. P1 — FIXED - Restore the missing transfer UX and correct incoming progress

Bring `lib/home_screen.dart` and `lib/net_server.dart` back in line with SPEC sections 3.3, 4, and 5.6.1 and with the changelog claim. The receiver never updates `TransferSession.currentIndex`, so every incoming transfer displays the first filename and `1/N` for its entire duration. A partial outgoing transfer is labeled `Received`. There is no Retry button even though the SPEC and changelog require one that resends only failed files. Completed transfer rows are not tappable, so the documented ability to open a received file or its folder from the finished entry is also missing.

Update incoming current-file state when an upload starts. Make direction-specific status text. Add Retry for eligible outgoing partial/failed transfers, resolve the peer by `peerId` at click time, resend only failed/not-done source files, and handle offline or missing peers without losing the retry set. Make a completed incoming single-file row open that file and a multi-file/folder transfer open the relevant receive directory; handle files moved after receipt gracefully. Ensure transfer records retain the final destination paths needed by this UI without exposing unsafe paths.

Add widget/state tests for multi-file incoming progress, outgoing partial wording, retry after a peer address changes, offline retry, and opening single- versus multi-file results.

## 13. P1 — FIXED - Make Android network/service lifecycle idempotent and race-safe

Refactor lifecycle coordination in `lib/home_screen.dart` and `lib/android_helpers.dart`. `_startNetwork()` calls `androidService.attach()` every time Android resumes; `attach()` adds the same `transfersTick` listener repeatedly, while `dispose()` removes it only once. Repeated background/foreground cycles therefore multiply service sync calls and retain the screen state after disposal. `_startNetwork()` and lifecycle `stop()` are also uncoordinated async operations: a permission request or overlapping resume can allow an older start to finish after the app has paused with background receiving disabled.

Create an idempotent lifecycle controller with explicit desired state and serialized start/stop transitions. Attach global listeners once and detach exactly once. Re-check lifecycle/background-receive intent after every awaited permission call before opening sockets. Prevent overlapping `receiveServer.start()`, `discovery.start()`, and poller starts. Do not stop active transfers, but transition to the desired idle state immediately after they finish.

Add lifecycle tests for many pause/resume cycles, pause during permission prompts, rapid resume/pause/resume, switching background receive, and widget disposal. Assert one listener, one server/socket/timer, and final state matching the latest lifecycle event.

## 14. P1 — FIXED - Correct foreground-service lock ownership and recovery

Fix lock state in `lib/android_helpers.dart` and `android/app/src/main/kotlin/a/a/easysend/TransferService.kt`. Native locks are acquired only for `ACTION_START`. When background receive has already started the service, a later transfer sends `ACTION_UPDATE`, so it does not establish a fresh transfer lock. The partial wake lock has a six-hour timeout; after it expires, later updates never reacquire it, while the Wi-Fi lock remains indefinitely. Dart's `_serviceUp` can also remain true after Android destroys/recreates the service, causing an update-started service to run without locks.

Model idle-listening and active-transfer modes explicitly. Acquire or refresh the CPU/Wi-Fi locks on transition into an active transfer, release transfer-only locks on transition back to idle when safe, and make every command idempotent after service recreation. Avoid an unbounded high-performance Wi-Fi lock unless it is truly required for idle receive; document the battery tradeoff. Ensure timeout safety does not make all transfers after six hours unreliable.

Add Kotlin unit/instrumentation tests for idle start, active transition, active completion, lock timeout/re-entry, duplicate commands, service recreation, and stop.

## 15. P1 — FIXED - Validate settings by schema and save them atomically

Harden `loadSettings()` and `saveSettings()` in `lib/settings_helpers.dart`. `loadSettings()` copies any JSON value for a known key into `xdef` without checking its type or range. Syntactically valid JSON such as `{"settings":{"Device name":5}}` completes loading and then crashes in `initIdentity()` outside the catch. Invalid ports and receive paths can likewise reach runtime code. Saving writes directly to `settings.json`; interruption can truncate it, and concurrent saves are not serialized. Renaming a damaged file to a fixed `.bad` name can itself fail if that backup already exists.

Define a typed schema with defaults and migrations. Validate strings, booleans stored in the current representation, language/theme membership when their assets are available, port range, device records, IDs, and receive-folder values. Preserve usable fields when one field is invalid and log/report the fallback. Serialize saves and write to a same-directory temporary file, flush it, then atomically replace the destination. Preserve damaged files under collision-free timestamped names.

Add tests for wrong-but-valid JSON types, out-of-range ports, partially valid files, duplicate/bad devices, existing `.bad` backups, concurrent saves, and interruption before replace.

## 16. P1 — FIXED - Enforce protocol resource limits before consent or allocation

Harden public HTTP parsing in `lib/net_server.dart` and `/info` parsing in `lib/net_discovery.dart`. `prepare` reads an unbounded body into memory and accepts an unbounded number of files, path lengths, IDs, sender names, and declared totals. A LAN peer can consume memory/CPU, create an unusable acceptance dialog, or keep the receiver busy with a huge manifest even when the user ultimately declines. `/info` is likewise read without a size limit.

Define documented protocol limits for JSON body bytes, file count, per-field UTF-8 length, path depth/length, file size, total declared size, and response size. Reject oversized requests while streaming, before decoding or displaying a prompt, with a stable status/reason. Validate `Content-Type` where appropriate and reject non-object JSON or values of the wrong type without returning 500. Limits should comfortably support the stated 500-file and 4-GB readiness cases and should not buffer file-upload bodies.

Add boundary and over-limit tests, including chunked JSON without `Content-Length`, deeply nested paths, duplicate IDs, huge numeric values, invalid UTF-8/JSON shapes, and a slow oversized body.

## 17. P1 — FIXED - Complete cross-platform filename validation

Finish `sanitizeRelPath()` in `lib/file_helpers.dart`. It claims to make names portable to Windows but does not reject Windows-invalid characters `<`, `>`, `"`, `|`, `?`, and `*`; it silently removes control characters and trailing spaces, which can collapse distinct manifest paths onto the same destination. It also needs platform-aware handling for case collisions and path/component length limits.

Choose a deterministic contract: preferably reject invalid or lossy names at `prepare` rather than silently mutate them. Apply Windows reserved-name rules correctly regardless of extension and case, cover trailing dots/spaces, and enforce safe component/path lengths with actionable failure reasons. Coordinate this with the manifest-wide reservation work so two accepted entries always remain distinct on the destination filesystem.

Add table-driven tests for all forbidden characters, control characters, reserved names with extensions/case, trailing dot/space, Unicode names, maximum lengths, and two raw names that would normalize to the same target.

## 18. P1 — FIXED - Stop the release script from downgrading the product version line

Fix version ownership in `10-MakeRelease.sh`. The repository currently declares `0.2.260810+64` in `pubspec.yaml` and `0.2.260810` in `lib/globals.dart`, but the script hard-codes `GLOBVERS="0.1"`. The next release run will rewrite both files to `0.1.<date>+65`, silently regressing the public version line. Multiple manually synchronized constants make this easy to repeat.

Use one authoritative product-version source or derive the major/minor line from the current validated version. Update all generated consumers from it, fail before mutation if versions disagree, and make the bump transactional so a failed build does not leave a misleading partial version state. Preserve the intended monotonically increasing Android `versionCode`. Add a dry-run/testable version function covering day changes, major/minor changes, malformed input, and a failed build.

## 19. P2 — FIXED - Implement the remaining user-visible SPEC promises or revise the SPEC

Resolve the following concrete documentation/code mismatches instead of leaving dead settings keys and misleading promises:

- `xdef['.First start']` is never consumed. SPEC section 9 requires a one-time warning that traffic is unencrypted and unsafe on public/guest networks, plus access to the warning from Settings; only README currently contains it.
- The initial language is always English. SPEC section 8 says first launch uses the supported system language and can then be overridden.
- Desktop window size and position are not persisted, although SPEC section 7 says they are remembered.
- The Android fallback device identity is stored only in private settings. SPEC section 5.3 requires a `.easysend-id` copy in the receive folder when `ANDROID_ID` is unavailable so reinstall does not break trust.

Implement these promises with migrations and tests, or deliberately edit `SPEC.md`/README and remove unused keys if the product decision has changed. For the security notice, do not mark first start complete until the notice has actually been shown. For locale detection, map the standard Ukrainian code `uk` to the asset's current `ua` key or migrate the data to `uk`. For the external ID fallback, validate ownership/content and do not overwrite a valid existing ID silently.

## 20. P1 — FIXED - Establish an automated regression suite for the transfer core

Create a `test/` suite and any small testability seams needed around filesystem, HTTP, clock/timers, notifications, and platform services. `flutter test` currently fails with `Test directory "test" not found`, so none of the protocol, path, retry, settings, discovery, or lifecycle invariants are protected. Do not rely only on widget golden tests.

At minimum cover path sanitization/containment, manifest planning, zero-byte and multi-gigabyte declared sizes without allocation, CRC success/mismatch/retry, cancellation at every protocol phase, session timeout/recovery, sender serialization, progress/speed/ETA math, settings migration, device online expiry, manual-ID mismatch, custom-port discovery design, and the key HomeScreen transfer states. Use loopback fake peers and temporary directories; tests must be deterministic and must not need a real LAN or Android device except for a clearly separated instrumentation group.

Make `flutter analyze` and `flutter test` the default local/CI verification commands. Fix the two current analyzer infos in `lib/ui_helpers.dart` while touching the suite, and keep the working tree free of generated test artifacts.

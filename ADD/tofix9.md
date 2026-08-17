# EasySend — audit of the platform code, the build scripts and the test harness, 2026-08-17

Scope was named by the user: the surfaces no previous audit has read.

- `android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt`, `MainActivity.kt`,
  `TransferService.kt`, and `android/app/src/main/AndroidManifest.xml`;
- every shell script in the project root (`00`, `01`, `05`, `06`, `10`, `11`, `12`,
  `13`, `14`, `20`, `21`, `22`, `77`, `99`);
- `lib/control_body.dart` and `lib/settings_helpers.dart`;
- the test suite's own hygiene — what a test leaves behind for the next one.

Product contract: `SPEC.md` as of this commit (5.3 identity, 7 Android specifics,
10 architecture and the release transaction), the global rules of the project
(one developer, release builds only, the user owns versioning), and
`ADD/tofix1.md`…`ADD/tofix8.md`, whose findings are all marked fixed, accepted or
measured.

Baseline: working tree clean at `46f8260` (build 112), `05-Lint.sh` clean,
`06-Test.sh` 360 tests green.

Every finding below is a code fact, read off the file and quoted with its line.
Two carry a condition that does not hold today and is named in place (findings 3
and 5), and one rests on how `flutter_launcher_icons` behaves when its input has
not changed (finding 1). Nothing here was reproduced by running a release build:
building is the user's step in this project, so the release scripts were read, not
executed. The one thing that was run is `bash -c 'set -e; false && echo x'`, to
settle whether the `[ -z "$apk" ] && apk=…` chains in `11`/`12` abort under
`set -e` — they do not.

## System model

**Who owns what.** Three processes' worth of state, and the scripts that move
files between them.

- `EasySendApplication` owns the Flutter engine, the method channel, the multicast
  lock and the "service timed out" flag in SharedPreferences. It outlives every
  Activity, which is the whole point (SPEC 7).
- `MainActivity` owns only what a screen can: the document picker's request code,
  the exit-request extra, and the cache directory copies of picked documents. It
  is destroyed and re-created freely, so anything that must survive that is handed
  to the Application.
- `TransferService` owns the ongoing notification, the wake lock and the Wi-Fi
  lock. It reports its own death (`serviceGone`) and its own refusal
  (`reportServiceTimeout`) to Dart, because Dart cannot observe either.
- The scripts own the artifacts. `10-MakeRelease.sh` owns the build counter and the
  two version files; `14-MakeAppImage.sh` owns the AppImage; `01-LinkOut.sh` owns
  the contents of `OUT/`; `20`/`21` own the tag and the changelog stamp; `22` owns
  the GitHub release; `77` owns the signing keystore, the only asset here that
  cannot be regenerated.
- The tests own no state at all, and that is the problem finding 6 is about: they
  borrow globals — `xdef`, `xvDevices`, `xvTransfers`, `xvNow`, `xvConfigDir`,
  `xvRecvDir` — and each file puts them back by hand, or does not.

**Lifecycle of a release.** `10` bumps both version files → builds four APKs →
renames them through a staging directory → verifies the set → commits the
transaction (`RELEASE_COMMITTED=true`) → prunes older APKs → optionally folds the
bump into the previous commit. Then `14` packs the Linux bundle, `01` links the
three artifacts into `OUT/`, `20` stamps the changelog and tags, `21` pushes, `22`
uploads to GitHub.

**Where untrusted data crosses in.** Nowhere new in this scope. The Kotlin side
receives only its own PendingIntents and the document picker's result; the scripts
read `pubspec.yaml`, `AndroidManifest.xml` and `CHANGELOG.md`, all of them ours.
The picked document's display name is the one piece of outside text, and
`displayName()` reduces it to `File(value).name`.

**Invariants.**

- **J1.** The version in `pubspec.yaml` and in `lib/globals.dart` agree, and an
  artifact's name states the build that is inside it.
- **J2.** A release is all-or-nothing: either every artifact exists under its final
  name and the version files are bumped, or nothing moved.
- **J3.** What a build produces is what the commit records — no tracked file is
  rewritten as a side effect of building.
- **J4.** `OUT/` holds the newest build and nothing else, and never loses an
  artifact that is still the newest of its kind.
- **J5.** A secret is never readable by anybody but its owner, at any moment of its
  existence.
- **J6.** A test starts from a known state and leaves none behind.
- **J7.** Anything Dart believes about the foreground service is something the
  service told it (SPEC 7).

## Findings

### 1. P2 [FIXED f59a88d] — A release build rewrites tracked launcher resources, so a release can carry icons no commit records

**Affected components:** `10-MakeRelease.sh` (the build section, `dart run
flutter_launcher_icons` at line 160); `android/app/src/main/res/mipmap-*/`,
`res/drawable-*/ic_launcher_foreground.png` (tracked); the amend condition at
lines 235-248; `pubspec.yaml` `flutter_launcher_icons:`; SPEC 10.

**Current behavior and reproduction:** every release build regenerates the
launcher resources from `assets/icon_small.png` and `assets/icon_fg.png`:

```sh
flutter pub get
dart run flutter_launcher_icons          # 10-MakeRelease.sh:160
```

Ten tracked PNGs are the output. When the icon sources have changed since the last
release, the build leaves those ten files modified in the working tree, and two
things follow.

First, the amend condition further down compares the dirty set against exactly the
two version files:

```sh
DIRTY=$(git status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')
if [[ "$DIRTY" == "$GLOB_FILE $PUB_FILE " ]]; then     # :237
```

With the regenerated icons in the way this is false, so the bump is left
uncommitted with ">>> Other changes present" — correct, but for a reason the user
did not cause and is not told about.

Second, and worse: the APK that was just built carries the new icons while the
commit the version bump belongs to records the old ones. Nothing in the release
path notices. It happened in this very session — the regenerated files sat in the
tree from a build at 11:53 and were swept into commit `e33a1ee`'s predecessor
`e38b324`, which is a Dart fix and has ten binary PNGs in it. The user has decided
to leave that commit as it is; the script behaviour is what this finding is about.

**Assumption named:** that `flutter_launcher_icons` writes byte-identical files
when its input has not changed, so an ordinary release leaves no diff and this only
bites after an icon change. That is how it behaved here today, and it is why the
problem is rare enough to have gone unnoticed.

**Root cause:** J3 is not enforced. A build step writes tracked source files, and
the release transaction (J2) covers artifacts and version files only — it neither
refuses to start on a dirty resource tree nor records the regenerated resources as
part of what it produced.

**Required outcome:** a release build cannot end with tracked files silently
modified. Either the icons are regenerated before the release and committed as
their own change — the project already has commits shaped exactly like that
("Regenerate the launcher icons for the new mark") — and the release then refuses
to run while `android/app/src/main/res` is dirty; or the regeneration stays in the
build and the release names those files as part of its output, so the run says out
loud what it rewrote and the user commits them deliberately. Either way the APK's
icons and the commit's icons agree.

**Constraints:** the user owns versioning and commits (global rules): the script
must not commit resources on its own beyond the existing, deliberate amend of the
two version files. A build must stay possible on a dirty tree — that is stated in
the script's own header. `dart run flutter_launcher_icons` must keep running
somewhere, or an icon change would never reach the launcher.

**Tests to add:** extend `test/release_transaction_test.dart` — its fake `flutter`
already stands in for the build. Add a fake `dart` that dirties a file under
`android/app/src/main/res`, and assert whatever the chosen answer is: either the
run refuses before touching the version files, or its output names the rewritten
resource and the version bump is still left uncommitted. The existing "dirty git
state leaves a completed version bump unamended" case is the one to model it on.

### 2. P2 [FIXED a90b05e] — A partial `01-LinkOut.sh` run deletes the previous good AppImage before reporting the failure

**Affected components:** `01-LinkOut.sh` — `link_latest()` (lines 28-42), the
sweep (lines 52-61), the exit at line 63; `00-MakeAll.sh` (runs it as optional).

**Current behavior and reproduction:** each artifact is linked by its own call, and
a missing one only sets a flag:

```sh
if [ -z "$newest" ] || [ ! -f "$newest" ]; then
    echo ">>> nothing to link into OUT"
    MISSING="yes"
    return 0            # 01-LinkOut.sh:34
fi
```

The sweep then runs unconditionally and removes everything in `OUT/` that is not
among the names linked *this run*:

```sh
case " $LINKED " in
    *" $(basename "$entry") "*) continue ;;
esac
rm -f "$entry"          # :59
```

and only afterwards does the script report the failure (`[ -n "$MISSING" ] && exit
1`). So a run with no Linux build present — `14-MakeAppImage.sh` not run yet, or
run for an older build — links the two APKs, deletes the AppImage that was sitting
there from the previous build, and exits 1. `OUT/` is advertised as "one place to
copy the build from"; after such a run it holds two thirds of a release and the
artifact that took the longest to produce is gone.

**Root cause:** J4 is not enforced. The sweep's rule is "keep what this run
linked", which quietly means "delete what this run could not link", and the
missing-artifact case is discovered before the deletion but acted on after it.

**Required outcome:** a run that cannot link every artifact does not remove the
ones already there. Either it refuses before sweeping, or the sweep keeps any
artifact of a kind it failed to link this time.

**Constraints:** the sweep must keep doing its job on a complete run — the previous
build's names, an ABI no longer built and stray copies all still go (that is the
point of the script). A directory somebody made inside `OUT/` is still not ours to
remove. Nothing here may build anything.

**Tests to add:** a shell-driven test in the shape of
`test/release_transaction_test.dart`: a fixture `OUT/` holding last build's
AppImage and APKs, a `build/` tree with the two APKs but no AppImage, then run the
script and assert the old AppImage is still there and the exit code is non-zero.

### 3. P3 — `99-CopyToAPKX.sh` names the link from one source and fills it from another

**Affected components:** `99-CopyToAPKX.sh` lines 19-40.

**Current behavior:** the build number comes from `pubspec.yaml` and the file comes
from the directory listing, with nothing tying the two together:

```sh
BUILD=$(grep -oP '^version:\s*[0-9.]+\+\K[0-9]+' "$PUB_FILE")
apk=$(ls -t "$APK_DIR"/*arm64-v8a*.apk 2>/dev/null | head -1)
...
dst="${PROJ_TITLE}-${BUILD}.apkx"
ln -sf "$apk" "$dst" 2>/dev/null || cp "$apk" "$dst"
```

The APK's own name already carries its version and build (`10-MakeRelease.sh`
names it that way), so the two can be compared — and when they differ, the `.apkx`
that gets sent over a messenger claims a build it does not contain. That happens
whenever the newest arm64 APK is not the current build: a release build that failed
after the rename and rolled the version files back, a version edited by hand, or
`10` run with `--dry-run` beforehand.

**Condition named:** in the ordinary flow `99` runs right after a successful `10`
and the two agree. This is the off-path case, not today's state.

**Root cause:** J1 is not enforced at the one place where a name is invented rather
than copied.

**Required outcome:** the name states the build that is inside the file. Either the
build number is taken from the APK's own name, or a mismatch is refused with a
sentence naming both.

**Constraints:** the short `.apkx` name is the whole point of the script — a
messenger mangles `.apk` — so the shape `<Title>-<build>.apkx` stays. Plain
`.apkx` files that are not links are copies someone made on purpose and are still
left alone.

**Tests to add:** a fixture directory with `EasySend-0.4.260817-111-arm64-v8a.apk`
as the newest file and `version: 0.4.260817+112` in a fake pubspec; the script
either refuses or produces `EasySend-111.apkx`, and in no case produces
`EasySend-112.apkx` pointing at the 111 file.

### 4. P3 — The key properties file is written world-readable and tightened afterwards

**Affected components:** `77-MakeMyKey.sh` lines 61-77.

**Current behavior:** the keystore is created by `keytool` and the properties file
by a plain redirect, both at the process umask, and only then are the modes fixed:

```sh
keytool -genkeypair -v -keystore "$STORE" ... -storepass "$STORE_PASS" -keypass "$STORE_PASS"

cat > "$PROPS" <<PROPERTIES
storeFile=$STORE
storePassword=$STORE_PASS
...
PROPERTIES

chmod 600 "$PROPS" "$STORE"      # :77
```

Between the redirect and the `chmod` the cleartext password sits in a file with the
default mode — 644 on a stock Ubuntu umask. The directory above it is already
`chmod 700`, which narrows the exposure to processes running as this user, so on a
single-user machine the practical risk is small; the ordering is still wrong, and
the fix is one line. The password also travels through `keytool`'s argv, where any
process on the machine can read it out of `/proc` while the command runs.

**Root cause:** J5 is not enforced — the secret exists before its protection does.

**Required outcome:** the password file is never readable by anybody but its owner
at any point, and the password does not appear in a command line.

**Constraints:** the script must stay a one-shot that refuses to touch an existing
keystore — that refusal is what protects every installed copy of the app. It must
keep working with the JDK's own `keytool`, and `android/app/build.gradle.kts` reads
the same four properties by name.

**Tests to add:** none as a Dart test — this is a shell one-shot. A probe instead:
run it against a temporary `HOME`, and check the mode of `key.properties` between
creation and the end (`umask 077` at the top makes that unobservable, which is the
point), then `ps` the `keytool` invocation for the password.

### 5. P3 — A system-installed `appimagetool` aborts the AppImage build

**Affected components:** `14-MakeAppImage.sh` lines 54-63.

**Current behavior:** the tool is looked up on `PATH` first and in `~/Downloads`
second, and then chmodded unconditionally:

```sh
APPIMAGETOOL=$(command -v appimagetool || true)
[ -z "$APPIMAGETOOL" ] && APPIMAGETOOL=$(ls -t "$HOME"/Downloads/appimagetool*.AppImage 2>/dev/null | head -1)
...
chmod +x "$APPIMAGETOOL"      # :63
```

With the tool installed system-wide — `/usr/bin/appimagetool`, root-owned and
already executable — `chmod` fails with EPERM, and `set -e` at the top of the file
ends the script before the build starts. The message is `chmod: changing
permissions of ...: Operation not permitted`, which says nothing about AppImages.

**Condition named:** here the tool lives in `~/Downloads`, so this does not fire
today. It fires on any machine where it was installed with a package manager.

**Root cause:** no invariant; a convenience applied to a file the script does not
own.

**Required outcome:** the build runs when the tool is already executable, wherever
it lives, and only tries to make it executable when that is both needed and
possible.

**Constraints:** the downloaded-file case must keep working, including a fresh
download with no execute bit. The missing-tool message with its `wget` line stays.

**Tests to add:** a probe with a read-only fake `appimagetool` on `PATH`: the
script gets past the toolchain checks instead of dying on `chmod`.

### 6. P3 — Global test state is restored by convention, and the conventions differ per file

**Affected components:** all 41 files in `test/`; `lib/globals.dart` (`xdef`,
`xvNow`, `xvTransfers`), `lib/settings_helpers.dart` (`xvDevices`, `xvConfigDir`,
`xvRecvDir`); no shared helper exists — `ls test/*helper*` finds nothing.

**Current behavior:** every test that needs a global sets it, and putting it back
is up to the author. The tally today: 31 of 41 files mutate at least one global;
six mutate `xdef` with no `tearDown` in the file at all
(`accept_dialog_test.dart`, `android_engine_lifetime_contract_test.dart`,
`device_name_validation_test.dart`, `network_timeout_test.dart`,
`receive_banner_text_test.dart`, `refused_names_dialog_test.dart`). Most of those
are harmless — `xdef['Program language'] = 'en'` in `setUp` writes the value that
was already there — and `network_timeout_test.dart:313` leaves `xdef['Port'] = '0'`
behind in the last test of its file, where nothing reads it afterwards. So there is
no defect on the board right now; what there is, is a rule nothing enforces.

`xvNow` (added earlier today) is the newest member of that pile and the most
dangerous one, because a leaked stubbed clock does not fail loudly — it makes an
unrelated test's device look permanently online or permanently stale.
`discovery_admission_test.dart` restores it nine times out of nine, by hand.

Test files run in separate isolates, so leakage never crosses files: this is about
one file's tests poisoning the next test in the same file.

**Root cause:** J6 is stated nowhere and enforced nowhere.

**Required outcome:** a test cannot leak global state into the next one in its
file, and a new test does not have to remember which globals exist to be safe.

**Constraints:** no new package, and the existing 360 tests keep passing with no
rewrite of their bodies. `flutter test` must stay the runner (`06-Test.sh`).

**Tests to add:** the mechanism is the test — one helper in `test/` that resets
every global to its default and is called from `setUp`, and one test asserting that
after the reset `xvNow`, `xdef`, `xvDevices` and `xvTransfers` hold their defaults.
A grep-style meta-test that every file mutating a global also installs the reset
would pin it for files added later.

### 7. P3 — Two membership tests are substring matches where they mean equality

**Affected components:** `01-LinkOut.sh` lines 56-58; `21-PushTag.sh` line 47.

**Current behavior:** both ask "is this name in that list?" by pattern:

```sh
case " $LINKED " in                                  # 01-LinkOut.sh
    *" $(basename "$entry") "*) continue ;;
esac

if git ls-remote --tags "$REMOTE" "$LAST_TAG" | grep -q "$LAST_TAG"; then   # 21
```

The first breaks on a name containing a space: `LINKED` is a space-joined string,
so with `android:label="Easy Send"` — which `10-MakeRelease.sh` uses verbatim in
artifact names — the just-linked file fails its own membership test and the sweep
deletes it. The second is a bare `grep` of an unanchored, unescaped pattern: a tag
that is a prefix of another (`v0.4.2608` beside `v0.4.260817+112`) reads as "already
pushed on the remote", and the tag is never pushed. Neither condition holds in this
repository today — the label is one word, the tags are all full versions — and both
are one line away from the exact test they mean.

**Root cause:** no invariant; the wrong comparison for the question.

**Required outcome:** the two tests answer about exact names.

**Constraints:** `01` must keep sweeping everything that is not part of this build;
`21` must keep skipping a tag that really is on the remote.

**Tests to add:** for `01`, a fixture whose artifact names contain a space, with the
linked file still present after the sweep. For `21`, a probe with two tags where one
is a prefix of the other.

### 8. P3 — `00-MakeAll.sh` exits 0 after a step failed, not only after one was absent

**Affected components:** `00-MakeAll.sh` `run()` (lines 21-36) and the closing
report (lines 47-52).

**Current behavior:** a failing optional script and a missing one land in the same
bucket:

```sh
echo ">>> $1 failed"
[ "$2" = "fatal" ] && exit 1
SKIPPED="$SKIPPED $1"      # :35
```

and the run ends with `Done, without: 12-PhoneRELEASE.sh` and exit status 0. A
phone that is not plugged in and a phone that refused the install — a signature
mismatch, no space, a locked bootloader — are told apart in the log and nowhere
else. Anything driving this script, including a shell loop or a future CI step,
reads success.

**Root cause:** the script's own rule ("a device that is not plugged in does not
stop the run") is right, but it is implemented as "nothing optional can fail",
which loses the difference between absent and broken.

**Required outcome:** the exit status distinguishes a complete run from one where
an optional step failed, while an absent device still does not stop the build.

**Constraints:** the AppImage must still be built when no device is connected —
that is why those steps are optional. `10` and `14` stay fatal.

**Tests to add:** a probe with a stub `12-PhoneRELEASE.sh` that exits 1: the run
still reaches `14` and `01`, and the final status is non-zero.

### 9. P3 — ACCEPTED — What the Kotlin side was read for, and the two cosmetics found

**Affected components:** `EasySendApplication.kt`, `MainActivity.kt`,
`TransferService.kt`, `AndroidManifest.xml`.

**Current behavior:** read end to end against J7 and SPEC 7, and it holds. Recorded
here so the next audit does not re-derive it:

- every argument the notification is built from is put into the Intent and read
  back by the service (`EXTRA_*`), which the contract test also pins;
- `startForeground` is wrapped, and a refusal drops the locks, reports the timeout
  through SharedPreferences *and* the channel, and stops the service instead of
  taking the process down;
- the two notification buttons have distinct request codes, and the one that has a
  question to ask goes to the Activity rather than the service (Android 12+);
- `EXTRA_EXIT_REQUESTED` is removed from the Intent as it is consumed, so a
  recreated Activity does not exit on its own;
- the multicast lock lives in the Application and is released only when Dart says
  discovery stopped;
- `specialUse` carries the `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` property Android 14
  requires, and `foregroundType()` picks `dataSync` only for a running transfer;
- copies of picked documents each get a directory of their own, so two documents
  with one display name cannot overwrite each other.

Two cosmetics, deliberately not worth a fix:

- `onDestroy()` notifies Dart `serviceGone` even when Dart asked for the stop, so
  `noteServiceGone()` clears state `_stop()` had already cleared. Idempotent, and
  the alternative is a flag that has to be right on every path.
- `13-MakeLinux.sh` and `14-MakeAppImage.sh` both assign `GLOB_FILE` and never use
  it, and `11`, `12`, `20`, `21`, `22`, `99` end with a bare `sleep 2`/`sleep 3`.
  Harmless, and shared by every script in the family.

**Cross-reference:** finding 1 touches `10-MakeRelease.sh`, whose transaction is
the subject of `ADD/tofix3.md` finding 17 (fixed) — that one closed the
artifact-set hole, this one is about tracked files the build rewrites. Finding 6
touches every test file, including the ones the earlier audits added.

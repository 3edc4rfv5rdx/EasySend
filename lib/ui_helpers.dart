import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'globals.dart';
import 'net_server.dart';

// A list row whose last element is an icon button. The stock trailing slot adds
// 16 px of its own padding outside the button's 48 px tap target, pushing the
// icon a thumb's width in from the edge and taking that width from the text
// beside it — long names and addresses wrapped onto an extra line for nothing.
// Only the padding goes: the button keeps its full 48 px target.
const EdgeInsets rowPadding = EdgeInsets.only(left: 16, right: 0);

// Shared look for dialog action buttons, so every dialog stays identical.
ButtonStyle get dialogButtonStyle => TextButton.styleFrom(
  backgroundColor: clAccent,
  foregroundColor: onColor(clAccent),
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(btnRadius)),
  elevation: 4,
  minimumSize: const Size(60, 40),
);

// The way out of a dialog: No, Cancel, Decline. On the button surface rather
// than the accent, so the answer that changes nothing does not look exactly
// like the one that does.
ButtonStyle get dialogCancelStyle => TextButton.styleFrom(
  backgroundColor: clButton,
  foregroundColor: clText,
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(btnRadius),
    side: BorderSide(color: clFrame),
  ),
  minimumSize: const Size(60, 40),
);

// The button inside the port banner. It stands on a filled error strip, where
// the app's own button colour would disappear, so it inverts the banner: the
// banner's ink becomes the surface and the error colour becomes the label.
ButtonStyle get bannerButtonStyle => TextButton.styleFrom(
  backgroundColor: onColor(clError),
  foregroundColor: clError,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(btnRadius)),
  minimumSize: const Size(60, 32),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

// What the receive banner says, by the reason receiving is not ready. A rule
// with three answers belongs outside build(), where a test can read it: the
// port number is part of the sentence only when the port is the problem.
String receiveBannerText(ReceiveReadinessFailure? failure, int port) =>
    switch (failure) {
      ReceiveReadinessFailure.folder => lw(
        'Receive folder unavailable, receiving is off',
      ),
      ReceiveReadinessFailure.port =>
        '${lw('Port is busy, receiving is off')}: $port',
      ReceiveReadinessFailure.transition => lw(
        'Network setup did not finish, receiving may be off',
      ),
      null => '',
    };

RoundedRectangleBorder get dialogShape => RoundedRectangleBorder(
  side: BorderSide(color: clAccent, width: 3.0),
  borderRadius: BorderRadius.circular(btnRadius),
);

// Dialogs appear at once: showDialog fades and scales them in, which is one
// animation more than this app wants anywhere. Otherwise it is showDialog, with
// the app-wide navigator as the default context.
Future<T?> showFlatDialog<T>({
  required WidgetBuilder builder,
  BuildContext? context,
  bool barrierDismissible = true,
}) {
  final BuildContext? ctx = context ?? navigatorKey.currentContext;
  if (ctx == null) return Future<T?>.value();
  return showGeneralDialog<T>(
    context: ctx,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(ctx).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: Duration.zero,
    pageBuilder: (BuildContext context, animation, secondaryAnimation) =>
        builder(context),
  );
}

// Section heading: a 2 px rule with the name laid into it, the trailing button
// sitting in the line as well. A filled strip made every section shout; here
// the structure is the line and the only coloured area left is Send.
Widget sectionTitle(String text, {Widget? trailing}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
    child: Stack(
      alignment: Alignment.center,
      children: [
        // One rule across the whole row. The name and the button are laid over
        // it on the screen colour, so the line reads as passing behind them
        // instead of being cut into pieces that have to be measured.
        Positioned.fill(
          child: Center(child: Container(height: 2, color: clFrame)),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Container(
                color: clFon,
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fsLarge,
                    fontWeight: fwBold,
                    color: clText,
                  ),
                ),
              ),
            ),
            // The button paints its own surface, so it hides the rule by itself
            // and ends at the screen margin, in line with the buttons above.
            ?trailing,
          ],
        ),
      ],
    ),
  );
}

// The button that rides inside a section heading. One shape for all of them:
// a filled circle for one and a bare icon for the next read as two different
// kinds of thing when they are the same kind of thing.
Widget sectionButton(
  IconData icon, {
  required String tooltip,
  required VoidCallback onTap,
}) {
  return Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(btnRadius),
      child: Container(
        width: 40,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: clButton,
          border: Border.all(color: clFrame),
          borderRadius: BorderRadius.circular(btnRadius),
        ),
        // 26 in a 30 px button: MaterialIcons is not a variable font, so the
        // only way to a heavier stroke is a bigger glyph.
        child: Icon(icon, color: clText, size: 26),
      ),
    ),
  );
}

// A path as it is worth showing: on a phone every folder sits under
// androidRoot, and repeating that prefix on each line only pushes the part
// that differs off the screen. Off Android the path is left alone.
String shortPath(String path) {
  if (!path.startsWith(androidRoot)) return path;
  final String rest = path.substring(androidRoot.length);
  return rest.isEmpty ? path : rest.replaceFirst(RegExp(r'^/+'), '');
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

// One line that keeps its end. A path is told apart by the folder it finishes
// in, so when it does not fit, the head is what goes: the ellipsis moves to the
// front instead of hiding the only part worth reading.
Widget tailText(String text, {TextStyle? style}) {
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final TextStyle st = style ?? tsSmall;
      final TextPainter painter = TextPainter(
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      );
      double widthOf(String s) {
        painter.text = TextSpan(text: s, style: st);
        painter.layout();
        return painter.width;
      }

      String result = text;
      if (widthOf(text) > constraints.maxWidth) {
        // The longest tail that still fits behind the ellipsis, by halving.
        int lo = 0;
        int hi = text.length;
        while (lo < hi) {
          final int mid = (lo + hi) ~/ 2;
          if (widthOf('…${text.substring(mid)}') > constraints.maxWidth) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        // Dropping one unit more is always safe; keeping half a surrogate pair
        // would draw a replacement glyph.
        if (lo < text.length && _isLowSurrogate(text.codeUnitAt(lo))) lo++;
        result = '…${text.substring(lo)}';
      }
      painter.dispose();
      return Text(result, style: st, maxLines: 1);
    },
  );
}

Future<bool> okConfirm({
  required String title,
  required String message,
  String? yesText,
  String? noText,
}) async {
  final result = await showFlatDialog<bool>(
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title, style: tsLarge),
        content: Text(message, style: tsNormal),
        backgroundColor: clFill,
        shape: dialogShape,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: dialogCancelStyle,
            child: Text(noText ?? lw('No')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: dialogButtonStyle,
            child: Text(yesText ?? lw('Yes')),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

void showCustomDialog({
  required String title,
  required String message,
  required Color color,
  required IconData icon,
}) {
  showFlatDialog<void>(
    builder: (context) {
      return AlertDialog(
        backgroundColor: clFill,
        shape: dialogShape,
        title: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Text(title, style: tsLarge),
          ],
        ),
        content: SingleChildScrollView(child: Text(message, style: tsNormal)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: dialogButtonStyle,
            child: Text(lw('Ok')),
          ),
        ],
        elevation: 10.0,
      );
    },
  );
}

// Ask whether to accept an incoming transfer. Returns (accepted, trust).
// Unanswered after acceptTimeoutSec the dialog closes itself and declines: the
// sender must not hang waiting for someone who is not at the screen. The
// receiver can also withdraw the question through `cancelled` — once its server
// is gone, no answer means anything any more.
Future<(bool, bool)> showAcceptDialog({
  required String senderName,
  required int fileCount,
  required int totalBytes,
  Future<void>? cancelled,
}) async {
  final BuildContext? context = navigatorKey.currentContext;
  if (context == null) return (false, false);

  bool trust = false;
  BuildContext? liveDialog;
  void close() {
    final BuildContext? ctx = liveDialog;
    if (ctx != null && ctx.mounted && Navigator.canPop(ctx)) {
      Navigator.pop(ctx, (false, false));
    }
  }

  // Started here and cancelled in the finally below, never inside the builder:
  // a builder runs again whenever the route rebuilds — which is exactly what a
  // language or theme change does — and each run would start another deadline
  // while dropping the reference to the one before it, leaving a timer alive
  // after the question had already been answered.
  final Timer timer = Timer(const Duration(seconds: acceptTimeoutSec), close);
  cancelled?.then((_) => close());
  try {
    final (bool, bool)? result = await showFlatDialog<(bool, bool)>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        liveDialog = dialogContext;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: clFill,
              shape: dialogShape,
              title: Row(
                children: [
                  Icon(Icons.download_outlined, color: clAccent),
                  const SizedBox(width: 8),
                  Text(lw('Incoming files'), style: tsLarge),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    senderName,
                    style: TextStyle(
                      fontSize: fsNormal,
                      fontWeight: fwBold,
                      color: clText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$fileCount — ${formatBytes(totalBytes)}',
                    style: tsNormal,
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: trust,
                    activeColor: clAccent,
                    checkColor: onColor(clAccent),
                    title: Text(lw('Always trust this device'), style: tsSmall),
                    onChanged: (v) => setState(() => trust = v ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, (false, false)),
                  style: dialogCancelStyle,
                  child: Text(lw('Decline')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, (true, trust)),
                  style: dialogButtonStyle,
                  child: Text(lw('Accept')),
                ),
              ],
            );
          },
        );
      },
    );
    return result ?? (false, false);
  } finally {
    timer.cancel();
  }
}

String _refusalReason(PickProblem problem) => switch (problem) {
  PickProblem.tooLong => lw('the name is too long'),
  PickProblem.backslash => lw('a backslash in the name'),
  PickProblem.reserved => lw('a name Windows reserves'),
  PickProblem.notPortable => lw('characters that cannot travel'),
  PickProblem.tooLarge => lw('the file is too large'),
};

// Which picked files cannot be sent under their own names, and why — said when
// they are picked rather than when a transfer dies halfway. Returns true when
// the user asked for the repairable ones to be repaired.
Future<bool> showRefusedNamesDialog(List<RefusedPick> refused) async {
  final bool repairable = refused.any(
    (RefusedPick r) => r.problem == PickProblem.backslash,
  );
  final ScrollController scroll = ScrollController();

  final bool? answer = await showFlatDialog<bool>(
    builder: (BuildContext dialogContext) => AlertDialog(
      backgroundColor: clFill,
      shape: dialogShape,
      title: Row(
        children: [
          Icon(Icons.report_gmailerrorred_outlined, color: clWarning),
          const SizedBox(width: 8),
          Expanded(child: Text(lw('Invalid names'), style: tsLarge)),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${lw('These files cannot be sent')}:', style: tsNormal),
            const SizedBox(height: 8),
            Flexible(
              child: Scrollbar(
                controller: scroll,
                child: ListView.builder(
                  controller: scroll,
                  shrinkWrap: true,
                  itemCount: refused.length,
                  itemBuilder: (BuildContext context, int index) {
                    final RefusedPick item = refused[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Whole, wrapped over as many lines as it takes:
                          // the name is what this list is for, and two files
                          // in one folder often differ only at the end.
                          Text(item.file.relativePath, style: tsNormal),
                          Text(
                            _refusalReason(item.problem),
                            style: tsSmall.copyWith(color: clTextMuted),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            // What Fix will do, said in words rather than offered as a second
            // control: the button is already the decision.
            if (repairable) ...[
              const SizedBox(height: 8),
              Text(
                lw('replace the backslash with a dash'),
                style: tsSmall.copyWith(color: clText),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          style: dialogCancelStyle,
          child: Text(repairable ? lw('Cancel') : lw('Ok')),
        ),
        if (repairable)
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: dialogButtonStyle,
            child: Text(lw('Fix')),
          ),
      ],
    ),
  );
  scroll.dispose();
  return answer ?? false;
}

// Single-field prompt, used for the device name, the port and manual IPs.
Future<String?> showInputDialog({
  required String title,
  String initial = '',
  TextInputType? keyboardType,
  String? hint,
  String? Function(String value)? validator,
}) async {
  final TextEditingController controller = TextEditingController(text: initial);
  String? validationError;
  final String? result = await showFlatDialog<String>(
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          void submit() {
            final String value = controller.text.trim();
            final String? error = validator?.call(value);
            if (error != null) {
              setDialogState(() => validationError = error);
              return;
            }
            Navigator.pop(context, value);
          }

          return AlertDialog(
            backgroundColor: clFill,
            shape: dialogShape,
            title: Text(title, style: tsLarge),
            content: TextField(
              controller: controller,
              keyboardType: keyboardType,
              autofocus: true,
              style: TextStyle(color: clText, fontSize: fsNormal),
              onChanged: (_) {
                if (validationError != null) {
                  setDialogState(() => validationError = null);
                }
              },
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                hintText: hint,
                errorText: validationError,
                hintStyle: TextStyle(color: clTextMuted),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: clFrame),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: clAccent),
                ),
                errorBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: clError),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: clError),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: dialogCancelStyle,
                child: Text(lw('Cancel')),
              ),
              TextButton(
                onPressed: submit,
                style: dialogButtonStyle,
                child: Text(lw('Ok')),
              ),
            ],
          );
        },
      );
    },
  );
  controller.dispose();
  return result;
}

void okInfo(String message) => showCustomDialog(
  title: lw('Info'),
  message: message,
  color: clInfo,
  icon: Icons.info_outline,
);
void okErr(String message) => showCustomDialog(
  title: lw('Error'),
  message: message,
  color: clError,
  icon: Icons.error_outline,
);
void okWarning(String message) => showCustomDialog(
  title: lw('Warning'),
  message: message,
  color: clWarning,
  icon: Icons.warning_amber_outlined,
);
void okSuccess(String message) => showCustomDialog(
  title: lw('Success'),
  message: message,
  color: clSuccess,
  icon: Icons.check_circle_outline,
);

Future<bool> showNetworkSafetyWarning({BuildContext? context}) async {
  final bool? acknowledged = await showFlatDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: clFill,
        shape: dialogShape,
        title: Row(
          children: [
            Icon(Icons.warning_amber_outlined, color: clWarning),
            const SizedBox(width: 8),
            Expanded(child: Text(lw('Network safety'), style: tsLarge)),
          ],
        ),
        content: Text(
          lw(
            'Transfers are unencrypted. Use EasySend only on private networks you trust, not on public or guest Wi-Fi.',
          ),
          style: tsNormal,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: dialogButtonStyle,
            child: Text(lw('I understand')),
          ),
        ],
      ),
    ),
  );
  return acknowledged ?? false;
}

// WCAG contrast between two colours, 1 for identical and 21 for black on white.
// Both must be opaque: computeLuminance() ignores alpha, so a translucent ink
// has to be flattened onto what it is drawn over first — Color.alphaBlend does
// that — or it measures as though it were fully opaque.
double contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

// Black or white, whichever actually contrasts better — compared by WCAG ratio
// rather than by a brightness threshold. Halfway-bright colours like amber are
// exactly where a threshold picks white and leaves the text barely there.
Color onColor(Color background) {
  return contrastRatio(background, Colors.black) >=
          contrastRatio(background, Colors.white)
      ? Colors.black
      : Colors.white;
}

// Core SnackBar function
void okInfoBar(
  String message, {
  Color? bgColor,
  Color? textColor,
  Duration? duration,
  DismissDirection dismissDirection = DismissDirection.down,
  SnackBarAction? action,
}) {
  final Color background = bgColor ?? clSnackInfo;
  scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      // Body size, not the small one: this is on screen for seconds and then
      // gone, so it has to be readable at a glance rather than studied.
      content: Text(
        message,
        style: TextStyle(
          fontSize: fsNormal,
          fontWeight: FontWeight.w500,
          color: textColor ?? onColor(background),
        ),
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: background,
      duration: duration ?? const Duration(seconds: 5),
      dismissDirection: dismissDirection,
      action: action,
    ),
  );
}

// SnackBar shortcuts, named after what they mean rather than the hue they used
// to be. The tones come from the Dark palette in every theme: a strip floating
// over the page is its own surface, not part of the one behind it.
void okInfoBarBlue(String message) => okInfoBar(
  message,
  bgColor: clSnackInfo,
  duration: const Duration(seconds: 6),
);
void okInfoBarRed(String message, {Duration? duration}) => okInfoBar(
  message,
  bgColor: clSnackError,
  duration: duration ?? const Duration(seconds: 7),
  dismissDirection: DismissDirection.none,
);
void okInfoBarOrange(String message) => okInfoBar(
  message,
  bgColor: clSnackWarning,
  duration: const Duration(seconds: 6),
);
void okInfoBarGreen(String message, {Duration? duration}) => okInfoBar(
  message,
  bgColor: clSnackSuccess,
  duration: duration ?? const Duration(seconds: 4),
);
void okInfoBarPurple(String message) => okInfoBar(
  message,
  bgColor: clSnackAccent,
  duration: const Duration(days: 3),
  dismissDirection: DismissDirection.none,
  action: SnackBarAction(
    label: '[ OK ]',
    // The action sits on the same strip, so it takes the same ink as the text.
    textColor: onColor(clSnackAccent),
    onPressed: () => scaffoldMessengerKey.currentState?.hideCurrentSnackBar(),
  ),
);

// Folder chooser. On desktop the system dialog is fine, but on Android
// file_picker goes through SAF: it asks to grant access to the tree, including
// future content, on every single pick, and hands back a content:// URI that
// Directory.list() cannot walk. We already hold all-files access, so a plain
// list of directories is both simpler and less intrusive.
Future<String?> pickFolder({String? initialPath}) async {
  if (!Platform.isAndroid) {
    return FilePicker.platform.getDirectoryPath();
  }

  // Grab the context before any await, so it cannot go stale meanwhile.
  final BuildContext? context = navigatorKey.currentContext;
  if (context == null) return null;

  const String root = androidRoot;
  String current = initialPath ?? root;
  // Checked synchronously: one stat() is cheap, and an await here would leave
  // the context behind an async gap.
  if (!Directory(current).existsSync()) current = root;

  return showFlatDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: clFill,
            shape: dialogShape,
            title: Row(
              children: [
                Expanded(child: Text(lw('Select folder'), style: tsLarge)),
                // Sorting the received files needs somewhere to put them, and
                // leaving the app for a file manager to make one is absurd.
                IconButton(
                  icon: Icon(Icons.create_new_folder_outlined, color: clText),
                  tooltip: lw('New folder'),
                  onPressed: () async {
                    final String? made = await _createFolder(current);
                    if (made != null) setState(() => current = made);
                  },
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(current, style: tsSmall),
                  const Divider(),
                  Flexible(
                    child: FutureBuilder<List<Directory>>(
                      future: _subDirectories(current),
                      builder: (context, snapshot) {
                        final List<Directory> dirs = snapshot.data ?? [];
                        final bool atRoot = current == root;
                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: dirs.length + (atRoot ? 0 : 1),
                          itemBuilder: (context, index) {
                            if (!atRoot && index == 0) {
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  Icons.arrow_upward,
                                  color: clText,
                                ),
                                title: Text('..', style: tsNormal),
                                onTap: () => setState(
                                  () => current = p.dirname(current),
                                ),
                              );
                            }
                            final Directory dir =
                                dirs[index - (atRoot ? 0 : 1)];
                            return ListTile(
                              dense: true,
                              leading: Icon(Icons.folder, color: clAccent),
                              title: Text(
                                p.basename(dir.path),
                                style: tsNormal,
                              ),
                              onTap: () => setState(() => current = dir.path),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: dialogCancelStyle,
                child: Text(lw('Cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, current),
                style: dialogButtonStyle,
                child: Text(lw('Select')),
              ),
            ],
          );
        },
      );
    },
  );
}

// Ask for a name and make the folder inside parent. Returns its full path, so
// the caller can step straight into it, or null when nothing was created.
Future<String?> _createFolder(String parent) async {
  final String? name = await showInputDialog(
    title: lw('New folder'),
    hint: lw('Folder name'),
  );
  if (name == null || name.isEmpty) return null;

  // A single plain name: the same rules the receiver applies to incoming
  // paths, plus no separators, so it cannot land outside the folder on screen.
  final String? safe = sanitizeRelPath(name);
  if (safe == null || safe.contains('/')) {
    okInfoBarRed(lw('Invalid folder name'));
    return null;
  }

  final String full = p.join(parent, safe);
  try {
    await Directory(full).create();
    return full;
  } catch (e) {
    myPrint('cannot create $full: $e');
    okInfoBarRed(lw('Cannot create the folder'));
    return null;
  }
}

// Readable subdirectories, dot-folders left out: they are never what someone
// means to send.
Future<List<Directory>> _subDirectories(String path) async {
  try {
    final List<Directory> dirs = await Directory(path)
        .list(followLinks: false)
        .where((e) => e is Directory && !p.basename(e.path).startsWith('.'))
        .cast<Directory>()
        .toList();
    dirs.sort(
      (a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
    return dirs;
  } catch (e) {
    myPrint('cannot list $path: $e');
    return [];
  }
}

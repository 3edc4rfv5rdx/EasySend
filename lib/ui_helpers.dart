import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';

import 'android_helpers.dart';
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
        'Folder unavailable, receiving is off',
      ),
      ReceiveReadinessFailure.port =>
        '${lw('Port is busy, receiving is off')}: $port',
      ReceiveReadinessFailure.transition => lw(
        'Setup did not finish, receiving may be off',
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

// Ask whether to accept an incoming transfer. Returns (accepted, trust, mode).
// Unanswered after acceptTimeoutSec the dialog closes itself and declines: the
// sender must not hang waiting for someone who is not at the screen. The
// receiver can also withdraw the question through `cancelled` — once its server
// is gone, no answer means anything any more.
//
// `occupied` is how many of the arriving names are already taken in the receive
// folder; zero leaves the dialog exactly as it has always been. `askTrust` is
// off for a sender that is trusted already: it is here for the names alone,
// and the trust question has been answered long ago.
Future<(bool, bool, ConflictMode)> showAcceptDialog({
  required String senderName,
  required int fileCount,
  required int totalBytes,
  int occupied = 0,
  bool askTrust = true,
  Future<void>? cancelled,
}) async {
  final BuildContext? context = navigatorKey.currentContext;
  if (context == null) return (false, false, ConflictMode.copies);

  bool trust = false;
  // What the app has always done, and what a question nobody answers comes
  // back with: copies side by side, and nothing of the user's is touched.
  ConflictMode mode = ConflictMode.copies;
  BuildContext? liveDialog;
  void close() {
    final BuildContext? ctx = liveDialog;
    if (ctx != null && ctx.mounted && Navigator.canPop(ctx)) {
      Navigator.pop(ctx, (false, false, ConflictMode.copies));
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
    final (bool, bool, ConflictMode)?
    result = await showFlatDialog<(bool, bool, ConflictMode)>(
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
                  if (occupied > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${lw('Such files are already here')}: $occupied',
                      style: tsNormal,
                    ),
                    // One under another rather than side by side: a translation
                    // of any of these is longer than a phone dialog is wide.
                    RadioGroup<ConflictMode>(
                      groupValue: mode,
                      onChanged: (ConflictMode? picked) =>
                          setState(() => mode = picked ?? mode),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final ConflictMode choice in ConflictMode.values)
                            RadioListTile<ConflictMode>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              visualDensity: const VisualDensity(vertical: -4),
                              controlAffinity: ListTileControlAffinity.leading,
                              value: choice,
                              activeColor: clAccent,
                              title: Text(
                                conflictModeLabel(choice),
                                style: tsSmall,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (askTrust) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: trust,
                      activeColor: clAccent,
                      checkColor: onColor(clAccent),
                      title: Text(
                        lw('Always trust this device'),
                        style: tsSmall,
                      ),
                      onChanged: (v) => setState(() => trust = v ?? false),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, (
                    false,
                    false,
                    ConflictMode.copies,
                  )),
                  style: dialogCancelStyle,
                  child: Text(lw('Decline')),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, (true, trust, mode)),
                  style: dialogButtonStyle,
                  child: Text(lw('Accept')),
                ),
              ],
            );
          },
        );
      },
    );
    return result ?? (false, false, ConflictMode.copies);
  } finally {
    timer.cancel();
  }
}

// What each answer about a taken name says on the button. All three describe
// what happens to the files that are here, not to the ones arriving: side by
// side, written over, left alone.
String conflictModeLabel(ConflictMode mode) => switch (mode) {
  ConflictMode.copies => lw('Add copies'),
  ConflictMode.replace => lw('Replace'),
  ConflictMode.keep => lw('Keep what is here'),
};

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
            Text('${lw('These cannot be sent')}:', style: tsNormal),
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

// A QR of the share address, drawn module by module. The matrix comes from the
// qr package — Reed-Solomon and mask selection are not something to write by
// hand — and the drawing is a hundred rectangles.
//
// Black on white whatever the theme is: a scanner reads contrast, and a dark
// palette that swapped these would be a picture no camera can follow. That is
// also why the quiet zone is inside the widget rather than left to whoever
// places it — four modules of white all round is part of the code, not padding.
class QrView extends StatelessWidget {
  final QrImage code;
  final double side;

  const QrView(this.code, {this.side = 220, super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: side,
    height: side,
    color: const Color(0xFFFFFFFF),
    child: CustomPaint(painter: _QrPainter(code)),
  );
}

class _QrPainter extends CustomPainter {
  static const int quietModules = 4;
  final QrImage code;

  const _QrPainter(this.code);

  @override
  void paint(Canvas canvas, Size size) {
    final int count = code.moduleCount;
    final double module = size.width / (count + quietModules * 2);
    final Paint dark = Paint()..color = const Color(0xFF000000);
    for (int row = 0; row < count; row++) {
      for (int col = 0; col < count; col++) {
        if (!code.isDark(row, col)) continue;
        // Half a pixel of overlap: at fractional module widths the seams
        // between neighbouring squares otherwise show as light hairlines, and
        // a scanner reads those as module boundaries that are not there.
        canvas.drawRect(
          Rect.fromLTWH(
            (col + quietModules) * module,
            (row + quietModules) * module,
            module + 0.5,
            module + 0.5,
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.code != code;
}

// The share address as a matrix, or null when it will not fit one — nothing
// this app puts in it ever comes close, but the answer is the caller's to make
// rather than an exception in the middle of a dialog.
QrImage? qrFor(String text) {
  try {
    return QrImage(QrCode(payload: QrPayload.fromString(text)));
  } catch (e) {
    myPrint('cannot build a QR of $text: $e');
    return null;
  }
}

// What a browser is offered while the share dialog stands open. Two answers
// rather than one: the device that needs a copy is not always the same
// architecture as the one handing it over, and a v7a build picked with File
// goes out exactly the same way this build does.
enum WebShareKind { program, files }

// The way a device with no EasySend on it gets one: this build serves itself
// over the receive server, and the other end types the address into a browser.
// The offer lives only as long as this dialog — closed, and the route is a 404
// again.
Future<void> showWebShareDialog(
  List<FileItem> selected, {
  bool zipWanted = false,
}) async {
  final List<WebShareEntry> files = [
    for (final FileItem file in selected)
      if (file.sourcePath != null)
        (name: file.relativePath, path: file.sourcePath!, size: file.size),
  ];
  WebShareEntry? program;
  final String? apkPath = await installedApkPath();
  if (apkPath != null) {
    final FileStat stat = await File(apkPath).stat();
    if (stat.type == FileSystemEntityType.file) {
      program = (
        // Named the way a release artifact is, so the other end can see which
        // build it is about to install without opening anything.
        name: 'EasySend-$progVersion+$buildNumber.apk',
        path: apkPath,
        size: stat.size,
      );
    }
  }
  if (program == null && files.isEmpty) {
    okInfo(lw('Nothing selected'));
    return;
  }

  // Nothing to share from: the routes live on the receive server, so a server
  // that is not listening has no address to give. The reason is the one the
  // banner already says — and a listener that is simply not up yet, with no
  // failure recorded, is the same 'setup did not finish' as any other.
  final int? port = receiveServer.boundPort;
  final ReceiveReadinessFailure? failure = receiveServer.readinessFailure;
  if (port == null || failure != null) {
    okErr(
      receiveBannerText(
        failure ?? ReceiveReadinessFailure.transition,
        port ?? currentPort,
      ),
    );
    return;
  }
  // Built once, not inside the builder: the dialog rebuilds whenever the choice
  // above changes, and a QR matrix is Reed-Solomon work rather than a colour.
  final List<({String url, QrImage? code})> targets = [];
  for (final String address in await localAddresses()) {
    final String url = webShareUrl(address, port);
    targets.add((url: url, code: qrFor(url)));
  }

  // Files win the default whenever there are any: picking them was a deliberate
  // act that just happened, and giving away the program is the rarer errand.
  WebShareKind kind = files.isNotEmpty
      ? WebShareKind.files
      : WebShareKind.program;
  void publish() {
    final List<WebShareEntry> entries = kind == WebShareKind.program
        ? [program!]
        : files;
    receiveServer.webOffer = entries.isEmpty ? null : entries;
  }

  publish();
  // The screen stays on for as long as this window does. Not a comfort: with
  // background receiving off, the screen going dark backgrounds the app and
  // takes the listener down with it, and the download on the other device dies
  // halfway. Off Android nobody asks, as everywhere else this lock is used.
  if (Platform.isAndroid) unawaited(screenWake.forWebShare(true));
  try {
    await showFlatDialog<void>(
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) => AlertDialog(
          backgroundColor: clFill,
          shape: dialogShape,
          // Wider than a stock dialog: the QR is the point of this one, and
          // 40 px of inset on each side of a phone is room the code could
          // be using instead.
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Row(
            children: [
              Icon(Icons.language, color: clAccent),
              const SizedBox(width: 8),
              Expanded(child: Text(lw('Share by link'), style: tsLarge)),
            ],
          ),
          // Scrolls: the QR is 220 px, and a desktop on two networks gets
          // two of them plus the choice above. Full width, or the dialog
          // would shrink to the widest line of text and waste the inset
          // just saved.
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // What is on offer, named before it is listed: without this
                  // line the choice below is two nouns with nothing to say what
                  // the dialog intends to do with them.
                  Text('${lw('Sharing')}:', style: tsNormal),
                  // With one thing to give there is nothing to choose, and a
                  // group of one radio button only asks a question the user
                  // cannot answer differently.
                  if (program != null && files.isNotEmpty)
                    RadioGroup<WebShareKind>(
                      groupValue: kind,
                      onChanged: (WebShareKind? picked) => setDialogState(() {
                        kind = picked ?? kind;
                        publish();
                      }),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Files first, because they are both the default and
                          // the everyday errand; handing over the program is
                          // the rare one and sits under it.
                          RadioListTile<WebShareKind>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            visualDensity: const VisualDensity(vertical: -4),
                            controlAffinity: ListTileControlAffinity.leading,
                            value: WebShareKind.files,
                            activeColor: clAccent,
                            title: Text(
                              '${lw('Selected files')}: ${files.length}',
                              style: tsNormal,
                            ),
                          ),
                          RadioListTile<WebShareKind>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            visualDensity: const VisualDensity(vertical: -4),
                            controlAffinity: ListTileControlAffinity.leading,
                            value: WebShareKind.program,
                            activeColor: clAccent,
                            // The build's own file name rather than a word for
                            // it: it says both what this is and which version
                            // the other device is about to be handed.
                            title: Text(program.name, style: tsNormal),
                          ),
                        ],
                      ),
                    )
                  else
                    Text(
                      kind == WebShareKind.program
                          ? program!.name
                          : '${lw('Selected files')}: ${files.length}',
                      style: tsNormal,
                    ),
                  const SizedBox(height: 12),
                  if (targets.isEmpty)
                    Text(lw('No address on this network'), style: tsNormal)
                  else ...[
                    Text(
                      lw('Scan this or type it on the other device'),
                      style: tsNormal,
                    ),
                    const SizedBox(height: 8),
                    // The code and the address it holds, one under the other:
                    // a camera reads the first, and a device whose camera does
                    // not read QR still has a browser and a keyboard. Two
                    // interfaces mean two of these rather than one code that
                    // may be for the network the other device is not on.
                    for (final ({String url, QrImage? code}) target in targets)
                      Center(
                        child: Column(
                          children: [
                            if (target.code != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: QrView(target.code!),
                              ),
                            // Selectable so a desktop can copy it into a chat
                            // instead of reading it out loud.
                            SelectableText(
                              target.url,
                              style: TextStyle(
                                fontSize: fsLarge,
                                fontWeight: fwBold,
                                color: clText,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  Text(lw('Works while this window is open'), style: tsNormal),
                ],
              ),
            ),
          ),
          // One row of my own rather than the stock action bar: that one
          // sizes each child to itself and stacks them the moment they do
          // not fit, which put the ZIP notice above the button instead of
          // beside it.
          actions: [
            SizedBox(
              width: double.maxFinite,
              child: Row(
                children: [
                  // The ZIP latch belongs to sending and is read nowhere
                  // near here. Said out loud rather than left to be
                  // noticed: the button stays lit across the whole screen,
                  // and a batch that goes out as separate files after it
                  // was pressed would look like a fault. Filled, because a
                  // coloured word on the dialog's own surface reads as
                  // decoration; two short lines keep it beside the button.
                  if (zipWanted)
                    Container(
                      constraints: const BoxConstraints(maxWidth: 170),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: clWarning,
                        borderRadius: BorderRadius.circular(btnRadius),
                      ),
                      // Black rather than onColor(): the ground here is
                      // the warning colour in every theme, and it is a
                      // light one, so the ink is not a question.
                      child: Text(
                        lw('ZIP does not apply here'),
                        style: const TextStyle(
                          fontSize: fsNormal,
                          color: Color(0xFF000000),
                        ),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    style: dialogButtonStyle,
                    // Close, not Ok: the button ends the sharing rather
                    // than agreeing to anything.
                    child: Text(lw('Close')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  } finally {
    // Every way out lands here: the button, the barrier and the system back
    // gesture. Nothing else in the app touches this field, so leaving it set
    // would keep the route alive for the rest of the run.
    receiveServer.webOffer = null;
    if (Platform.isAndroid) unawaited(screenWake.forWebShare(false));
  }
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
            'Traffic is not encrypted. Use EasySend only on a network you trust, not on public Wi-Fi.',
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
    return FilePicker.getDirectoryPath();
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

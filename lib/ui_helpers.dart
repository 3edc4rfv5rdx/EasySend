import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'globals.dart';

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
    pageBuilder: (BuildContext context, _, __) => builder(context),
  );
}

// Section heading: a 2 px rule with the name laid into it, the trailing button
// sitting in the line as well. A filled strip made every section shout; here
// the structure is the line and the only coloured area left is Send.
// trailingToEdge drops the closing stub of rule, so the trailing widget ends
// where the screen's 12 px margin does — that is how Clear lines up with the
// Folder button above it.
Widget sectionTitle(String text, {Widget? trailing, bool trailingToEdge = false}) {
  Widget rule([double? width]) {
    final Widget line = Container(height: 2, color: clFrame);
    return width == null ? Expanded(child: line) : SizedBox(width: width, child: line);
  }

  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          rule(16),
          const SizedBox(width: 8),
          // Its natural width, capped rather than made flexible: a Flexible
          // here would share the free space with the Expanded rule and get
          // half of it, shortening headings that fit perfectly well. The cap
          // only bites on a heading long enough to squeeze the rule out.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fsLarge, fontWeight: fwBold, color: clText),
            ),
          ),
          const SizedBox(width: 8),
          rule(),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing,
            if (!trailingToEdge) ...[
              const SizedBox(width: 10),
              rule(12),
            ],
          ],
        ],
      ),
    ),
  );
}

// The button that rides inside a section heading. One shape for all of them:
// a filled circle for one and a bare icon for the next read as two different
// kinds of thing when they are the same kind of thing.
Widget sectionButton(IconData icon, {required String tooltip, required VoidCallback onTap}) {
  return Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(btnRadius),
      child: Container(
        width: 34,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: clButton,
          border: Border.all(color: clFrame),
          borderRadius: BorderRadius.circular(btnRadius),
        ),
        child: Icon(icon, color: clText, size: 18),
      ),
    ),
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
// sender must not hang waiting for someone who is not at the screen.
Future<(bool, bool)> showAcceptDialog({
  required String senderName,
  required int fileCount,
  required int totalBytes,
}) async {
  final BuildContext? context = navigatorKey.currentContext;
  if (context == null) return (false, false);

  bool trust = false;
  Timer? timer;
  final (bool, bool)? result = await showFlatDialog<(bool, bool)>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) {
      timer = Timer(const Duration(seconds: acceptTimeoutSec), () {
        if (Navigator.canPop(dialogContext)) Navigator.pop(dialogContext, (false, false));
      });
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
                Text(senderName, style: TextStyle(fontSize: fsNormal, fontWeight: fwBold, color: clText)),
                const SizedBox(height: 4),
                Text('$fileCount — ${formatBytes(totalBytes)}', style: tsNormal),
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
  timer?.cancel();
  return result ?? (false, false);
}

// Single-field prompt, used for the device name, the port and manual IPs.
Future<String?> showInputDialog({
  required String title,
  String initial = '',
  TextInputType? keyboardType,
  String? hint,
}) async {
  final TextEditingController controller = TextEditingController(text: initial);
  final String? result = await showFlatDialog<String>(
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: clFill,
        shape: dialogShape,
        title: Text(title, style: tsLarge),
        content: TextField(
          controller: controller,
          keyboardType: keyboardType,
          autofocus: true,
          style: TextStyle(color: clText, fontSize: fsNormal),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: clFrame),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: clFrame)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: clAccent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: dialogCancelStyle,
            child: Text(lw('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: dialogButtonStyle,
            child: Text(lw('Ok')),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return result;
}

void okInfo(String message) => showCustomDialog(title: lw('Info'), message: message, color: clInfo, icon: Icons.info_outline);
void okErr(String message) => showCustomDialog(title: lw('Error'), message: message, color: clError, icon: Icons.error_outline);
void okWarning(String message) => showCustomDialog(title: lw('Warning'), message: message, color: clWarning, icon: Icons.warning_amber_outlined);
void okSuccess(String message) => showCustomDialog(title: lw('Success'), message: message, color: clSuccess, icon: Icons.check_circle_outline);

// Black or white, whichever actually contrasts better — compared by WCAG ratio
// rather than by a brightness threshold. Halfway-bright colours like amber are
// exactly where a threshold picks white and leaves the text barely there.
Color onColor(Color background) {
  final double l = background.computeLuminance();
  final double onWhite = 1.05 / (l + 0.05);
  final double onBlack = (l + 0.05) / 0.05;
  return onBlack >= onWhite ? Colors.black : Colors.white;
}

// Core SnackBar function
void okInfoBar(String message, {
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
void okInfoBarBlue(String message) => okInfoBar(message, bgColor: clSnackInfo, duration: const Duration(seconds: 6));
void okInfoBarRed(String message, {Duration? duration}) => okInfoBar(message, bgColor: clSnackError, duration: duration ?? const Duration(seconds: 7), dismissDirection: DismissDirection.none);
void okInfoBarOrange(String message) => okInfoBar(message, bgColor: clSnackWarning, duration: const Duration(seconds: 6));
void okInfoBarGreen(String message, {Duration? duration}) => okInfoBar(message, bgColor: clSnackSuccess, duration: duration ?? const Duration(seconds: 4));
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

  const String root = '/storage/emulated/0';
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
                                leading: Icon(Icons.arrow_upward, color: clText),
                                title: Text('..', style: tsNormal),
                                onTap: () => setState(
                                  () => current = p.dirname(current),
                                ),
                              );
                            }
                            final Directory dir = dirs[index - (atRoot ? 0 : 1)];
                            return ListTile(
                              dense: true,
                              leading: Icon(Icons.folder, color: clAccent),
                              title: Text(p.basename(dir.path), style: tsNormal),
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
    dirs.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
    return dirs;
  } catch (e) {
    myPrint('cannot list $path: $e');
    return [];
  }
}

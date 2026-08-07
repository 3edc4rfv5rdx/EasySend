import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'globals.dart';

// Shared look for dialog action buttons, so every dialog stays identical.
ButtonStyle get dialogButtonStyle => TextButton.styleFrom(
  // Same reason as the frame: appBar sits too close to the dialog surface on
  // a dark theme.
  backgroundColor: xvDarkNow ? clFrame : clUpBar,
  foregroundColor: clText,
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  elevation: 4,
  minimumSize: const Size(60, 40),
);

RoundedRectangleBorder get dialogShape => RoundedRectangleBorder(
  // On a dark theme the appBar colour is too close to the dialog surface, so
  // the lighter frame colour is used instead.
  side: BorderSide(color: xvDarkNow ? clFrame : clUpBar, width: 3.0),
  borderRadius: BorderRadius.circular(8.0),
);

Future<bool> okConfirm({
  required String title,
  required String message,
  String? yesText,
  String? noText,
}) async {
  final result = await showDialog<bool>(
    context: navigatorKey.currentContext!,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title, style: tsLarge),
        content: Text(message, style: tsNormal),
        backgroundColor: clFill,
        shape: dialogShape,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: dialogButtonStyle,
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
  showDialog(
    context: navigatorKey.currentContext!,
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
  final (bool, bool)? result = await showDialog<(bool, bool)>(
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
                Icon(Icons.download_outlined, color: clUpBar),
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
                  activeColor: clUpBar,
                  checkColor: clText,
                  title: Text(lw('Always trust this device'), style: tsSmall),
                  onChanged: (v) => setState(() => trust = v ?? false),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, (false, false)),
                style: dialogButtonStyle,
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
  final String? result = await showDialog<String>(
    context: navigatorKey.currentContext!,
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
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: clUpBar)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: dialogButtonStyle,
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

void okInfo(String message) => showCustomDialog(title: lw('Info'), message: message, color: Colors.blue, icon: Icons.info_outline);
void okErr(String message) => showCustomDialog(title: lw('Error'), message: message, color: Colors.red, icon: Icons.error_outline);
void okWarning(String message) => showCustomDialog(title: lw('Warning'), message: message, color: Colors.orange, icon: Icons.warning_amber_outlined);
void okSuccess(String message) => showCustomDialog(title: lw('Success'), message: message, color: Colors.green, icon: Icons.check_circle_outline);

// Core SnackBar function
void okInfoBar(String message, {
  Color bgColor = Colors.blue,
  Color? textColor,
  Duration? duration,
  DismissDirection dismissDirection = DismissDirection.down,
  SnackBarAction? action,
}) {
  scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(message, style: TextStyle(fontSize: fsSmall, color: textColor ?? clText)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: bgColor,
      duration: duration ?? const Duration(seconds: 4),
      dismissDirection: dismissDirection,
      action: action,
    ),
  );
}

// Colored SnackBar shortcuts
void okInfoBarBlue(String message) => okInfoBar(message, bgColor: Colors.blue, textColor: Colors.white, duration: const Duration(seconds: 5));
void okInfoBarRed(String message, {Duration? duration}) => okInfoBar(message, bgColor: Colors.red, textColor: Colors.white, duration: duration ?? const Duration(seconds: 7), dismissDirection: DismissDirection.none);
void okInfoBarOrange(String message) => okInfoBar(message, bgColor: Colors.orange);
void okInfoBarGreen(String message, {Duration? duration}) => okInfoBar(message, bgColor: Colors.green, duration: duration ?? const Duration(seconds: 3));
void okInfoBarPurple(String message) => okInfoBar(
  message,
  bgColor: Colors.purple,
  textColor: Colors.white,
  duration: const Duration(days: 3),
  dismissDirection: DismissDirection.none,
  action: SnackBarAction(
    label: '[ OK ]',
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

  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: clFill,
            shape: dialogShape,
            title: Text(lw('Select folder'), style: tsLarge),
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
                              leading: Icon(Icons.folder, color: clUpBar),
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
                style: dialogButtonStyle,
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

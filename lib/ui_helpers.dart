import 'dart:async';

import 'package:flutter/material.dart';

import 'globals.dart';

// Shared look for dialog action buttons, so every dialog stays identical.
ButtonStyle get dialogButtonStyle => TextButton.styleFrom(
  backgroundColor: clUpBar,
  foregroundColor: clText,
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  elevation: 4,
  minimumSize: const Size(60, 40),
);

RoundedRectangleBorder get dialogShape => RoundedRectangleBorder(
  side: BorderSide(color: clUpBar, width: 3.0),
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
        backgroundColor: clFon,
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
        backgroundColor: clFon,
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
            backgroundColor: clFon,
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
        backgroundColor: clFon,
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

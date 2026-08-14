import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android declares separate idle and transfer foreground types',
    () async {
      final String manifest = await File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsString();
      final String service = await File(
        'android/app/src/main/kotlin/a/a/easysend/TransferService.kt',
      ).readAsString();

      expect(manifest, contains('FOREGROUND_SERVICE_DATA_SYNC'));
      expect(manifest, contains('FOREGROUND_SERVICE_SPECIAL_USE'));
      expect(manifest, contains('dataSync|specialUse'));
      expect(manifest, contains('PROPERTY_SPECIAL_USE_FGS_SUBTYPE'));
      expect(service, contains('FOREGROUND_SERVICE_TYPE_DATA_SYNC'));
      expect(service, contains('FOREGROUND_SERVICE_TYPE_SPECIAL_USE'));
    },
  );

  // startForeground() is allowed to refuse — from Android 12 when the app may
  // no longer hold a foreground service, from Android 15 when the dataSync
  // budget is spent. It throws on the main thread inside onStartCommand, where
  // an unguarded call ends the process together with the transfer, the receive
  // server and discovery, which SPEC 7 says must not happen.
  test('a refused foreground start gives the service up, not the process', () async {
    final String service = await File(
      'android/app/src/main/kotlin/a/a/easysend/TransferService.kt',
    ).readAsString();
    final RegExp guarded = RegExp(
      r'private fun startForegroundOrGiveUp[\s\S]*?\n    \}\n',
    );
    final String body = guarded.firstMatch(service)!.group(0)!;

    // Refused, it does exactly what a platform timeout does.
    expect(body, contains('catch'));
    expect(body, contains('releaseLocks()'));
    expect(body, contains('stopForeground(STOP_FOREGROUND_REMOVE)'));
    expect(body, contains('reportServiceTimeout(type)'));
    expect(body, contains('stopSelf()'));
    // And there is nowhere else to start from: one guarded door, or the guard
    // is worth nothing. Counted over the code alone — the prose above says
    // "startForeground()" too.
    String code(String source) => source
        .split('\n')
        .where((String line) {
          final String trimmed = line.trimLeft();
          return !trimmed.startsWith('*') &&
              !trimmed.startsWith('//') &&
              !trimmed.startsWith('/*');
        })
        .join('\n');
    expect(
      'startForeground('.allMatches(code(service)).length,
      'startForeground('.allMatches(code(body)).length,
    );
  });

  test('a platform timeout releases resources and stops the service', () async {
    final String service = await File(
      'android/app/src/main/kotlin/a/a/easysend/TransferService.kt',
    ).readAsString();
    final RegExp timeout = RegExp(r'override fun onTimeout[\s\S]*?\n    \}');
    final String body = timeout.firstMatch(service)!.group(0)!;

    expect(body, contains('releaseLocks()'));
    expect(body, contains('stopForeground(STOP_FOREGROUND_REMOVE)'));
    expect(body, contains('reportServiceTimeout(fgsType)'));
    expect(body, contains('stopSelf()'));
  });
}

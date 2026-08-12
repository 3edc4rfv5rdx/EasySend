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

import 'package:easysend/android_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('service listener attachment is idempotent', () {
    final service = AndroidService();
    expect(service.attached, isFalse);
    service.attach();
    service.attach();
    expect(service.attached, isTrue);
    service.detach();
    service.detach();
    expect(service.attached, isFalse);
  });
}

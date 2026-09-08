import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// A file as the receiving end holds it once the transfer is over: done or not,
// and with the path it was actually written to, or none.
FileItem arrived(String name, {String? at, bool done = true}) => FileItem(
  id: name,
  relativePath: name,
  size: 1,
  destinationPath: at,
)..done = done;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('easysend/service');
  final List<MethodCall> invocations = [];

  setUp(() {
    invocations.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          invocations.add(call);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('receivedMediaPaths', () {
    test('takes pictures and videos, by where they landed', () {
      expect(
        receivedMediaPaths([
          arrived('photo.JPG', at: '/recv/photo.JPG'),
          arrived('clip.mp4', at: '/recv/clip.mp4'),
          arrived('notes.pdf', at: '/recv/notes.pdf'),
          arrived('app.apk', at: '/recv/app.apk'),
        ]),
        ['/recv/photo.JPG', '/recv/clip.mp4'],
      );
    });

    test('skips a file that was never written here', () {
      expect(
        receivedMediaPaths([
          // Kept because the name was taken: the user's own file, not ours.
          arrived('photo.jpg'),
          // Never arrived at all.
          arrived('other.jpg', at: '/recv/other.jpg', done: false),
        ]),
        isEmpty,
      );
    });
  });

  group('scanReceivedMedia', () {
    test('hands the paths over when the setting is on', () async {
      xdef['Show in the gallery'] = 'true';
      await scanReceivedMedia([
        arrived('photo.jpg', at: '/recv/photo.jpg'),
      ], android: true);

      expect(invocations.single.method, 'scanMedia');
      expect(invocations.single.arguments, {
        'paths': ['/recv/photo.jpg'],
      });
    });

    test('says nothing with the setting off', () async {
      xdef['Show in the gallery'] = 'false';
      await scanReceivedMedia([
        arrived('photo.jpg', at: '/recv/photo.jpg'),
      ], android: true);

      expect(invocations, isEmpty);
    });

    test('says nothing off Android', () async {
      xdef['Show in the gallery'] = 'true';
      await scanReceivedMedia([
        arrived('photo.jpg', at: '/recv/photo.jpg'),
      ], android: false);

      expect(invocations, isEmpty);
    });

    test('says nothing when nothing a gallery shows arrived', () async {
      xdef['Show in the gallery'] = 'true';
      await scanReceivedMedia([
        arrived('notes.pdf', at: '/recv/notes.pdf'),
      ], android: true);

      expect(invocations, isEmpty);
    });

    test('the Kotlin side answers that same name with a media scan', () async {
      final String application = await File(
        'android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt',
      ).readAsString();

      expect(application, contains('"scanMedia" ->'));
      // The files stay where they are; only the index is told about them.
      expect(application, contains('MediaScannerConnection.scanFile'));
    });

    test('a platform failure is swallowed', () async {
      xdef['Show in the gallery'] = 'true';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(code: 'easysend');
          });

      await expectLater(
        scanReceivedMedia([
          arrived('photo.jpg', at: '/recv/photo.jpg'),
        ], android: true),
        completes,
      );
    });
  });
}

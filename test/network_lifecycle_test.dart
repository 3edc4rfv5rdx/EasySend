import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/home_screen.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('receive server restarts', () {
    late Directory sandbox;
    late ReceiveServer server;
    late HttpClient client;
    late int port;

    Uri url(String route, [Map<String, String>? query]) =>
        Uri.http('127.0.0.1:$port', '$apiPrefix/$route', query);

    Future<int> post(
      String route, {
      Map<String, String>? query,
      Object? body,
    }) async {
      final HttpClientRequest req = await client.postUrl(url(route, query));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(json.encode(body));
      } else {
        req.contentLength = 0;
      }
      final HttpClientResponse resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode;
    }

    Future<Map<String, dynamic>> prepare(String path, int size) async {
      final HttpClientRequest req = await client.postUrl(url('prepare'));
      req.headers.contentType = ContentType.json;
      req.write(
        json.encode({
          'senderId': 'trusted-sender',
          'senderName': 'Sender',
          'files': [
            {'id': 'file-1', 'path': path, 'size': size},
          ],
        }),
      );
      final HttpClientResponse resp = await req.close();
      final String text = await utf8.decoder.bind(resp).join();
      return (json.decode(text) as Map).cast<String, dynamic>();
    }

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-lifecycle-');
      xvConfigDir = p.join(sandbox.path, 'config');
      xvRecvDir = p.join(sandbox.path, 'receive');
      xvDeviceId = 'receiver';
      xvDeviceName = 'Receiver';
      xvPlatform = 'linux';
      xvTransfers = [];
      xvDevices = [Device(id: 'trusted-sender', name: 'Sender', trusted: true)];
      client = HttpClient();
      // Bind on a free port first, then pin the settings to it: the guard being
      // tested compares the bound port with the configured one.
      xdef['Port'] = '0';
      server = ReceiveServer();
      expect(await server.start(), isTrue);
      port = server.boundPort!;
      xdef['Port'] = '$port';
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      xdef['Port'] = '$defaultPort';
      await sandbox.delete(recursive: true);
    });

    test('starting again on the same port keeps the session alive', () async {
      final Map<String, dynamic> prepared = await prepare('kept.bin', 2);
      final String session = prepared['sessionId'] as String;

      // What returning to the foreground does on every resume.
      expect(await server.start(), isTrue);
      expect(server.boundPort, port);

      final HttpClientRequest upload = await client.postUrl(
        url('upload', {'session': session, 'file': 'file-1'}),
      );
      upload.contentLength = 2;
      upload.add([1, 2]);
      final HttpClientResponse uploaded = await upload.close();
      await uploaded.drain<void>();
      expect(uploaded.statusCode, 200);

      final String crc = getCrc32([1, 2]).toRadixString(16);
      expect(
        await post(
          'verify',
          query: {'session': session, 'file': 'file-1', 'crc': crc},
        ),
        200,
      );
      expect(await post('finish', query: {'session': session}), 200);
      expect(await File(p.join(xvRecvDir, 'kept.bin')).exists(), isTrue);
      expect(xvTransfers.single.status, TransferStatus.done);
    });

    test('a changed port still rebinds', () async {
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int free = probe.port;
      await probe.close();

      xdef['Port'] = '$free';
      expect(await server.start(), isTrue);
      expect(server.boundPort, free);
      expect(server.boundPort, isNot(port));
    });
  });

  group('lifecycle decides the network state', () {
    test('inactive is never an answer', () {
      for (final bool background in [false, true]) {
        expect(
          networkDesiredFor(
            AppLifecycleState.inactive,
            receiveInBackground: background,
          ),
          isNull,
        );
      }
    });

    test('background receiving keeps the network up in every state', () {
      for (final AppLifecycleState state in [
        AppLifecycleState.resumed,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
        AppLifecycleState.hidden,
      ]) {
        expect(
          networkDesiredFor(state, receiveInBackground: true),
          isTrue,
          reason: '$state',
        );
      }
    });

    test('without it, only a visible app announces itself', () {
      expect(
        networkDesiredFor(
          AppLifecycleState.resumed,
          receiveInBackground: false,
        ),
        isTrue,
      );
      for (final AppLifecycleState state in [
        AppLifecycleState.paused,
        AppLifecycleState.detached,
        AppLifecycleState.hidden,
      ]) {
        expect(
          networkDesiredFor(state, receiveInBackground: false),
          isFalse,
          reason: '$state',
        );
      }
    });
  });

  test('receiver advertisement follows readiness exactly', () async {
    int starts = 0;
    int stops = 0;

    expect(
      await updateReceiverAdvertisement(
        receiverReady: false,
        startAdvertisement: () async {
          starts++;
          return true;
        },
        stopAdvertisement: () async => stops++,
      ),
      isFalse,
    );
    expect(starts, 0);
    expect(stops, 1);

    expect(
      await updateReceiverAdvertisement(
        receiverReady: true,
        startAdvertisement: () async {
          starts++;
          return true;
        },
        stopAdvertisement: () async => stops++,
      ),
      isTrue,
    );
    expect(starts, 1);
    expect(stops, 1);
  });

  test(
    'network transition queue continues after a failed transition',
    () async {
      final SerialQueue queue = SerialQueue('network transition');
      final List<String> transitions = [];
      final Completer<void> firstStarted = Completer<void>();
      final Completer<void> releaseFirst = Completer<void>();

      final Future<void> failed = queue.add(() async {
        transitions.add('failed start');
        firstStarted.complete();
        await releaseFirst.future;
        throw StateError('permission channel disappeared');
      });
      await firstStarted.future;

      final Future<void> latest = queue.add(() async {
        transitions.add('latest state');
      });
      expect(transitions, ['failed start']);

      releaseFirst.complete();
      await Future.wait([failed, latest]);
      expect(transitions, ['failed start', 'latest state']);
    },
  );
}

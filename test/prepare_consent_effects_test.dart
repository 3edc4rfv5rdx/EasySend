import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// What a prepare is allowed to change about the device list, and when. Every
// line of it outlives the request — the address and port are persisted, and the
// manual flag keeps an entry in the list for good and has it polled — so a
// transfer the user refused has to leave the list exactly as it found it.
//
// The rule itself is tested apart from the server: a request over loopback can
// never teach an address, because a loopback source is this machine talking to
// itself and dialling it back would reach us.
void main() {
  // A device discovered a while ago and gone quiet since: in the list, not
  // manual, and past its announce timeout. This is the ordinary state of a
  // laptop that was closed, and the one the promotion rule looks at.
  Device silentPeer() => Device(
    id: 'peer',
    name: 'Peer',
    address: '10.0.0.9',
    port: defaultPort,
    lastSeen: DateTime.now().subtract(
      const Duration(seconds: deviceTimeoutSec + 5),
    ),
  );

  group('what the connection teaches about a sender', () {
    test('a device announces nothing, so only a poll will find it again', () {
      final Device peer = silentPeer();

      learnSenderAddress(
        peer,
        address: '192.168.5.5',
        port: 4242,
        wasOnline: false,
      );

      expect(peer.address, '192.168.5.5');
      expect(peer.port, 4242);
      expect(peer.manual, isTrue);
      expect(peer.online, isTrue);
    });

    test('a device discovery still reaches is left alone', () {
      final Device peer = silentPeer();

      learnSenderAddress(
        peer,
        address: '192.168.5.5',
        port: 4242,
        wasOnline: true,
      );

      expect(peer.manual, isFalse, reason: 'announces are reaching it already');
      expect(peer.address, '192.168.5.5');
      expect(peer.port, 4242);
    });

    test('a loopback source teaches nothing but the time', () {
      final Device peer = silentPeer();

      learnSenderAddress(
        peer,
        address: '127.0.0.1',
        port: 4242,
        wasOnline: false,
      );

      expect(peer.address, '10.0.0.9', reason: 'that address reaches us, not it');
      expect(peer.port, defaultPort);
      expect(peer.manual, isFalse);
      expect(peer.online, isTrue);
    });
  });

  group('a refusal leaves no trace', () {
    late Directory sandbox;
    late ReceiveServer server;
    late HttpClient client;
    late int port;

    Uri url(String route) => Uri.http('127.0.0.1:$port', '$apiPrefix/$route');

    Future<int> prepare(String senderId) async {
      final HttpClientRequest req = await client.postUrl(url('prepare'));
      req.headers.contentType = ContentType.json;
      req.write(
        json.encode({
          'senderId': senderId,
          'senderName': 'Sender',
          'senderPort': 4242,
          'files': [
            {'id': 'f1', 'path': 'one.bin', 'size': 1},
          ],
        }),
      );
      final HttpClientResponse resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode;
    }

    void answerWith(bool accepted, {bool trust = false}) {
      server.askUser =
          ({
            required String senderName,
            required int fileCount,
            required int totalBytes,
          }) async => (accepted, trust);
    }

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-consent-');
      xvConfigDir = p.join(sandbox.path, 'config');
      xvRecvDir = p.join(sandbox.path, 'receive');
      xvDeviceId = 'receiver';
      xvDeviceName = 'Receiver';
      xvPlatform = 'linux';
      xvTransfers = [];
      xvDevices = [];
      client = HttpClient();
      xdef['Port'] = '0';
      server = ReceiveServer();
      expect(await server.start(), isTrue);
      port = server.boundPort!;
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      xdef['Port'] = '$defaultPort';
      await sandbox.delete(recursive: true);
    });

    // The stamp stands in for the whole of it: address, port, the manual flag
    // and lastSeen are written by one call, so a lastSeen the refusal did not
    // touch is proof that call never happened.
    test('a declined prepare changes nothing about the device', () async {
      final Device peer = silentPeer();
      final DateTime? seenBefore = peer.lastSeen;
      xvDevices = [peer];
      answerWith(false);

      expect(await prepare('peer'), HttpStatus.forbidden);

      expect(peer.manual, isFalse, reason: 'a refusal must not pin it in place');
      expect(peer.lastSeen, seenBefore, reason: 'nor make it look reachable');
      expect(peer.online, isFalse);
      expect(peer.trusted, isFalse);
      expect(peer.address, '10.0.0.9');
      expect(peer.port, defaultPort);
    });

    test('a declined prepare writes nothing to disk', () async {
      xvDevices = [silentPeer()];
      answerWith(false);

      expect(await prepare('peer'), HttpStatus.forbidden);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        await File(p.join(xvConfigDir, settFile)).exists(),
        isFalse,
        reason: 'a refused transfer is not a reason to persist anything',
      );
    });

    test('declining an unknown sender remembers nothing', () async {
      answerWith(false, trust: true);

      expect(await prepare('stranger'), HttpStatus.forbidden);

      expect(xvDevices, isEmpty);
    });

    test('an accepted prepare stamps the device as seen', () async {
      final Device peer = silentPeer();
      xvDevices = [peer];
      answerWith(true);

      expect(await prepare('peer'), HttpStatus.ok);

      expect(peer.online, isTrue);
      // Accepting once is not trusting: the question is asked again next time.
      expect(peer.trusted, isFalse);
    });

    test('accepting with trust remembers a known sender', () async {
      final Device peer = silentPeer();
      xvDevices = [peer];
      answerWith(true, trust: true);

      expect(await prepare('peer'), HttpStatus.ok);

      expect(peer.trusted, isTrue);
      expect(xvDevices.single, same(peer));
    });

    test('accepting with trust remembers an unknown sender', () async {
      answerWith(true, trust: true);

      expect(await prepare('stranger'), HttpStatus.ok);

      final Device added = xvDevices.single;
      expect(added.id, 'stranger');
      expect(added.trusted, isTrue);
    });

    test('a trusted sender is stamped without being asked', () async {
      final Device peer = silentPeer()..trusted = true;
      xvDevices = [peer];
      // No askUser hook at all: a trusted sender must never reach the question.
      expect(await prepare('peer'), HttpStatus.ok);

      expect(peer.online, isTrue);
    });
  });
}

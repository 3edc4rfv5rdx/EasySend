import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';

// The routes a plain browser reaches: the way a device that has no EasySend on
// it gets one. They answer only while the share dialog holds an offer, and they
// are the only place in the server where a request is not another copy of the
// app talking the transfer protocol.
void main() {
  late Directory sandbox;
  late ReceiveServer server;
  late HttpClient client;
  late int port;

  Future<HttpClientResponse> get(String route) async {
    final HttpClientRequest req = await client.getUrl(
      Uri.http('127.0.0.1:$port', route),
    );
    return req.close();
  }

  WebShareEntry entryFor(String name, List<int> bytes) {
    final File file = File(p.join(sandbox.path, p.basename(name)));
    file.writeAsBytesSync(bytes);
    return (name: name, path: file.path, size: bytes.length);
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-share-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xdef['Port'] = '0';
    client = HttpClient();
    server = ReceiveServer();
    expect(await server.start(), isTrue);
    port = server.boundPort!;
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await sandbox.delete(recursive: true);
  });

  test('with no dialog open there is no such route', () async {
    expect((await get(webShareIndexPath)).statusCode, HttpStatus.notFound);
    expect((await get('/0')).statusCode, HttpStatus.notFound);
  });

  test('the index lists exactly what is on offer', () async {
    server.webOffer = [
      entryFor('one.txt', [1, 2, 3]),
      entryFor('two.apk', [4]),
    ];
    final HttpClientResponse resp = await get(webShareIndexPath);
    expect(resp.statusCode, HttpStatus.ok);
    expect(resp.headers.contentType?.mimeType, 'text/html');
    final String body = await utf8.decoder.bind(resp).join();
    expect(body, contains('href="/0"'));
    expect(body, contains('one.txt'));
    expect(body, contains('href="/1"'));
    expect(body, contains('two.apk'));
    expect(body, isNot(contains('href="/2"')));
  });

  test('the offer goes away with the dialog', () async {
    server.webOffer = [
      entryFor('one.txt', [1]),
    ];
    expect((await get(webShareIndexPath)).statusCode, HttpStatus.ok);
    server.webOffer = null;
    expect((await get(webShareIndexPath)).statusCode, HttpStatus.notFound);
    expect((await get('/0')).statusCode, HttpStatus.notFound);
  });

  test('a file goes out whole, named and sized', () async {
    final List<int> bytes = List<int>.generate(5000, (int i) => i % 256);
    server.webOffer = [entryFor('gift.bin', bytes)];
    final HttpClientResponse resp = await get('/0');
    expect(resp.statusCode, HttpStatus.ok);
    expect(resp.contentLength, bytes.length);
    expect(
      resp.headers.value('content-disposition'),
      contains('filename="gift.bin"'),
    );
    final List<int> received = await resp.fold<List<int>>(
      <int>[],
      (List<int> all, List<int> chunk) => all..addAll(chunk),
    );
    expect(received, bytes);
  });

  // An .apk has to arrive as the type Android's installer is registered for,
  // or the finished download is a file the phone has no idea what to do with.
  test('an apk is announced as a package, anything else as bytes', () async {
    server.webOffer = [
      entryFor('build.apk', [1]),
      entryFor('notes.txt', [2]),
    ];
    final HttpClientResponse apk = await get('/0');
    expect(
      apk.headers.contentType?.mimeType,
      'application/vnd.android.package-archive',
    );
    await apk.drain<void>();
    final HttpClientResponse text = await get('/1');
    expect(text.headers.contentType?.mimeType, 'application/octet-stream');
    await text.drain<void>();
  });

  // A Russian name cannot travel in the plain filename parameter, and a browser
  // that got only that would save the route number instead.
  test('a name outside ASCII travels in the encoded form', () async {
    server.webOffer = [
      entryFor('снимок.jpg', [1]),
    ];
    final HttpClientResponse resp = await get('/0');
    final String? disposition = resp.headers.value('content-disposition');
    expect(disposition, contains("filename*=UTF-8''"));
    expect(disposition, contains(Uri.encodeComponent('снимок.jpg')));
    await resp.drain<void>();
  });

  test('anything but an index in range is not a route', () async {
    server.webOffer = [
      entryFor('one.txt', [1]),
    ];
    expect((await get('/1')).statusCode, HttpStatus.notFound);
    expect((await get('/-1')).statusCode, HttpStatus.notFound);
    expect((await get('/x')).statusCode, HttpStatus.notFound);
    expect((await get('/0/0')).statusCode, HttpStatus.notFound);
    expect((await get('/favicon.ico')).statusCode, HttpStatus.notFound);
  });

  // The share routes sit at the root now, one 'GET' above the protocol's own.
  // A protocol route must still be answered by the protocol, and a mistyped one
  // must not become a file.
  test('the transfer protocol keeps its own routes', () async {
    server.webOffer = [
      entryFor('one.txt', [1]),
    ];
    final HttpClientResponse info = await get('$apiPrefix/info');
    expect(info.statusCode, HttpStatus.ok);
    expect(info.headers.contentType?.mimeType, 'application/json');
    await info.drain<void>();
    expect((await get('$apiPrefix/prepare')).statusCode, HttpStatus.notFound);
  });

  // The single receive slot belongs to transfers between two copies of the app.
  // A browser pulling a file holds nothing: an ordinary transfer must be able
  // to start while the other device is still downloading.
  test('a browser download takes no receive slot', () async {
    final List<int> bytes = List<int>.generate(200000, (int i) => i % 256);
    server.webOffer = [entryFor('big.bin', bytes)];
    final HttpClientResponse resp = await get('/0');
    // Headers are here, the body is not: this is the middle of the download.
    expect(server.receiveSlotHeld, isFalse);
    await resp.drain<void>();
    expect(server.receiveSlotHeld, isFalse);
  });

  // Without the scheme a browser treats it as something to search for, and the
  // person holding the other phone gets a search page instead of the file.
  test('the address is shown as a whole URL', () {
    expect(webShareUrl('192.168.88.7', 15353), 'http://192.168.88.7:15353');
  });

  // The address is also shown as a QR, and a matrix that failed to build would
  // be swallowed by the dialog as a missing picture rather than an error.
  test('the address becomes a QR of a workable size', () {
    final QrImage? code = qrFor(webShareUrl('192.168.88.7', 15353));
    expect(code, isNotNull);
    // Every QR version is 21 modules plus a multiple of four, and an address
    // this short must not need a big one: the bigger the version, the finer
    // the modules a camera has to resolve off a phone screen.
    expect((code!.moduleCount - 21) % 4, 0);
    expect(code.moduleCount, lessThanOrEqualTo(33));
  });

  test('a name is escaped rather than laid into the page as markup', () {
    final String html = webShareIndexHtml([
      (name: 'a<b>&c.txt', path: '/tmp/x', size: 1),
    ]);
    expect(html, contains('a&lt;b&gt;&amp;c.txt'));
    expect(html, isNot(contains('<b>')));
  });
}

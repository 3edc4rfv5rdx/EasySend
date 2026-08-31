import 'package:easysend/globals.dart';
import 'package:easysend/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FileItem file(String path) => FileItem(id: path, relativePath: path, size: 1);

void main() {
  test('an ordinary transfer says which way it went', () {
    expect(
      transferRowIcon(incoming: true, files: [file('photo.jpg')]),
      Icons.download,
    );
    expect(
      transferRowIcon(incoming: false, files: [file('photo.jpg')]),
      Icons.upload,
    );
  });

  test('a clipboard says so without giving up the direction', () {
    final List<FileItem> clip = [file('clipboard/x.20260831-143007.txt')];
    expect(transferRowIcon(incoming: true, files: clip), Icons.content_paste);
    expect(
      transferRowIcon(incoming: false, files: clip),
      Icons.content_paste_go,
    );
  });

  test('a batch that merely carries one is a batch of files', () {
    expect(
      transferRowIcon(
        incoming: true,
        files: [file('clipboard/x.20260831-143007.txt'), file('photo.jpg')],
      ),
      Icons.download,
    );
  });

  test('a transfer with no files is not a clipboard', () {
    expect(transferRowIcon(incoming: true, files: const []), Icons.download);
  });
}

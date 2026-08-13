import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// WCAG AA: 4.5:1 for text, 3:1 for a control or an icon carrying meaning.
// Muted text is body text that has been quietened, not decoration, so it is
// held to the text figure wherever it is read.
const double minTextContrast = 4.5;

// The two surfaces a device row is drawn on: the page, and the tint a selected
// row gets under it.
Color get _selectedSurface => Color.alphaBlend(clSel, clFon);

void main() {
  setUpAll(() async {
    final Map<String, dynamic> data =
        jsonDecode(await File(colorsFile).readAsString())
            as Map<String, dynamic>;
    loadedThemes = data.map(
      (String name, dynamic palette) =>
          MapEntry(name, Map<String, String>.from(palette as Map)),
    );
  });

  test('every palette in colors.json is loaded for these checks', () {
    // A palette added to the file but skipped here would be unmeasured, and
    // this suite is the only thing standing between it and an unreadable row.
    expect(loadedThemes.keys, isNotEmpty);
    expect(loadedThemes.keys, contains(themeLight));
    expect(loadedThemes.keys, contains(themeDark));
  });

  test('muted text stays readable on the page in every palette', () {
    for (final String name in loadedThemes.keys) {
      applyTheme(name);
      // Flattened first: computeLuminance() ignores alpha, so the translucent
      // ink has to be composited onto what it is drawn over.
      final double ratio = contrastRatio(
        Color.alphaBlend(clTextMuted, clFon),
        clFon,
      );
      expect(
        ratio,
        greaterThanOrEqualTo(minTextContrast),
        reason: '$name: muted text is $ratio:1 on the background',
      );
    }
  });

  test('muted text stays readable on a selected row in every palette', () {
    // A device can be chosen and then go offline, which leaves muted text on
    // the selection tint rather than on the page.
    for (final String name in loadedThemes.keys) {
      applyTheme(name);
      final Color surface = _selectedSurface;
      final double ratio = contrastRatio(
        Color.alphaBlend(clTextMuted, surface),
        surface,
      );
      expect(
        ratio,
        greaterThanOrEqualTo(minTextContrast),
        reason: '$name: muted text is $ratio:1 on a selected row',
      );
    }
  });

  test('body text stays readable in every palette', () {
    for (final String name in loadedThemes.keys) {
      applyTheme(name);
      expect(
        contrastRatio(clText, clFon),
        greaterThanOrEqualTo(minTextContrast),
        reason: '$name: body text on the background',
      );
      expect(
        contrastRatio(clUpBarText, clUpBar),
        greaterThanOrEqualTo(minTextContrast),
        reason: '$name: app bar text on the app bar',
      );
    }
  });

  test('the frame colour is not a text colour, which is why muted exists', () {
    // Kept as a check rather than a comment: if a palette ever gave clFrame
    // enough contrast to read, the reason for clTextMuted would be worth
    // revisiting instead of silently keeping two colours that do one job.
    applyTheme(themeLight);
    expect(contrastRatio(clFrame, clFon), lessThan(minTextContrast));
  });

  test('contrastRatio is symmetric and bounded', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(Colors.white, Colors.black), closeTo(21, 0.01));
    expect(contrastRatio(Colors.white, Colors.white), closeTo(1, 0.0001));
  });
}

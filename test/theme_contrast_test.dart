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

// The track a transfer's bar is drawn on: the frame colour at the alpha the row
// uses, over the page.
Color get _barTrack => Color.alphaBlend(clFrame.withValues(alpha: 0.3), clFon);

// Degrees apart on the colour wheel, the short way round.
double _hueGap(Color a, Color b) {
  final double diff =
      (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
  return diff > 180 ? 360 - diff : diff;
}

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

  test('the badge of a departed device is visible, and not the online one', () {
    // The filled badge a device gets when it closed the app: the circle against
    // the page and against a selected row, and the struck-through icon punched
    // out of it in the background colour. The hue checks keep it out of the
    // green that means the device is there, and away from the warm tones every
    // failure on this screen is painted in.
    for (final String name in loadedThemes.keys) {
      applyTheme(name);
      expect(
        loadedThemes[name]!['departed'],
        isNotNull,
        reason: '$name has no departed colour of its own',
      );
      expect(
        contrastRatio(clDeparted, clFon),
        greaterThanOrEqualTo(3),
        reason: '$name: the departed badge on the background',
      );
      expect(
        contrastRatio(clDeparted, _selectedSurface),
        greaterThanOrEqualTo(3),
        reason: '$name: the departed badge on a selected row',
      );
      expect(
        contrastRatio(clFon, clDeparted),
        greaterThanOrEqualTo(minTextContrast),
        reason: '$name: the icon punched out of the departed badge',
      );
      expect(
        HSLColor.fromColor(clDeparted).saturation,
        greaterThanOrEqualTo(0.15),
        reason: '$name: departed is grey, which is what it has to differ from',
      );
      expect(
        _hueGap(clDeparted, clGreen),
        greaterThanOrEqualTo(60),
        reason: '$name: departed is too close to the colour of being there',
      );
      expect(
        _hueGap(clDeparted, clError),
        greaterThanOrEqualTo(30),
        reason: '$name: departed reads as a failure',
      );
    }
  });

  test('every palette names the unconfirmed colour itself', () {
    // Without it a new palette silently borrows the fallback, which belongs to
    // another theme and can land anywhere against its background.
    for (final MapEntry<String, Map<String, String>> palette
        in loadedThemes.entries) {
      expect(
        palette.value['unconfirmed'],
        isNotNull,
        reason: '${palette.key} has no unconfirmed colour of its own',
      );
    }
  });

  test('an unconfirmed bar is visible and not another warm tone', () {
    // A bar is a control carrying meaning, so 3:1 rather than the text figure.
    // The hue check is the point of the colour: every other state of this bar —
    // running, partial, failed — is warm, and a violet is what keeps a finished
    // transfer nobody confirmed from reading as one still going.
    for (final String name in loadedThemes.keys) {
      applyTheme(name);
      expect(
        contrastRatio(clUnconfirmed, _barTrack),
        greaterThanOrEqualTo(3),
        reason: '$name: the unconfirmed bar on its track',
      );
      expect(
        _hueGap(clUnconfirmed, clProgress),
        greaterThanOrEqualTo(60),
        reason: '$name: unconfirmed is too close to the running colour',
      );
      expect(
        _hueGap(clUnconfirmed, clError),
        greaterThanOrEqualTo(60),
        reason: '$name: unconfirmed is too close to the failure colour',
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

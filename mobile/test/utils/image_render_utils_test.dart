import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/image_adjustments.model.dart';
import 'package:immich_mobile/utils/image_render.utils.dart';

const _noTransform = (crop: Rect.fromLTRB(0, 0, 1, 1), rotation: 0, flipHorizontal: false, flipVertical: false);

ImageAdjustments _tone(ToneAdjustment tone, double value) => ImageAdjustments.none.withTone(tone, value);

void main() {
  group('ImageAdjustments', () {
    test('is the identity without changes', () {
      expect(ImageAdjustments.none.isIdentity, isTrue);
      expect(_tone(ToneAdjustment.shadows, 0).isIdentity, isTrue);
      expect(_tone(ToneAdjustment.shadows, 0), ImageAdjustments.none);
    });

    test('resize alone is not a tone change', () {
      final adjustments = ImageAdjustments.none.withMaxLongEdge(1280);
      expect(adjustments.hasToneChanges, isFalse);
      expect(adjustments.isIdentity, isFalse);
    });
  });

  group('renderedSize', () {
    test('applies the crop and swaps sides for quarter turns', () {
      const geometry = (crop: Rect.fromLTWH(0, 0, 0.5, 1), rotation: 90, flipHorizontal: false, flipVertical: false);
      expect(renderedSize(4000, 3000, geometry, null), (width: 3000, height: 2000));
    });

    test('limits the longest edge without upscaling', () {
      expect(renderedSize(4000, 3000, _noTransform, 1920), (width: 1920, height: 1440));
      expect(renderedSize(1000, 500, _noTransform, 1920), (width: 1000, height: 500));
    });
  });

  group('renderEditedImage', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('render_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    // 64x32 source: left half red, right half blue, with EXIF date and orientation
    File writeSource() {
      final image = img.Image(width: 64, height: 32);
      for (final pixel in image) {
        pixel
          ..r = pixel.x < 32 ? 255 : 0
          ..g = 0
          ..b = pixel.x < 32 ? 0 : 255;
      }
      image.exif.imageIfd['DateTime'] = '2020:01:02 03:04:05';
      image.exif.imageIfd.orientation = 1;
      return File('${dir.path}/source.jpg')..writeAsBytesSync(img.encodeJpg(image, quality: 100));
    }

    Future<(img.Image, img.ExifData?)> render(RenderGeometry geometry, ImageAdjustments adjustments) async {
      final source = writeSource();
      final output = await renderEditedImage(
        source: source,
        geometry: geometry,
        adjustments: adjustments,
        outputPath: '${dir.path}/out.jpg',
      );
      final bytes = output.readAsBytesSync();
      return (img.decodeJpg(bytes)!, img.decodeJpgExif(bytes));
    }

    testWidgets('crops, rotates clockwise and keeps EXIF', (tester) async {
      // keep the left 3/4 (red + some blue) so left and right can be told apart after rotating
      const geometry = (crop: Rect.fromLTWH(0, 0, 0.75, 1), rotation: 90, flipHorizontal: false, flipVertical: false);
      final (result, exif) = (await tester.runAsync(() => render(geometry, ImageAdjustments.none)))!;

      expect(result.width, 32);
      expect(result.height, 48);
      // clockwise: the left (red) side ends up at the top, the blue side at the bottom
      expect(result.getPixel(16, 4).r, greaterThan(200));
      expect(result.getPixel(16, 44).b, greaterThan(200));
      expect(exif?.imageIfd['DateTime']?.toString(), '2020:01:02 03:04:05');
      expect(exif?.imageIfd.orientation, 1);
    });

    testWidgets('mirrors horizontally and resizes', (tester) async {
      const geometry = (crop: Rect.fromLTRB(0, 0, 1, 1), rotation: 0, flipHorizontal: true, flipVertical: false);
      final (result, _) = (await tester.runAsync(() => render(geometry, const ImageAdjustments(maxLongEdge: 32))))!;

      expect(result.width, 32);
      expect(result.height, 16);
      expect(result.getPixel(2, 8).b, greaterThan(200));
      expect(result.getPixel(30, 8).r, greaterThan(200));
    });

    // 32x32 source of a single grey level
    Future<int> renderGrey(
      WidgetTester tester,
      int level,
      ImageAdjustments adjustments, {
      int x = 16,
      int y = 16,
    }) async {
      final image = img.Image(width: 32, height: 32)..clear(img.ColorRgb8(level, level, level));
      final source = File('${dir.path}/grey.jpg')..writeAsBytesSync(img.encodeJpg(image, quality: 100));
      final result = (await tester.runAsync(() async {
        final output = await renderEditedImage(
          source: source,
          geometry: _noTransform,
          adjustments: adjustments,
          outputPath: '${dir.path}/grey_out.jpg',
        );
        return img.decodeJpg(output.readAsBytesSync())!;
      }))!;
      return result.getPixel(x, y).g.toInt();
    }

    testWidgets('saturation -1 turns colours grey', (tester) async {
      final (result, _) = (await tester.runAsync(() => render(_noTransform, _tone(ToneAdjustment.saturation, -1))))!;

      final pixel = result.getPixel(8, 8);
      expect((pixel.r - pixel.b).abs(), lessThan(8));
      expect((pixel.r - pixel.g).abs(), lessThan(8));
    });

    testWidgets('brightness +1 doubles mid tones', (tester) async {
      expect(await renderGrey(tester, 60, _tone(ToneAdjustment.brightness, 1)), closeTo(120, 4));
    });

    testWidgets('shadows lift dark tones and leave bright ones', (tester) async {
      expect(await renderGrey(tester, 40, _tone(ToneAdjustment.shadows, 1)), greaterThan(60));
      expect(await renderGrey(tester, 240, _tone(ToneAdjustment.shadows, 1)), closeTo(240, 4));
    });

    testWidgets('highlights darken bright tones and leave dark ones', (tester) async {
      expect(await renderGrey(tester, 220, _tone(ToneAdjustment.highlights, -1)), lessThan(190));
      expect(await renderGrey(tester, 30, _tone(ToneAdjustment.highlights, -1)), closeTo(30, 4));
    });

    testWidgets('black point deepens dark tones', (tester) async {
      expect(await renderGrey(tester, 30, _tone(ToneAdjustment.blackPoint, 1)), lessThan(10));
    });

    testWidgets('vignette darkens the corners only', (tester) async {
      final vignette = _tone(ToneAdjustment.vignette, -1);
      expect(await renderGrey(tester, 128, vignette), closeTo(128, 4));
      expect(await renderGrey(tester, 128, vignette, x: 1, y: 1), lessThan(64));
    });
  });
}

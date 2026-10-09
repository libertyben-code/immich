import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/image_adjustments.model.dart';
import 'package:immich_mobile/utils/image_render.utils.dart';

const _noTransform = (crop: Rect.fromLTRB(0, 0, 1, 1), rotation: 0, flipHorizontal: false, flipVertical: false);

List<double> _apply(List<double> m, List<double> rgb) => [
  for (var row = 0; row < 3; row++)
    m[row * 5] * rgb[0] + m[row * 5 + 1] * rgb[1] + m[row * 5 + 2] * rgb[2] + m[row * 5 + 4],
];

void main() {
  group('ImageAdjustments.colorMatrix', () {
    test('is the identity without changes', () {
      expect(ImageAdjustments.none.isIdentity, isTrue);
      expect(_apply(ImageAdjustments.none.colorMatrix, [10, 120, 250]), [10, 120, 250]);
    });

    test('brightness +1 doubles the values', () {
      expect(_apply(const ImageAdjustments(brightness: 1).colorMatrix, [10, 60, 100]), [20, 120, 200]);
    });

    test('contrast keeps mid grey', () {
      final result = _apply(const ImageAdjustments(contrast: 0.5).colorMatrix, [128, 128, 128]);
      for (final value in result) {
        expect(value, closeTo(128, 1e-9));
      }
    });

    test('saturation -1 turns colours grey', () {
      final result = _apply(const ImageAdjustments(saturation: -1).colorMatrix, [255, 0, 0]);
      expect(result[0], closeTo(result[1], 1e-9));
      expect(result[1], closeTo(result[2], 1e-9));
    });

    test('warmth raises red and lowers blue', () {
      final result = _apply(const ImageAdjustments(warmth: 1).colorMatrix, [100, 100, 100]);
      expect(result[0], greaterThan(100));
      expect(result[2], lessThan(100));
    });

    test('resize alone is not a colour change', () {
      const adjustments = ImageAdjustments(maxLongEdge: 1280);
      expect(adjustments.hasColorChanges, isFalse);
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

    testWidgets('applies the colour matrix', (tester) async {
      final (result, _) = (await tester.runAsync(() => render(_noTransform, const ImageAdjustments(saturation: -1))))!;

      final pixel = result.getPixel(8, 8);
      expect((pixel.r - pixel.b).abs(), lessThan(8));
      expect((pixel.r - pixel.g).abs(), lessThan(8));
    });
  });
}

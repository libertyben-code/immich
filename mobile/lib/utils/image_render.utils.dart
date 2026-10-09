import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/image_adjustments.model.dart';
import 'package:logging/logging.dart';

final _log = Logger('ImageRender');

const _jpegQuality = 92;

/// The geometry chosen in the editor, in the same terms as the editor state:
/// [crop] is a fraction of the upright (EXIF-oriented) image, the flips are
/// applied to the cropped image and [rotation] (clockwise degrees) last.
typedef RenderGeometry = ({Rect crop, int rotation, bool flipHorizontal, bool flipVertical});

/// Size of the saved image for a source of [width] x [height] pixels.
({int width, int height}) renderedSize(int width, int height, RenderGeometry geometry, int? maxLongEdge) {
  final cropWidth = geometry.crop.width * width;
  final cropHeight = geometry.crop.height * height;
  final quarterTurned = _normalizeRotation(geometry.rotation) % 180 != 0;
  final outWidth = quarterTurned ? cropHeight : cropWidth;
  final outHeight = quarterTurned ? cropWidth : cropHeight;
  final scale = maxLongEdge == null ? 1.0 : min(1.0, maxLongEdge / max(outWidth, outHeight));
  return (width: max(1, (outWidth * scale).round()), height: max(1, (outHeight * scale).round()));
}

/// Renders [source] with the editor's geometry and [adjustments] into a new
/// JPEG at [outputPath]. The original's EXIF data (dates, GPS, camera) is
/// carried over when the source is a JPEG.
Future<File> renderEditedImage({
  required File source,
  required RenderGeometry geometry,
  required ImageAdjustments adjustments,
  required String outputPath,
}) async {
  // Flutter's decoder applies the EXIF orientation, matching what the editor shows
  final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
  final codec = await ui.instantiateImageCodecFromBuffer(buffer);
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }

  final ByteData pixels;
  final ({int width, int height}) size;
  try {
    size = renderedSize(image.width, image.height, geometry, adjustments.maxLongEdge);
    pixels = await _draw(image, size, geometry, adjustments);
  } finally {
    image.dispose();
  }

  final sourcePath = source.path;
  final jpeg = await Isolate.run(() => _encodeJpeg(pixels, size.width, size.height, sourcePath));
  return File(outputPath).writeAsBytes(jpeg, flush: true);
}

Future<ByteData> _draw(
  ui.Image image,
  ({int width, int height}) size,
  RenderGeometry geometry,
  ImageAdjustments adjustments,
) async {
  final crop = geometry.crop;
  final src = Rect.fromLTWH(
    crop.left * image.width,
    crop.top * image.height,
    crop.width * image.width,
    crop.height * image.height,
  );
  final rotation = _normalizeRotation(geometry.rotation);
  final quarterTurned = rotation % 180 != 0;
  final scale = (quarterTurned ? size.height : size.width) / src.width;

  final paint = Paint()
    ..filterQuality = FilterQuality.high
    ..isAntiAlias = true;
  if (adjustments.hasColorChanges) {
    paint.colorFilter = ColorFilter.matrix(adjustments.colorMatrix);
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..translate(size.width / 2, size.height / 2)
    ..rotate(rotation * pi / 180)
    ..scale(geometry.flipHorizontal ? -1 : 1, geometry.flipVertical ? -1 : 1);
  canvas.drawImageRect(
    image,
    src,
    Rect.fromCenter(center: Offset.zero, width: src.width * scale, height: src.height * scale),
    paint,
  );

  final picture = recorder.endRecording();
  final rendered = await picture.toImage(size.width, size.height);
  picture.dispose();
  try {
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) {
      throw StateError('Could not read the rendered image');
    }
    return bytes;
  } finally {
    rendered.dispose();
  }
}

Uint8List _encodeJpeg(ByteData pixels, int width, int height, String sourcePath) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    numChannels: 4,
  );

  final exif = _readExif(sourcePath);
  if (exif != null) {
    // the pixels are already upright and the old thumbnail no longer matches
    exif.imageIfd.orientation = 1;
    exif.directories.remove('ifd1');
    final ifd0 = exif.imageIfd;
    if (ifd0.data.containsKey(0x0100)) {
      ifd0.imageWidth = width;
      ifd0.imageHeight = height;
    }
    if (exif.imageIfd.sub.containsKey('exif')) {
      final exifIfd = exif.exifIfd;
      if (exifIfd.data.containsKey(0xA002)) {
        exifIfd[0xA002] = width;
        exifIfd[0xA003] = height;
      }
    }
    image.exif = exif;
  }

  return img.encodeJpg(image, quality: _jpegQuality);
}

img.ExifData? _readExif(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    // only JPEG originals; HEIC and others keep just the date, set at upload
    if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      return null;
    }
    final exif = img.decodeJpgExif(bytes);
    return exif == null || exif.isEmpty ? null : exif;
  } catch (e) {
    _log.warning('Could not read EXIF data from the original', e);
    return null;
  }
}

int _normalizeRotation(int degrees) => ((degrees % 360) + 360) % 360;

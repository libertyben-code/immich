import 'dart:math';

/// Colour and size adjustments made in the built-in editor. Unlike crop,
/// rotate and mirror these are not part of the server's edit model, so they
/// are rendered on the device into a new copy of the photo.
///
/// The colour values range from -1 to 1, with 0 leaving the image unchanged.
class ImageAdjustments {
  final double brightness;
  final double contrast;
  final double saturation;
  final double warmth;

  /// Longest edge of the saved image in pixels, `null` keeps the full size.
  final int? maxLongEdge;

  const ImageAdjustments({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.maxLongEdge,
  });

  static const none = ImageAdjustments();

  bool get hasColorChanges => brightness != 0 || contrast != 0 || saturation != 0 || warmth != 0;

  bool get isIdentity => !hasColorChanges && maxLongEdge == null;

  ImageAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
    int? Function()? maxLongEdge,
  }) {
    return ImageAdjustments(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      warmth: warmth ?? this.warmth,
      maxLongEdge: maxLongEdge != null ? maxLongEdge() : this.maxLongEdge,
    );
  }

  /// The colour changes as a 4x5 matrix for `ColorFilter.matrix`. The live
  /// preview and the saved copy both use it, so what you see is what is saved.
  List<double> get colorMatrix {
    var matrix = _identity;

    // brightness as exposure: up to one stop darker or brighter
    if (brightness != 0) {
      final gain = pow(2, brightness).toDouble();
      matrix = _multiply(_scale(gain, gain, gain), matrix);
    }

    // contrast around mid grey
    if (contrast != 0) {
      final factor = contrast > 0 ? 1 + contrast : 1 + contrast * 0.7;
      final offset = 128 * (1 - factor);
      matrix = _multiply(_scale(factor, factor, factor, offset), matrix);
    }

    if (saturation != 0) {
      matrix = _multiply(_saturation(1 + saturation), matrix);
    }

    // warmth shifts the balance between red and blue
    if (warmth != 0) {
      matrix = _multiply(_scale(1 + 0.2 * warmth, 1 + 0.03 * warmth, 1 - 0.2 * warmth), matrix);
    }

    return matrix;
  }

  @override
  bool operator ==(Object other) =>
      other is ImageAdjustments &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.warmth == warmth &&
      other.maxLongEdge == maxLongEdge;

  @override
  int get hashCode => Object.hash(brightness, contrast, saturation, warmth, maxLongEdge);
}

const _identity = <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

List<double> _scale(double r, double g, double b, [double offset = 0]) => [
  r, 0, 0, 0, offset, //
  0, g, 0, 0, offset,
  0, 0, b, 0, offset,
  0, 0, 0, 1, 0,
];

List<double> _saturation(double s) {
  // Rec. 709 luma weights
  const lr = 0.2126;
  const lg = 0.7152;
  const lb = 0.0722;
  final inv = 1 - s;
  return [
    lr * inv + s, lg * inv, lb * inv, 0, 0, //
    lr * inv, lg * inv + s, lb * inv, 0, 0,
    lr * inv, lg * inv, lb * inv + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// Returns `a * b` for 4x5 colour matrices, i.e. [b] is applied first.
List<double> _multiply(List<double> a, List<double> b) {
  final result = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      var value = col == 4 ? a[row * 5 + 4] : 0.0;
      for (var k = 0; k < 4; k++) {
        value += a[row * 5 + k] * b[k * 5 + col];
      }
      result[row * 5 + col] = value;
    }
  }
  return result;
}

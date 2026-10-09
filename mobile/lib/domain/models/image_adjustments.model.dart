/// Tone and colour adjustments of the built-in editor, each from -1 to 1 with
/// 0 leaving the image unchanged. The order matches the uniforms of
/// `shaders/image_adjust.frag`.
enum ToneAdjustment {
  brightness,
  contrast,
  whitePoint,
  highlights,
  shadows,
  blackPoint,
  vignette,
  saturation,
  vibrance,
  warmth,
  tint,
  sharpness,
}

/// Adjustments made in the built-in editor. Unlike crop, rotate and mirror
/// these are not part of the server's edit model, so they are rendered on the
/// device into a new copy of the photo.
class ImageAdjustments {
  /// Changed tones; missing ones are 0.
  final Map<ToneAdjustment, double> tones;

  /// Longest edge of the saved image in pixels, `null` keeps the full size.
  final int? maxLongEdge;

  const ImageAdjustments({this.tones = const {}, this.maxLongEdge});

  static const none = ImageAdjustments();

  double operator [](ToneAdjustment tone) => tones[tone] ?? 0;

  bool get hasToneChanges => tones.values.any((value) => value != 0);

  bool get isIdentity => !hasToneChanges && maxLongEdge == null;

  ImageAdjustments withTone(ToneAdjustment tone, double value) =>
      ImageAdjustments(tones: {...tones, tone: value}, maxLongEdge: maxLongEdge);

  ImageAdjustments withMaxLongEdge(int? value) => ImageAdjustments(tones: tones, maxLongEdge: value);

  @override
  bool operator ==(Object other) =>
      other is ImageAdjustments &&
      other.maxLongEdge == maxLongEdge &&
      ToneAdjustment.values.every((tone) => other[tone] == this[tone]);

  @override
  int get hashCode => Object.hashAll([maxLongEdge, for (final tone in ToneAdjustment.values) this[tone]]);
}

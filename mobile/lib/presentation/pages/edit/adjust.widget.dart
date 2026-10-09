import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/image_adjustments.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/utils/image_render.utils.dart';
import 'package:logging/logging.dart';

final _log = Logger('AdjustPreview');

/// Long edge of the live preview; the saved copy uses the full resolution.
const _previewLongEdge = 1600;

/// Colour and size adjustments of the photo open in the editor. They are
/// rendered on the device into a new copy when saved, see [ImageAdjustments].
final imageAdjustmentsProvider = NotifierProvider.autoDispose<ImageAdjustmentsNotifier, ImageAdjustments>(
  ImageAdjustmentsNotifier.new,
);

class ImageAdjustmentsNotifier extends AutoDisposeNotifier<ImageAdjustments> {
  @override
  ImageAdjustments build() => ImageAdjustments.none;

  void reset() => state = ImageAdjustments.none;

  void setTone(ToneAdjustment tone, double value) => state = state.withTone(tone, value);

  void setMaxLongEdge(int? value) => state = state.withMaxLongEdge(value);
}

extension EditorStateGeometry on EditorState {
  RenderGeometry get geometry =>
      (crop: crop, rotation: rotationAngle, flipHorizontal: flipHorizontal, flipVertical: flipVertical);
}

/// The photo as it will be saved: cropped, mirrored and rotated, rendered with
/// the same shader as the saved copy. Press and hold to compare with the original.
class AdjustPreview extends ConsumerStatefulWidget {
  final ImageProvider image;

  const AdjustPreview({super.key, required this.image});

  @override
  ConsumerState<AdjustPreview> createState() => _AdjustPreviewState();
}

class _AdjustPreviewState extends ConsumerState<AdjustPreview> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(_onImage, onError: _onImageError);
  ui.FragmentProgram? _program;
  bool _showOriginal = false;

  // the decoded preview, the framed (cropped/rotated) copy and the adjusted one
  ui.Image? _source;
  ui.Image? _framed;
  RenderGeometry? _framedFor;
  ui.Image? _adjusted;
  ImageAdjustments? _adjustedFor;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProgram());
  }

  Future<void> _loadProgram() async {
    try {
      final program = await loadAdjustmentShader();
      if (mounted) {
        setState(() => _program = program);
      }
    } catch (error, stack) {
      _log.severe('Failed to load the adjustment shader', error, stack);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key != _stream?.key) {
      _stream?.removeListener(_listener);
      _stream = stream..addListener(_listener);
    }
  }

  void _onImage(ImageInfo info, bool _) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _source?.dispose();
      _source = info.image;
      _clearFramed();
    });
  }

  void _onImageError(Object error, StackTrace? stack) => _log.warning('Failed to load the preview image', error, stack);

  void _clearFramed() {
    _framed?.dispose();
    _framed = null;
    _framedFor = null;
    _clearAdjusted();
  }

  void _clearAdjusted() {
    _adjusted?.dispose();
    _adjusted = null;
    _adjustedFor = null;
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _clearFramed();
    _source?.dispose();
    super.dispose();
  }

  /// The image to show, re-rendered only when the geometry or adjustments change.
  ui.Image? _render(RenderGeometry geometry, ImageAdjustments adjustments) {
    final source = _source;
    if (source == null) {
      return null;
    }
    if (_framed == null || _framedFor != geometry) {
      _clearFramed();
      _framed = frameImageSync(source, geometry, maxLongEdge: _previewLongEdge);
      _framedFor = geometry;
    }

    final program = _program;
    if (_showOriginal || program == null || !adjustments.hasToneChanges) {
      return _framed;
    }
    if (_adjusted == null || _adjustedFor != adjustments) {
      _clearAdjusted();
      _adjusted = adjustImageSync(program, _framed!, adjustments);
      _adjustedFor = adjustments;
    }
    return _adjusted;
  }

  @override
  Widget build(BuildContext context) {
    final geometry = ref.watch(editorStateProvider.select((state) => state.geometry));
    final adjustments = ref.watch(imageAdjustmentsProvider);
    final image = _render(geometry, adjustments);

    return GestureDetector(
      onLongPressStart: (_) => setState(() => _showOriginal = true),
      onLongPressEnd: (_) => setState(() => _showOriginal = false),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: image == null
            ? const Center(child: CircularProgressIndicator())
            : SizedBox.expand(
                child: RawImage(image: image, fit: BoxFit.contain),
              ),
      ),
    );
  }
}

extension on ToneAdjustment {
  IconData get icon => switch (this) {
    ToneAdjustment.brightness => Icons.brightness_6_outlined,
    ToneAdjustment.contrast => Icons.contrast,
    ToneAdjustment.whitePoint => Icons.wb_sunny_outlined,
    ToneAdjustment.highlights => Icons.flare,
    ToneAdjustment.shadows => Icons.dark_mode_outlined,
    ToneAdjustment.blackPoint => Icons.circle,
    ToneAdjustment.vignette => Icons.vignette_outlined,
    ToneAdjustment.saturation => Icons.palette_outlined,
    ToneAdjustment.vibrance => Icons.auto_awesome_outlined,
    ToneAdjustment.warmth => Icons.thermostat,
    ToneAdjustment.tint => Icons.water_drop_outlined,
    ToneAdjustment.sharpness => Icons.deblur,
  };

  String label(BuildContext context) => switch (this) {
    ToneAdjustment.brightness => context.t.editor_brightness,
    ToneAdjustment.contrast => context.t.editor_contrast,
    ToneAdjustment.whitePoint => context.t.editor_white_point,
    ToneAdjustment.highlights => context.t.editor_highlights,
    ToneAdjustment.shadows => context.t.editor_shadows,
    ToneAdjustment.blackPoint => context.t.editor_black_point,
    ToneAdjustment.vignette => context.t.editor_vignette,
    ToneAdjustment.saturation => context.t.editor_saturation,
    ToneAdjustment.vibrance => context.t.editor_vibrance,
    ToneAdjustment.warmth => context.t.editor_warmth,
    ToneAdjustment.tint => context.t.editor_tint,
    ToneAdjustment.sharpness => context.t.editor_sharpness,
  };
}

class AdjustControls extends ConsumerStatefulWidget {
  const AdjustControls({super.key});

  @override
  ConsumerState<AdjustControls> createState() => _AdjustControlsState();
}

class _AdjustControlsState extends ConsumerState<AdjustControls> {
  /// The selected slider, `null` when resize is selected.
  ToneAdjustment? _tone = ToneAdjustment.brightness;

  @override
  Widget build(BuildContext context) {
    final adjustments = ref.watch(imageAdjustmentsProvider);
    final tone = _tone;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final value in ToneAdjustment.values)
                _ToolButton(
                  icon: value.icon,
                  label: value.label(context),
                  isSelected: value == tone,
                  isChanged: adjustments[value] != 0,
                  onPressed: () => setState(() => _tone = value),
                ),
              _ToolButton(
                icon: Icons.photo_size_select_large,
                label: context.t.editor_resize,
                isSelected: tone == null,
                isChanged: adjustments.maxLongEdge != null,
                onPressed: () => setState(() => _tone = null),
              ),
            ],
          ),
        ),
        SizedBox(height: 64, child: tone == null ? const _ResizeOptions() : _AdjustSlider(tone: tone)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            context.t.editor_adjust_saves_copy,
            textAlign: TextAlign.center,
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isChanged;
  final VoidCallback onPressed;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isChanged,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? context.primaryColor : context.themeData.iconTheme.color;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          Badge(
            isLabelVisible: isChanged,
            smallSize: 6,
            backgroundColor: context.primaryColor,
            offset: const Offset(-6, 6),
            child: IconButton(
              iconSize: 28,
              icon: Icon(icon, color: color),
              onPressed: onPressed,
            ),
          ),
          Text(label, style: context.textTheme.labelSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _AdjustSlider extends ConsumerWidget {
  final ToneAdjustment tone;

  const _AdjustSlider({required this.tone});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(imageAdjustmentsProvider.select((adjustments) => adjustments[tone]));
    final notifier = ref.watch(imageAdjustmentsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: value * 100,
              min: -100,
              max: 100,
              divisions: 200,
              onChanged: (newValue) => notifier.setTone(tone, newValue.roundToDouble() / 100),
            ),
          ),
          SizedBox(
            width: 40,
            child: GestureDetector(
              // tap the number to reset this adjustment
              onTap: () => notifier.setTone(tone, 0),
              child: Text('${(value * 100).round()}', textAlign: TextAlign.end, style: context.textTheme.labelLarge),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResizeOptions extends ConsumerWidget {
  static const _longEdges = [3840, 2560, 1920, 1280];

  const _ResizeOptions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final maxLongEdge = ref.watch(imageAdjustmentsProvider.select((adjustments) => adjustments.maxLongEdge));
    final notifier = ref.watch(imageAdjustmentsProvider.notifier);

    final knownSize = editorState.originalWidth > 0 && editorState.originalHeight > 0;
    RenderSize? sizeFor(int? longEdge) => knownSize
        ? renderedSize(editorState.originalWidth, editorState.originalHeight, editorState.geometry, longEdge)
        : null;
    final full = sizeFor(null);
    final fullLongEdge = full == null ? null : (full.width > full.height ? full.width : full.height);

    Widget option(int? longEdge, String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: maxLongEdge == longEdge,
        onSelected: (_) => notifier.setMaxLongEdge(longEdge),
      ),
    );

    String describe(RenderSize? size, String fallback) => size == null ? fallback : '${size.width} × ${size.height}';

    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            option(null, '${context.t.editor_resize_original} (${describe(full, '100%')})'),
            for (final longEdge in _longEdges)
              if (fullLongEdge == null || longEdge < fullLongEdge)
                option(longEdge, describe(sizeFor(longEdge), '$longEdge px')),
          ],
        ),
      ),
    );
  }
}

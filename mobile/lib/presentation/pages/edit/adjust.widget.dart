import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/image_adjustments.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/utils/image_render.utils.dart';

/// Colour and size adjustments of the photo open in the editor. They are
/// rendered on the device into a new copy when saved, see [ImageAdjustments].
final imageAdjustmentsProvider = NotifierProvider.autoDispose<ImageAdjustmentsNotifier, ImageAdjustments>(
  ImageAdjustmentsNotifier.new,
);

class ImageAdjustmentsNotifier extends AutoDisposeNotifier<ImageAdjustments> {
  @override
  ImageAdjustments build() => ImageAdjustments.none;

  void reset() => state = ImageAdjustments.none;

  void setBrightness(double value) => state = state.copyWith(brightness: value);

  void setContrast(double value) => state = state.copyWith(contrast: value);

  void setSaturation(double value) => state = state.copyWith(saturation: value);

  void setWarmth(double value) => state = state.copyWith(warmth: value);

  void setMaxLongEdge(int? value) => state = state.copyWith(maxLongEdge: () => value);
}

extension EditorStateGeometry on EditorState {
  RenderGeometry get geometry =>
      (crop: crop, rotation: rotationAngle, flipHorizontal: flipHorizontal, flipVertical: flipVertical);
}

/// Wraps [child] with the live colour preview of the current adjustments.
class AdjustedColors extends ConsumerWidget {
  final Widget child;

  const AdjustedColors({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adjustments = ref.watch(imageAdjustmentsProvider);
    if (!adjustments.hasColorChanges) {
      return child;
    }
    return ColorFiltered(colorFilter: ColorFilter.matrix(adjustments.colorMatrix), child: child);
  }
}

/// The photo as it will be saved: cropped, mirrored and rotated, with the
/// colour adjustments applied. Press and hold to compare with the original.
class AdjustPreview extends ConsumerStatefulWidget {
  final ImageProvider image;

  const AdjustPreview({super.key, required this.image});

  @override
  ConsumerState<AdjustPreview> createState() => _AdjustPreviewState();
}

class _AdjustPreviewState extends ConsumerState<AdjustPreview> {
  bool _showOriginal = false;

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorStateProvider);
    final width = editorState.originalWidth.toDouble();
    final height = editorState.originalHeight.toDouble();
    final crop = editorState.crop;

    // where the crop sits within the image, as an alignment of -1..1
    double align(double start, double extent) => extent >= 1 ? 0 : (start / (1 - extent)) * 2 - 1;

    Widget preview = width > 0 && height > 0
        ? SizedBox(
            width: crop.width * width,
            height: crop.height * height,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment(align(crop.left, crop.width), align(crop.top, crop.height)),
                minWidth: width,
                maxWidth: width,
                minHeight: height,
                maxHeight: height,
                child: Image(image: widget.image, fit: BoxFit.fill, gaplessPlayback: true),
              ),
            ),
          )
        : Image(image: widget.image, gaplessPlayback: true);

    preview = RotatedBox(
      quarterTurns: (((editorState.rotationAngle % 360) + 360) % 360) ~/ 90,
      child: Transform.flip(flipX: editorState.flipHorizontal, flipY: editorState.flipVertical, child: preview),
    );
    if (!_showOriginal) {
      preview = AdjustedColors(child: preview);
    }

    return GestureDetector(
      onLongPressStart: (_) => setState(() => _showOriginal = true),
      onLongPressEnd: (_) => setState(() => _showOriginal = false),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(child: FittedBox(child: preview)),
      ),
    );
  }
}

enum _AdjustTool {
  brightness(Icons.brightness_6_outlined),
  contrast(Icons.contrast),
  saturation(Icons.palette_outlined),
  warmth(Icons.thermostat),
  resize(Icons.photo_size_select_large);

  final IconData icon;

  const _AdjustTool(this.icon);

  String label(BuildContext context) => switch (this) {
    _AdjustTool.brightness => context.t.editor_brightness,
    _AdjustTool.contrast => context.t.editor_contrast,
    _AdjustTool.saturation => context.t.editor_saturation,
    _AdjustTool.warmth => context.t.editor_warmth,
    _AdjustTool.resize => context.t.editor_resize,
  };

  bool isChanged(ImageAdjustments adjustments) => switch (this) {
    _AdjustTool.brightness => adjustments.brightness != 0,
    _AdjustTool.contrast => adjustments.contrast != 0,
    _AdjustTool.saturation => adjustments.saturation != 0,
    _AdjustTool.warmth => adjustments.warmth != 0,
    _AdjustTool.resize => adjustments.maxLongEdge != null,
  };
}

class AdjustControls extends ConsumerStatefulWidget {
  const AdjustControls({super.key});

  @override
  ConsumerState<AdjustControls> createState() => _AdjustControlsState();
}

class _AdjustControlsState extends ConsumerState<AdjustControls> {
  _AdjustTool _tool = _AdjustTool.brightness;

  @override
  Widget build(BuildContext context) {
    final adjustments = ref.watch(imageAdjustmentsProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final tool in _AdjustTool.values)
                _ToolButton(
                  tool: tool,
                  isSelected: tool == _tool,
                  isChanged: tool.isChanged(adjustments),
                  onPressed: () => setState(() => _tool = tool),
                ),
            ],
          ),
        ),
        SizedBox(height: 64, child: _tool == _AdjustTool.resize ? const _ResizeOptions() : _AdjustSlider(tool: _tool)),
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
  final _AdjustTool tool;
  final bool isSelected;
  final bool isChanged;
  final VoidCallback onPressed;

  const _ToolButton({required this.tool, required this.isSelected, required this.isChanged, required this.onPressed});

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
              icon: Icon(tool.icon, color: color),
              onPressed: onPressed,
            ),
          ),
          Text(tool.label(context), style: context.textTheme.labelSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _AdjustSlider extends ConsumerWidget {
  final _AdjustTool tool;

  const _AdjustSlider({required this.tool});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adjustments = ref.watch(imageAdjustmentsProvider);
    final notifier = ref.watch(imageAdjustmentsProvider.notifier);
    final (value, onChanged) = switch (tool) {
      _AdjustTool.brightness => (adjustments.brightness, notifier.setBrightness),
      _AdjustTool.contrast => (adjustments.contrast, notifier.setContrast),
      _AdjustTool.saturation => (adjustments.saturation, notifier.setSaturation),
      _AdjustTool.warmth => (adjustments.warmth, notifier.setWarmth),
      _AdjustTool.resize => throw StateError('resize has no slider'),
    };

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
              onChanged: (newValue) => onChanged(newValue.roundToDouble() / 100),
            ),
          ),
          SizedBox(
            width: 40,
            child: GestureDetector(
              // tap the number to reset this adjustment
              onTap: () => onChanged(0),
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
    ({int width, int height})? sizeFor(int? longEdge) => knownSize
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

    String describe(({int width, int height})? size, String fallback) =>
        size == null ? fallback : '${size.width} × ${size.height}';

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

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/edited_copy.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:path/path.dart' as p;

/// Only a single, still image can be handed to an editor. Android only: iOS
/// has no "edit and return" intent, the share sheet covers it there.
final _stateProvider = Provider.family.autoDispose<BaseAsset?, ActionSource>((ref, source) {
  if (!CurrentPlatform.isAndroid) {
    return null;
  }
  final assets = ref.watch(assetsActionProvider(source));
  final asset = assets.singleOrNull;
  if (asset == null || !asset.isImage) {
    return null;
  }
  // Never copy locked-folder or trashed photos into shared storage for another app.
  if (asset case RemoteAsset(isLocked: true) || RemoteAsset(isTrashed: true)) {
    return null;
  }
  return asset;
}, dependencies: [assetsActionProvider]);

/// Opens the photo in a third-party editor, then uploads the result as a new
/// asset stacked on top of the original. The original is never modified.
class ExternalEditAction extends AssetActionBuilder {
  const ExternalEditAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (!ref.watch(_stateProvider(source).select((asset) => asset != null))) {
      return null;
    }

    return .new(
      icon: Icons.open_in_new_rounded,
      label: context.t.edit_in_external_app,
      onAction: () => _edit(context, ref),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final asset = ref.read(_stateProvider(source));
    if (asset == null) {
      return;
    }

    final editorApi = ref.read(externalEditorApiProvider);
    final mediaRepository = ref.read(assetMediaRepositoryProvider);
    final toastService = ref.read(toastServiceProvider);
    final noEditorMessage = context.t.edit_in_external_app_no_editor;
    final nothingReturnedMessage = context.t.edit_in_external_app_nothing_returned;

    if (!await editorApi.hasEditor()) {
      await toastService.error(noEditorMessage);
      return;
    }
    if (!context.mounted) {
      return;
    }

    final cancelCompleter = Completer<void>();
    final progress = ValueNotifier<double?>(null);
    final tempFiles = <FileSystemEntity>[];

    try {
      // 1. full-resolution source (gallery original, or a temp download)
      final source = await runWithProgressDialog(
        context,
        progress,
        cancelCompleter,
        () => mediaRepository.getOriginalFile(
          asset,
          cancelCompleter: cancelCompleter,
          onProgress: (value) => progress.value = value,
        ),
      );
      if (source == null || cancelCompleter.isCompleted) {
        return;
      }
      if (source.tempEntity != null) {
        tempFiles.add(source.tempEntity!);
      }

      // 2. hand off to the editor and wait for it to come back
      final editedPath = await editorApi.editImage(source.file.path, _mimeTypeFor(source.file.path));
      if (editedPath == null || !File(editedPath).existsSync()) {
        // cancelled, or the editor saved its own copy to the gallery (backup will pick it up)
        await toastService.error(nothingReturnedMessage, toast: const ToastOption(timeout: Duration(seconds: 6)));
        return;
      }

      // 3. give the result a recognisable name; the server keeps this as the asset name
      final edited = await File(editedPath).rename(
        p.join(p.dirname(editedPath), '${p.basenameWithoutExtension(asset.name)}_edited${p.extension(editedPath)}'),
      );
      tempFiles.add(edited);

      // 4. keep both (stacked) or replace the original?
      if (!context.mounted) {
        return;
      }
      final outcome = await askEditOutcome(context, ref, asset);
      if (outcome == null || !context.mounted) {
        return;
      }

      // 5. upload the edit, then stack with, or dispose of, the original
      await uploadEditedCopy(context, ref, asset, edited, outcome);
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to edit the asset in an external app');
    } finally {
      progress.dispose();
      await deleteTempFiles(tempFiles);
    }
  }

  static String _mimeTypeFor(String path) => switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.gif' => 'image/gif',
    '.heic' || '.heif' => 'image/heic',
    '.avif' => 'image/avif',
    _ => 'image/*',
  };
}

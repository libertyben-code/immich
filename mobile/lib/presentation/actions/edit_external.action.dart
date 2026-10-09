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
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ExternalEditAction');

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

/// The server original can only be stacked or trashed by its owner. A local
/// photo's remote copy was uploaded by this user; a remote one must match.
bool _ownsServerCopy(BaseAsset asset, String userId) => switch (asset) {
  LocalAsset() => true,
  RemoteAsset(:final ownerId) => ownerId == userId,
};

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
    final uploadService = ref.read(foregroundUploadServiceProvider);
    final assetService = ref.read(assetServiceProvider);
    final toastService = ref.read(toastServiceProvider);
    final userId = ref.read(authUserProvider).id;
    final trashEnabled = ref.read(serverInfoProvider.select((state) => state.serverFeatures.trash));
    final noEditorMessage = context.t.edit_in_external_app_no_editor;
    final uploadedMessage = context.t.edit_in_external_app_uploaded;
    final replacedMessage = context.t.edit_in_external_app_replaced;
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
      final source = await _withProgressDialog(
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

      // 4. keep both (stacked) or replace the original? Only for a server copy
      // this user owns: a local-only photo has nothing to trash remotely, and a
      // partner's or shared-album photo can't be stacked or trashed by us.
      final originalRemoteId = _ownsServerCopy(asset, userId) ? asset.remoteId : null;
      if (!context.mounted) {
        return;
      }
      final outcome = originalRemoteId == null
          ? _EditOutcome.keepBoth
          : await showDialog<_EditOutcome>(
              context: context,
              useRootNavigator: false,
              builder: (_) => _OutcomeDialog(trash: trashEnabled),
            );
      if (outcome == null) {
        return;
      }

      // 5. upload the edit
      String? remoteId;
      String? error;
      await uploadService.uploadShareIntent(
        [edited],
        fileCreatedAt: asset.createdAt,
        onSuccess: (_, id) => remoteId = id,
        onError: (_, message) => error = message,
      );
      if (remoteId == null) {
        throw Exception(_describeUploadError(error));
      }

      // 6. stack with, or dispose of, the original
      switch (outcome) {
        case _EditOutcome.keepBoth when originalRemoteId != null:
          // the edit goes first so it becomes the stack's primary asset
          await assetService.stack(userId, [remoteId!, originalRemoteId]);
          await toastService.success(uploadedMessage);
        case _EditOutcome.keepBoth:
          await toastService.success(uploadedMessage);
        case _EditOutcome.replace:
          if (trashEnabled) {
            await assetService.trash([originalRemoteId!]);
          } else {
            await assetService.delete([originalRemoteId!]);
          }
          await toastService.success(replacedMessage);
      }
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to edit the asset in an external app');
    } finally {
      progress.dispose();
      await _cleanup(tempFiles);
    }
  }

  /// Runs [task] behind a cancellable progress dialog and returns its result.
  Future<T?> _withProgressDialog<T>(
    BuildContext context,
    ValueNotifier<double?> progress,
    Completer<void> cancelCompleter,
    Future<T?> Function() task,
  ) async {
    T? result;
    Object? failure;
    StackTrace? failureStack;
    await showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (dialogContext) {
        unawaited(() async {
          try {
            result = await task();
          } catch (error, stack) {
            failure = error;
            failureStack = stack;
          }
          if (!cancelCompleter.isCompleted && dialogContext.mounted) {
            Navigator.of(dialogContext).pop();
          }
        }());
        return _PreparingDialog(progress: progress, onCancel: () => Navigator.of(dialogContext).pop());
      },
    );
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    if (result == null && !cancelCompleter.isCompleted) {
      // dialog dismissed by the user before the task finished
      cancelCompleter.complete();
    }
    return result;
  }

  Future<void> _cleanup(List<FileSystemEntity> entities) async {
    for (final entity in entities) {
      try {
        if (entity.existsSync()) {
          await entity.delete(recursive: true);
        }
      } catch (e) {
        _log.warning('Failed to delete temporary file: ${entity.path}', e);
      }
    }
  }

  /// Proxies in front of the server answer with HTML pages; keep the toast readable.
  static String _describeUploadError(String? message) {
    if (message == null) {
      return 'Upload failed';
    }
    final status = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(message)?.group(1);
    if (message.contains('<html') && status != null) {
      return 'Upload refused by the server (HTTP $status)';
    }
    return message;
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

enum _EditOutcome { keepBoth, replace }

class _OutcomeDialog extends StatelessWidget {
  /// Whether the server trashes (recoverable) or permanently deletes on replace.
  final bool trash;

  const _OutcomeDialog({required this.trash});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t.edit_in_external_app_save_title),
      contentPadding: const .symmetric(vertical: 8),
      content: Column(
        mainAxisSize: .min,
        children: [
          ListTile(
            leading: const Icon(Icons.filter_none_rounded),
            title: Text(context.t.edit_in_external_app_keep_both),
            subtitle: Text(context.t.edit_in_external_app_keep_both_description),
            onTap: () => Navigator.of(context).pop(_EditOutcome.keepBoth),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: Text(context.t.edit_in_external_app_replace),
            subtitle: Text(
              trash
                  ? context.t.edit_in_external_app_replace_description_trash
                  : context.t.edit_in_external_app_replace_description_delete,
            ),
            onTap: () => Navigator.of(context).pop(_EditOutcome.replace),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.cancel))],
    );
  }
}

class _PreparingDialog extends StatelessWidget {
  final ValueNotifier<double?> progress;
  final VoidCallback onCancel;

  const _PreparingDialog({required this.progress, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: .min,
        children: [
          Container(margin: const .only(bottom: 12), child: Text(context.t.share_dialog_preparing)),
          SizedBox(
            width: 240,
            child: ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, _) => LinearProgressIndicator(value: value, minHeight: 8.0),
            ),
          ),
        ],
      ),
      actions: [TextButton(onPressed: onCancel, child: Text(context.t.cancel))],
    );
  }
}

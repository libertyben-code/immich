import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/image_adjustments.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/utils/image_render.utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('EditedCopy');

/// Saving an edited copy of a photo, shared by the external editor and the
/// built-in editor's adjustments: the copy is uploaded as a new asset and
/// either stacked on top of the original or replaces it (original trashed).
enum EditOutcome { keepBoth, replace }

/// The server original can only be stacked or trashed by its owner. A local
/// photo's remote copy was uploaded by this user; a remote one must match.
bool _ownsServerCopy(BaseAsset asset, String userId) => switch (asset) {
  LocalAsset() => true,
  RemoteAsset(:final ownerId) => ownerId == userId,
};

/// Asks whether to keep the original next to the copy or replace it. Returns
/// `null` when cancelled. Only a server copy this user owns can be replaced:
/// a local-only photo has nothing to trash remotely, and a partner's or
/// shared-album photo can't be stacked or trashed by us.
Future<EditOutcome?> askEditOutcome(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  final userId = ref.read(authUserProvider).id;
  if (!_ownsServerCopy(asset, userId) || asset.remoteId == null) {
    return EditOutcome.keepBoth;
  }
  final trashEnabled = ref.read(serverInfoProvider.select((state) => state.serverFeatures.trash));
  return showDialog<EditOutcome>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _OutcomeDialog(trash: trashEnabled),
  );
}

/// Uploads [edited] with the original's date, then stacks it with, or
/// disposes of, the original according to [outcome]. Throws when the upload fails.
Future<void> uploadEditedCopy(
  BuildContext context,
  WidgetRef ref,
  BaseAsset asset,
  File edited,
  EditOutcome outcome,
) async {
  final uploadService = ref.read(foregroundUploadServiceProvider);
  final assetService = ref.read(assetServiceProvider);
  final toastService = ref.read(toastServiceProvider);
  final userId = ref.read(authUserProvider).id;
  final trashEnabled = ref.read(serverInfoProvider.select((state) => state.serverFeatures.trash));
  final uploadedMessage = context.t.edit_in_external_app_uploaded;
  final replacedMessage = context.t.edit_in_external_app_replaced;
  final originalRemoteId = _ownsServerCopy(asset, userId) ? asset.remoteId : null;

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

  switch (outcome) {
    case EditOutcome.replace when originalRemoteId != null:
      if (trashEnabled) {
        await assetService.trash([originalRemoteId]);
      } else {
        await assetService.delete([originalRemoteId]);
      }
      await toastService.success(replacedMessage);
    case _ when originalRemoteId != null:
      // the edit goes first so it becomes the stack's primary asset
      await assetService.stack(userId, [remoteId!, originalRemoteId]);
      await toastService.success(uploadedMessage);
    case _:
      await toastService.success(uploadedMessage);
  }
}

/// Renders the built-in editor's adjustments (and its crop/rotate/mirror) from
/// the full-resolution original into a new photo and saves it like an
/// external edit. Returns whether a copy was saved.
Future<bool> saveAdjustedCopy(
  BuildContext context,
  WidgetRef ref,
  BaseAsset asset,
  RenderGeometry geometry,
  ImageAdjustments adjustments,
) async {
  final outcome = await askEditOutcome(context, ref, asset);
  if (outcome == null || !context.mounted) {
    return false;
  }

  final mediaRepository = ref.read(assetMediaRepositoryProvider);
  final cancelCompleter = Completer<void>();
  final progress = ValueNotifier<double?>(null);
  final tempFiles = <FileSystemEntity>[];

  try {
    final workDir = await Directory.systemTemp.createTemp('immich_edit_');
    tempFiles.add(workDir);
    if (!context.mounted) {
      return false;
    }

    final rendered = await runWithProgressDialog(context, progress, cancelCompleter, () async {
      final source = await mediaRepository.getOriginalFile(
        asset,
        cancelCompleter: cancelCompleter,
        onProgress: (value) => progress.value = value,
      );
      if (source?.tempEntity != null) {
        tempFiles.add(source!.tempEntity!);
      }
      if (source == null || cancelCompleter.isCompleted) {
        return null;
      }

      progress.value = null;
      return renderEditedImage(
        source: source.file,
        geometry: geometry,
        adjustments: adjustments,
        outputPath: p.join(workDir.path, '${p.basenameWithoutExtension(asset.name)}_edited.jpg'),
      );
    });
    if (rendered == null || cancelCompleter.isCompleted || !context.mounted) {
      return false;
    }

    await uploadEditedCopy(context, ref, asset, rendered, outcome);
    return true;
  } catch (error, stack) {
    handleError(error, stack: stack, description: 'Failed to save the adjusted copy of the asset');
    return false;
  } finally {
    progress.dispose();
    await deleteTempFiles(tempFiles);
  }
}

/// Runs [task] behind a cancellable progress dialog and returns its result.
/// Cancelling completes [cancelCompleter] and returns `null`.
Future<T?> runWithProgressDialog<T>(
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

Future<void> deleteTempFiles(List<FileSystemEntity> entities) async {
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
String _describeUploadError(String? message) {
  if (message == null) {
    return 'Upload failed';
  }
  final status = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(message)?.group(1);
  if (message.contains('<html') && status != null) {
    return 'Upload refused by the server (HTTP $status)';
  }
  return message;
}

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
            onTap: () => Navigator.of(context).pop(EditOutcome.keepBoth),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: Text(context.t.edit_in_external_app_replace),
            subtitle: Text(
              trash
                  ? context.t.edit_in_external_app_replace_description_trash
                  : context.t.edit_in_external_app_replace_description_delete,
            ),
            onTap: () => Navigator.of(context).pop(EditOutcome.replace),
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

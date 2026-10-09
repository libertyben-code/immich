import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/external_editor_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/externaleditor/ExternalEditor.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.externaleditor'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class ExternalEditorHostApi {
  /// Hands [path] to an installed photo editor (ACTION_EDIT on Android) and
  /// resolves once the editor returns. The result is the path of a temp copy
  /// of the edited image, or null when the user cancelled or the editor did
  /// not produce a result the app can read.
  @async
  String? editImage(String path, String mimeType);

  /// True when at least one installed app can handle ACTION_EDIT for images.
  bool hasEditor();
}

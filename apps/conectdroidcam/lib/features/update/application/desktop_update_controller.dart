import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/update_models.dart';
import 'update_controller.dart';

const int compiledBuild = int.fromEnvironment('CDC_BUILD');

final desktopBuildProvider = Provider<int>((ref) => compiledBuild);

final desktopUpdateEnabledProvider = Provider<bool>(
  (ref) =>
      Platform.isLinux &&
      (Platform.environment['FLATPAK_ID'] ?? '').isNotEmpty &&
      ref.read(desktopBuildProvider) > 0,
);

final desktopUpdateProvider =
    NotifierProvider<DesktopUpdateController, ReleaseAsset?>(
      DesktopUpdateController.new,
    );

class DesktopUpdateController extends Notifier<ReleaseAsset?> {
  @override
  ReleaseAsset? build() => null;

  Future<void> check() async {
    if (!ref.read(desktopUpdateEnabledProvider)) return;
    try {
      final latest = await ref
          .read(releaseSourceProvider)
          .latest(suffix: '.flatpak');
      if (latest != null && latest.build > ref.read(desktopBuildProvider)) {
        state = latest;
      }
    } on Object catch (_) {}
  }

  void dismiss() => state = null;
}

const desktopUpdateCommand =
    'flatpak update io.github.eduardo_lima_dev.ConectDroidCam';

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/update_models.dart';
import 'update_controller.dart';

/// Número do build embutido na compilação pelo CI (`--dart-define=CDC_BUILD=N`), o mesmo `N`
/// da release `build-N`. Builds locais ficam com 0.
const int compiledBuild = int.fromEnvironment('CDC_BUILD');

final desktopBuildProvider = Provider<int>((ref) => compiledBuild);

/// O aviso no computador só vale para o app instalado pelo Flatpak de uma release: é o
/// Flatpak que atualiza, e só um build com número sabe se está velho.
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

/// Procura uma versão nova do app do computador. O estado é a release mais nova, quando ela
/// é mais nova que a instalada; senão, `null`. Não instala nada: quem atualiza é o Flatpak.
class DesktopUpdateController extends Notifier<ReleaseAsset?> {
  @override
  ReleaseAsset? build() => null;

  /// Sem internet ou com o GitHub fora, simplesmente não avisa.
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

/// Comando que atualiza o app instalado pelo repositório Flatpak do projeto.
const desktopUpdateCommand =
    'flatpak update io.github.eduardo_lima_dev.ConectDroidCam';

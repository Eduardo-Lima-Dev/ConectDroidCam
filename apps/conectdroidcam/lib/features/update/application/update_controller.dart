import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/update_sources.dart';
import '../domain/update_models.dart';

enum UpdatePhase {
  /// Ainda não procurou, ou o atualizador não vale nesta plataforma.
  idle,
  checking,
  upToDate,

  /// Há uma versão nova; nada foi baixado ainda.
  available,
  downloading,

  /// O Android pede que o usuário permita instalar apps vindos do ConectDroidCam.
  needsPermission,

  /// Baixado e pronto para instalar.
  ready,

  /// A tela de confirmação do Android está aberta.
  installing,
  failed,
}

class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.release,
    this.installedBuild = 0,
    this.progress = 0,
    this.message,
  });

  final UpdatePhase phase;
  final ReleaseApk? release;
  final int installedBuild;

  /// Progresso do download, de 0 a 1.
  final double progress;

  /// Explicação para o usuário quando algo não deu certo.
  final String? message;

  UpdateState copyWith({
    UpdatePhase? phase,
    ReleaseApk? release,
    int? installedBuild,
    double? progress,
    String? Function()? message,
  }) => UpdateState(
    phase: phase ?? this.phase,
    release: release ?? this.release,
    installedBuild: installedBuild ?? this.installedBuild,
    progress: progress ?? this.progress,
    message: message != null ? message() : this.message,
  );
}

/// O atualizador só existe no Android: no Linux, quem atualiza é o Flatpak.
final updaterEnabledProvider = Provider<bool>((ref) => Platform.isAndroid);

final releaseSourceProvider = Provider<ReleaseSource>(
  (ref) => GitHubReleaseSource(),
);

final updateDownloaderProvider = Provider<UpdateDownloader>(
  (ref) => HttpUpdateDownloader(),
);

final updaterPlatformProvider = Provider<UpdaterPlatform>(
  (ref) => ChannelUpdaterPlatform(),
);

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

class UpdateController extends Notifier<UpdateState> {
  StreamSubscription<(InstallStatus, String?)>? _status;
  String? _apkPath;

  @override
  UpdateState build() {
    ref.onDispose(() => _status?.cancel());
    return const UpdateState();
  }

  UpdaterPlatform get _platform => ref.read(updaterPlatformProvider);

  /// Procura uma versão nova. Falhar aqui (sem internet, GitHub fora) não é um erro para o
  /// usuário: o app só não mostra o aviso.
  Future<void> check() async {
    if (!ref.read(updaterEnabledProvider)) return;
    if (state.phase == UpdatePhase.checking ||
        state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.installing) {
      return;
    }
    state = state.copyWith(phase: UpdatePhase.checking, message: () => null);
    try {
      final installed = await _platform.installedBuild();
      final latest = await ref.read(releaseSourceProvider).latest();
      if (latest == null || latest.build <= installed) {
        state = state.copyWith(
          phase: UpdatePhase.upToDate,
          installedBuild: installed,
        );
        return;
      }
      state = UpdateState(
        phase: UpdatePhase.available,
        release: latest,
        installedBuild: installed,
      );
    } on Object catch (_) {
      state = state.copyWith(phase: UpdatePhase.idle);
    }
  }

  /// Baixa a versão nova e, se o Android já permite, abre a instalação.
  Future<void> download() async {
    final release = state.release;
    if (release == null ||
        state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.installing) {
      return;
    }
    state = state.copyWith(
      phase: UpdatePhase.downloading,
      progress: 0,
      message: () => null,
    );
    try {
      final dir = await _platform.downloadDir();
      // Só um APK por vez na pasta: os de atualizações anteriores são apagados.
      for (final old in Directory(dir).listSync().whereType<File>()) {
        if (old.path.endsWith('.apk')) old.deleteSync();
      }
      final path = '$dir/ConectDroidCam-${release.build}.apk';
      await ref
          .read(updateDownloaderProvider)
          .download(
            release.apkUrl,
            path,
            expectedSize: release.size,
            onProgress: (p) => state = state.copyWith(progress: p),
          );
      _apkPath = path;
      state = state.copyWith(phase: UpdatePhase.ready, progress: 1);
      await install();
    } on Object catch (e) {
      state = state.copyWith(
        phase: UpdatePhase.failed,
        message: () => 'Não consegui baixar a atualização: $e',
      );
    }
  }

  /// Abre a instalação do APK já baixado. Sem a permissão, pede ao usuário que a dê.
  Future<void> install() async {
    final path = _apkPath;
    if (path == null) return;
    if (!await _platform.canInstall()) {
      state = state.copyWith(phase: UpdatePhase.needsPermission);
      return;
    }
    _status ??= _platform.installStatus.listen(_onStatus);
    state = state.copyWith(phase: UpdatePhase.installing, message: () => null);
    try {
      await _platform.install(path);
    } on Object catch (e) {
      state = state.copyWith(
        phase: UpdatePhase.failed,
        message: () => 'Não consegui abrir a instalação: $e',
      );
    }
  }

  /// Leva às configurações do Android para permitir que o ConectDroidCam instale apps.
  Future<void> openInstallSettings() => _platform.openInstallSettings();

  void _onStatus((InstallStatus, String?) event) {
    final (status, detail) = event;
    switch (status) {
      case InstallStatus.pendingUser:
        state = state.copyWith(phase: UpdatePhase.installing);
      case InstallStatus.success:
        // Em geral o Android encerra o app ao atualizar; se não, some o aviso.
        state = state.copyWith(phase: UpdatePhase.upToDate);
      case InstallStatus.aborted:
        state = state.copyWith(
          phase: UpdatePhase.ready,
          message: () => 'Instalação cancelada.',
        );
      case InstallStatus.conflict:
        state = state.copyWith(
          phase: UpdatePhase.failed,
          message: () =>
              'O app instalado foi assinado com outra chave (por exemplo, uma '
              'versão de desenvolvimento), e o Android não deixa atualizar por cima. '
              'Desinstale o ConectDroidCam uma vez e instale o APK da release; '
              'depois disso as atualizações funcionam por aqui.',
        );
      case InstallStatus.failure:
        state = state.copyWith(
          phase: UpdatePhase.failed,
          message: () =>
              'A instalação falhou${detail != null ? ': $detail' : '.'}',
        );
    }
  }
}

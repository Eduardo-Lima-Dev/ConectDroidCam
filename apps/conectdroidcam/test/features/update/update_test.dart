import 'dart:async';
import 'dart:io';

import 'package:conectdroidcam/features/update/application/update_controller.dart';
import 'package:conectdroidcam/features/update/data/update_sources.dart';
import 'package:conectdroidcam/features/update/domain/update_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> release(
  String tag, {
  bool apk = true,
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/x/y/releases/tag/$tag',
  'draft': draft,
  'prerelease': prerelease,
  'assets': [
    if (apk)
      {
        'name': 'ConectDroidCam-${tag.replaceFirst('build-', '')}.apk',
        'browser_download_url': 'https://example.com/$tag.apk',
        'size': 1000,
      },
    {
      'name': 'ConectDroidCam.flatpak',
      'browser_download_url': 'https://example.com/$tag.flatpak',
      'size': 2000,
    },
  ],
};

class FakeSource implements ReleaseSource {
  ReleaseAsset? next;
  Object? error;

  @override
  Future<ReleaseAsset?> latest({String suffix = '.apk'}) async {
    if (error != null) throw error!;
    return next;
  }
}

class FakeDownloader implements UpdateDownloader {
  Object? error;
  final List<String> urls = [];

  @override
  Future<void> download(
    String url,
    String destination, {
    required int expectedSize,
    void Function(double progress)? onProgress,
  }) async {
    if (error != null) throw error!;
    urls.add(url);
    onProgress?.call(0.5);
    await File(destination).writeAsBytes(List.filled(10, 1));
    onProgress?.call(1);
  }
}

class FakePlatform implements UpdaterPlatform {
  FakePlatform(this.dir);

  final String dir;
  int build = 4;
  bool allowed = true;
  final List<String> installs = [];
  int settingsOpened = 0;
  int backgroundEnabled = 0;
  int notificationRequests = 0;
  final status = StreamController<(InstallStatus, String?)>.broadcast();

  @override
  Future<int> installedBuild() async => build;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openInstallSettings() async => settingsOpened++;
  @override
  Future<String> downloadDir() async => dir;
  @override
  Future<void> install(String path) async => installs.add(path);
  @override
  Future<void> enableBackgroundChecks() async => backgroundEnabled++;
  @override
  Future<void> requestNotificationPermission() async => notificationRequests++;
  @override
  Stream<(InstallStatus, String?)> get installStatus => status.stream;
}

void main() {
  group('escolha da release', () {
    test('pega o build mais alto que tem APK', () {
      final apk = latestApk([
        release('build-4'),
        release('build-9'),
        release('build-7'),
      ]);
      expect(apk!.build, 9);
      expect(apk.assetUrl, 'https://example.com/build-9.apk');
      expect(apk.size, 1000);
    });

    test(
      'ignora tags de versão, rascunhos, pré-lançamentos e releases sem APK',
      () {
        final apk = latestApk([
          release('build-4'),
          release('v0.1.0'),
          release('build-10', draft: true),
          release('build-11', prerelease: true),
          release('build-12', apk: false),
        ]);
        expect(apk!.build, 4);
      },
    );

    test('sem nenhuma release válida devolve nada', () {
      expect(latestApk([release('v0.1.0'), 'lixo', 3]), isNull);
      expect(latestApk(const []), isNull);
    });
  });

  group('controlador', () {
    late Directory dir;
    late FakeSource source;
    late FakeDownloader downloader;
    late FakePlatform platform;
    late ProviderContainer container;

    UpdateController controller() =>
        container.read(updateControllerProvider.notifier);
    UpdateState state() => container.read(updateControllerProvider);
    Future<void> tick() => Future<void>.delayed(Duration.zero);

    const nova = ReleaseAsset(
      build: 7,
      tag: 'build-7',
      assetUrl: 'https://example.com/build-7.apk',
      size: 10,
      pageUrl: '',
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cdc-update-');
      source = FakeSource()..next = nova;
      downloader = FakeDownloader();
      platform = FakePlatform(dir.path);
      container = ProviderContainer(
        overrides: [
          updaterEnabledProvider.overrideWithValue(true),
          releaseSourceProvider.overrideWithValue(source),
          updateDownloaderProvider.overrideWithValue(downloader),
          updaterPlatformProvider.overrideWithValue(platform),
        ],
      );
      addTearDown(() {
        container.dispose();
        dir.deleteSync(recursive: true);
      });
      container.listen(updateControllerProvider, (_, _) {});
    });

    test('build mais novo que o instalado vira aviso de atualização', () async {
      await controller().check();
      expect(state().phase, UpdatePhase.available);
      expect(state().release!.build, 7);
      expect(state().installedBuild, 4);
    });

    test('mesmo build ou mais antigo: está atualizado', () async {
      platform.build = 7;
      await controller().check();
      expect(state().phase, UpdatePhase.upToDate);
    });

    test('sem internet não mostra erro, só não avisa nada', () async {
      source.error = const SocketException('sem rede');
      await controller().check();
      expect(state().phase, UpdatePhase.idle);
      expect(state().message, isNull);
    });

    test('fora do Android não procura', () async {
      final c = ProviderContainer(
        overrides: [
          updaterEnabledProvider.overrideWithValue(false),
          releaseSourceProvider.overrideWithValue(source),
          updaterPlatformProvider.overrideWithValue(platform),
        ],
      );
      addTearDown(c.dispose);
      await c.read(updateControllerProvider.notifier).check();
      expect(c.read(updateControllerProvider).phase, UpdatePhase.idle);
    });

    test('baixa, apaga APKs antigos e abre a instalação', () async {
      File('${dir.path}/ConectDroidCam-3.apk').writeAsStringSync('velho');
      await controller().check();
      await controller().download();
      expect(downloader.urls, [nova.assetUrl]);
      expect(platform.installs, ['${dir.path}/ConectDroidCam-7.apk']);
      expect(File('${dir.path}/ConectDroidCam-3.apk').existsSync(), isFalse);
      expect(state().phase, UpdatePhase.installing);
    });

    test('só pede a permissão de notificação ao atualizar', () async {
      await controller().check();
      await controller().enableBackgroundChecks();
      expect(platform.notificationRequests, 0);

      await controller().download();
      expect(platform.notificationRequests, 1);
    });

    test(
      'sem permissão para instalar, pede a permissão e instala depois',
      () async {
        platform.allowed = false;
        await controller().check();
        await controller().download();
        expect(state().phase, UpdatePhase.needsPermission);
        expect(platform.installs, isEmpty);

        await controller().openInstallSettings();
        expect(platform.settingsOpened, 1);

        platform.allowed = true;
        await controller().install();
        expect(platform.installs, hasLength(1));
      },
    );

    test('download que falha vira erro com explicação', () async {
      downloader.error = const HttpException('o download veio incompleto');
      await controller().check();
      await controller().download();
      expect(state().phase, UpdatePhase.failed);
      expect(state().message, contains('incompleto'));
      expect(platform.installs, isEmpty);
    });

    test(
      'assinatura diferente explica que é preciso reinstalar uma vez',
      () async {
        await controller().check();
        await controller().download();
        platform.status.add((InstallStatus.conflict, null));
        await tick();
        expect(state().phase, UpdatePhase.failed);
        expect(state().message, contains('Desinstale'));
      },
    );

    test('cancelar a instalação deixa tentar de novo', () async {
      await controller().check();
      await controller().download();
      platform.status.add((InstallStatus.aborted, null));
      await tick();
      expect(state().phase, UpdatePhase.ready);
      await controller().install();
      expect(platform.installs, hasLength(2));
    });

    test('liga a procura em segundo plano só no Android', () async {
      await controller().enableBackgroundChecks();
      expect(platform.backgroundEnabled, 1);

      final c = ProviderContainer(
        overrides: [
          updaterEnabledProvider.overrideWithValue(false),
          updaterPlatformProvider.overrideWithValue(platform),
        ],
      );
      addTearDown(c.dispose);
      await c.read(updateControllerProvider.notifier).enableBackgroundChecks();
      expect(platform.backgroundEnabled, 1);
    });

    test('instalação concluída some com o aviso', () async {
      await controller().check();
      await controller().download();
      platform.status.add((InstallStatus.success, null));
      await tick();
      expect(state().phase, UpdatePhase.upToDate);
    });
  });
}

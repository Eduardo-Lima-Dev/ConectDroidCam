import 'dart:io';

import 'package:conectdroidcam/features/setup/data/system_probe.dart';
import 'package:conectdroidcam/features/setup/domain/system_check.dart';
import 'package:flutter_test/flutter_test.dart';

SystemFacts facts({
  bool ffmpegOk = true,
  bool moduleLoaded = true,
  bool? secureBoot = false,
  bool hasDeviceFamily = true,
  bool hasLegacyDevice = false,
  bool? trayAvailable = true,
}) => SystemFacts(
  ffmpegOk: ffmpegOk,
  ffmpegHint: 'instale o ffmpeg',
  moduleLoaded: moduleLoaded,
  secureBoot: secureBoot,
  hasDeviceFamily: hasDeviceFamily,
  hasLegacyDevice: hasLegacyDevice,
  trayAvailable: trayAvailable,
  setupCommand: 'sudo bash setup.sh',
);

SystemCheck check(List<SystemCheck> all, String id) =>
    all.firstWhere((c) => c.id == id);

void main() {
  test('sistema pronto não tem problema que bloqueie', () {
    final all = evaluateSystem(facts());
    expect(hasBlockingProblem(all), isFalse);
    expect(check(all, 'modulo').command, isNull);
  });

  test('sem módulo e sem webcams, os dois pedem o comando de instalação', () {
    final all = evaluateSystem(
      facts(moduleLoaded: false, hasDeviceFamily: false),
    );
    expect(hasBlockingProblem(all), isTrue);
    expect(check(all, 'modulo').status, CheckStatus.problem);
    expect(check(all, 'modulo').command, 'sudo bash setup.sh');
    expect(check(all, 'webcams').status, CheckStatus.problem);
  });

  test('Secure Boot ligado sem módulo avisa sobre a assinatura', () {
    final all = evaluateSystem(facts(moduleLoaded: false, secureBoot: true));
    expect(check(all, 'secureboot').status, CheckStatus.warning);
    expect(check(all, 'secureboot').detail, contains('MOK'));
  });

  test('Secure Boot desconhecido não aparece', () {
    final all = evaluateSystem(facts(secureBoot: null));
    expect(all.where((c) => c.id == 'secureboot'), isEmpty);
  });

  test('webcam única antiga é só um aviso', () {
    final all = evaluateSystem(
      facts(hasDeviceFamily: false, hasLegacyDevice: true),
    );
    expect(check(all, 'webcams').status, CheckStatus.warning);
  });

  test('sem bandeja, explica a extensão do GNOME', () {
    final all = evaluateSystem(facts(trayAvailable: false));
    expect(check(all, 'bandeja').status, CheckStatus.warning);
    expect(check(all, 'bandeja').detail, contains('AppIndicator'));
    expect(
      evaluateSystem(
        facts(trayAvailable: null),
      ).where((c) => c.id == 'bandeja'),
      isEmpty,
    );
  });

  test('ffmpeg ausente usa o texto recebido', () {
    final all = evaluateSystem(facts(ffmpegOk: false));
    expect(check(all, 'ffmpeg').detail, 'instale o ffmpeg');
  });

  group('leitura do sistema', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('cdc-probe'));
    tearDown(() => root.deleteSync(recursive: true));

    test('módulo e Secure Boot', () {
      final probe = SystemProbe(root: root.path);
      expect(probe.moduleLoaded(), isFalse);
      expect(probe.secureBoot(), isNull);

      Directory(
        '${root.path}/sys/module/v4l2loopback',
      ).createSync(recursive: true);
      final efi = File(
        '${root.path}/sys/firmware/efi/efivars/'
        'SecureBoot-8be4df61-93ca-11d2-aa0d-e98032b8c39c',
      )..createSync(recursive: true);
      efi.writeAsBytesSync([6, 0, 0, 0, 1]);

      expect(probe.moduleLoaded(), isTrue);
      expect(probe.secureBoot(), isTrue);

      efi.writeAsBytesSync([6, 0, 0, 0, 0]);
      expect(probe.secureBoot(), isFalse);
    });
  });
}

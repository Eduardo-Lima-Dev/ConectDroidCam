@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conectdroidcam/features/receiver/data/rust_receiver_platform.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
import 'package:flutter_test/flutter_test.dart';

// Usa a ponte de verdade: carrega o núcleo em Rust, acha o emissor simulado pela rede (mDNS)
// e recebe vídeo dele. Precisa de `cargo build -p cdc-ffi -p cdc-testsender` e do ffmpeg;
// sem isso, os testes são pulados, não falham.

final _rust = Directory('../../rust/target/debug').absolute.path;
final _lib = File('$_rust/libcdc_ffi.so');
final _sender = File('$_rust/cdc-testsender');

String? _pular() {
  if (!_lib.existsSync() || !_sender.existsSync()) {
    return 'compile antes: cargo build -p cdc-ffi -p cdc-testsender (em rust/)';
  }
  if (Process.runSync('ffmpeg', ['-version']).exitCode != 0) {
    return 'ffmpeg não instalado';
  }
  return null;
}

/// Conecta como o app: se o celular pedir pareamento, o "usuário" confirma o código.
Stream<ReceiverUpdate> _connect(
  RustReceiverPlatform platform, {
  required String address,
  required String? videoDevice,
  ImageFormat format = ImageFormat.auto,
}) {
  return platform
      .connect(
        address: address,
        videoDevice: videoDevice,
        format: format,
        size: OutputSize.fullHd,
        shapeDevices: const [],
      )
      .map((update) {
        if (update is PairingCodeUpdate) {
          unawaited(platform.confirmPairing(true));
        }
        return update;
      });
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  final skip = _pular();
  late RustReceiverPlatform platform;

  setUpAll(() async {
    if (skip != null) return;
    platform = RustReceiverPlatform(libraryPath: _lib.path);
    await platform.init();
  });

  test(
    'acha o emissor pela rede e recebe o vídeo girado, até o fim',
    () async {
      final port = await _freePort();
      final name = 'Teste Dart $pid';
      final sender = await Process.start(_sender.path, [
        '--bind',
        '0.0.0.0', // como o celular: escuta em todas as interfaces
        '--auto-pair',
        '--port',
        '$port',
        '--rotation',
        '90',
        '--seconds',
        '4',
        '--advertise',
        name,
      ]);
      addTearDown(sender.kill);
      // Sem ler o stderr o processo pode travar quando o pipe enche.
      unawaited(sender.stderr.transform(utf8.decoder).drain());
      unawaited(sender.stdout.drain());

      // 1. Descoberta por mDNS.
      final found = Completer<Phone>();
      final sub = platform.discover().listen((change) {
        final phone = change.phone;
        if (phone != null && phone.name == name && !found.isCompleted) {
          found.complete(phone);
        }
      });
      final phone = await found.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () =>
            throw TestFailure('o emissor não apareceu na rede em 20 s'),
      );
      await sub.cancel();
      await platform.stopDiscovery();
      expect(phone.address, endsWith(':$port'));

      // 2. Conexão e recebimento. O dispositivo "null" decodifica e descarta o vídeo.
      final updates = await _connect(
        platform,
        address: phone.address,
        videoDevice: 'null',
        format: ImageFormat.auto,
      ).toList().timeout(const Duration(seconds: 30));

      expect(
        updates.last,
        isA<EndedUpdate>(),
        reason: updates.last is FailedUpdate
            ? (updates.last as FailedUpdate).message
            : null,
      );
      expect(
        updates.whereType<HelloUpdate>().single.deviceName,
        'cdc-testsender',
      );
      final profile = updates.whereType<ProfileUpdate>().first.video;
      expect(
        (profile.width, profile.height, profile.rotation),
        (1280, 720, 90),
      );
      final output = updates.whereType<OutputUpdate>().first.video;
      // Celular em pé e formato automático: a saída fica vertical, sem barras.
      expect((output.width, output.height, output.rotation), (1080, 1920, 90));
      // A prévia chega como JPEG válido (começa em FFD8 e termina em FFD9).
      final previews = updates.whereType<PreviewUpdate>().toList();
      expect(previews.length, greaterThan(10));
      expect(previews.first.jpeg.sublist(0, 2), [0xFF, 0xD8]);
      expect(previews.first.jpeg.sublist(previews.first.jpeg.length - 2), [
        0xFF,
        0xD9,
      ]);
      final stats = updates.whereType<StatsUpdate>().toList();
      expect(stats, isNotEmpty);
      expect(stats.last.stats.fps, inInclusiveRange(20, 40));
      expect(stats.last.stats.frames, greaterThan(60));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'formato vertical troca largura e altura da saída',
    () async {
      final port = await _freePort();
      final sender = await Process.start(_sender.path, [
        '--auto-pair',
        '--port',
        '$port',
        '--seconds',
        '3',
      ]);
      addTearDown(sender.kill);
      unawaited(sender.stderr.drain());
      unawaited(sender.stdout.drain());
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final updates = await _connect(
        platform,
        address: '127.0.0.1:$port',
        videoDevice: 'null',
        format: ImageFormat.vertical,
      ).toList().timeout(const Duration(seconds: 30));

      final output = updates.whereType<OutputUpdate>().first.video;
      expect((output.width, output.height), (1080, 1920));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('conectar a um celular que não existe explica o motivo', () async {
    final updates = await _connect(
      platform,
      address: '127.0.0.1:1',
      videoDevice: null,
      format: ImageFormat.auto,
    ).toList().timeout(const Duration(seconds: 15));

    final failed = updates.whereType<FailedUpdate>().single;
    expect(failed.message, contains('não consegui conectar'));
  }, skip: skip);

  test(
    'parar a sessão de outra parte a encerra',
    () async {
      final port = await _freePort();
      final sender = await Process.start(_sender.path, [
        '--auto-pair',
        '--port',
        '$port',
        '--seconds',
        '30',
      ]);
      addTearDown(sender.kill);
      unawaited(sender.stderr.drain());
      unawaited(sender.stdout.drain());
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final future = _connect(
        platform,
        address: '127.0.0.1:$port',
        videoDevice: null,
        format: ImageFormat.auto,
      ).toList();
      await Future<void>.delayed(const Duration(seconds: 2));
      await platform.disconnect();
      final updates = await future.timeout(const Duration(seconds: 10));

      expect(updates.last, isA<EndedUpdate>());
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('lista os dispositivos de vídeo sem falhar', () async {
    final devices = await platform.listVideoDevices();
    expect(devices.every((d) => d.path.startsWith('/dev/video')), isTrue);
  }, skip: skip);
}

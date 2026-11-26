import 'package:conectdroidcam/features/receiver/application/receiver_controller.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_receiver_platform.dart';

const pixel = Phone(
  id: 'ConectDroidCam Pixel._conectdroidcam._tcp.local.',
  name: 'ConectDroidCam Pixel',
  address: '192.168.0.7:47821',
);

void main() {
  late FakeReceiverPlatform platform;
  late FakeSettingsStore store;
  late ProviderContainer container;

  ReceiverController controller() =>
      container.read(receiverControllerProvider.notifier);
  ReceiverState state() => container.read(receiverControllerProvider);
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  setUp(() {
    platform = FakeReceiverPlatform();
    store = FakeSettingsStore();
    container = ProviderContainer(
      overrides: [
        receiverPlatformProvider.overrideWithValue(platform),
        receiverSettingsStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    container.listen(receiverControllerProvider, (_, _) {});
  });

  group('início', () {
    test(
      'carrega o núcleo, escolhe a webcam do ConectDroidCam e procura celulares',
      () async {
        await controller().start();

        expect(state().phase, ReceiverPhase.idle);
        expect(platform.initCalls, 1);
        expect(state().selectedDevice, ReceiverController.automaticDevice);
        expect(state().hasConectDroidCamDevice, isTrue);
        expect(state().ffmpegOk, isTrue);
      },
    );

    test('se o núcleo não carregar, explica e deixa tentar de novo', () async {
      platform.initError = StateError('libcdc_ffi.so ausente');

      await controller().start();

      expect(state().phase, ReceiverPhase.unavailable);
      expect(state().error, contains('libcdc_ffi.so'));

      platform.initError = null;
      await controller().start();
      expect(state().phase, ReceiverPhase.idle);
      expect(state().error, isNull);
    });

    test(
      'sem a webcam do ConectDroidCam, nenhum dispositivo é escolhido',
      () async {
        platform.devices = const [
          VideoDevice(path: '/dev/video0', name: 'Dummy video device (0x0000)'),
        ];

        await controller().start();

        expect(state().selectedDevice, isNull);
        expect(state().hasConectDroidCamDevice, isFalse);
      },
    );

    test('ffmpeg ausente é avisado', () async {
      platform.ffmpeg = false;

      await controller().start();

      expect(state().ffmpegOk, isFalse);
    });

    test(
      'falha ao procurar na rede não impede de conectar por endereço',
      () async {
        platform.discoverError = 'sem multicast';

        await controller().start();
        await tick();

        expect(state().discoveryError, contains('sem multicast'));
        expect(state().phase, ReceiverPhase.idle);
      },
    );
  });

  group('celulares na rede', () {
    setUp(() async {
      await controller().start();
    });

    test('aparece e some', () async {
      platform.phoneFound(pixel);
      await tick();
      expect(state().phones.map((p) => p.name), ['ConectDroidCam Pixel']);

      platform.phoneLost(pixel.id);
      await tick();
      expect(state().phones, isEmpty);
    });

    test('o mesmo celular com outro endereço não duplica', () async {
      platform.phoneFound(pixel);
      platform.phoneFound(
        const Phone(
          id: 'ConectDroidCam Pixel._conectdroidcam._tcp.local.',
          name: 'ConectDroidCam Pixel',
          address: '192.168.0.9:47821',
        ),
      );
      await tick();

      expect(state().phones, hasLength(1));
      expect(state().phones.single.address, '192.168.0.9:47821');
    });
  });

  group('conexão', () {
    setUp(() async {
      await controller().start();
    });

    test('conecta com o dispositivo e o formato escolhidos', () async {
      await controller().setFormat(ImageFormat.vertical);

      await controller().connect('192.168.0.7:47821', name: 'Pixel');

      expect(state().phase, ReceiverPhase.connecting);
      expect(platform.lastAddress, '192.168.0.7:47821');
      expect(platform.lastDevice, isNull);
      expect(platform.lastShapeDevices, hasLength(6));
      expect(
        platform.lastShapeDevices!.any(
          (d) =>
              d.vertical &&
              d.size == OutputSize.fullHd &&
              d.path == '/dev/video11',
        ),
        isTrue,
      );
      expect(platform.lastFormat, ImageFormat.vertical);
    });

    test(
      'mostra o que o celular entrega e a saída, e atualiza as estatísticas',
      () async {
        await controller().connect('192.168.0.7:47821');
        platform.send(
          const HelloUpdate(deviceName: '2201117SL', platform: 'android'),
        );
        platform.send(
          const ProfileUpdate(
            IncomingVideo(
              width: 1920,
              height: 1080,
              fps: 30,
              bitrateKbps: 6000,
              rotation: 90,
            ),
          ),
        );
        platform.send(
          const OutputUpdate(
            OutgoingVideo(width: 1920, height: 1080, rotation: 90),
          ),
        );
        platform.send(
          const StatsUpdate(
            LiveStats(fps: 29.8, kbps: 6800, delayMs: 12, frames: 300),
          ),
        );
        await tick();

        expect(state().phase, ReceiverPhase.connected);
        expect(state().phoneName, '2201117SL');
        expect(state().incoming?.rotation, 90);
        expect(state().outgoing?.width, 1920);
        expect(state().stats?.fps, 29.8);
      },
    );

    test('o celular girar chega como novo perfil, sem desconectar', () async {
      await controller().connect('192.168.0.7:47821');
      platform.send(
        const ProfileUpdate(
          IncomingVideo(
            width: 1280,
            height: 720,
            fps: 30,
            bitrateKbps: 3000,
            rotation: 0,
          ),
        ),
      );
      await tick();
      platform.send(
        const ProfileUpdate(
          IncomingVideo(
            width: 1280,
            height: 720,
            fps: 30,
            bitrateKbps: 3000,
            rotation: 90,
          ),
        ),
      );
      await tick();

      expect(state().phase, ReceiverPhase.connected);
      expect(state().incoming?.rotation, 90);
    });

    test('desconectar encerra e volta ao início', () async {
      await controller().connect('192.168.0.7:47821');
      platform.send(const HelloUpdate(deviceName: 'X', platform: 'android'));
      await tick();

      await controller().disconnect();
      await tick();

      expect(platform.disconnects, 1);
      expect(state().phase, ReceiverPhase.idle);
      expect(state().connectedTo, isNull);
      expect(state().stats, isNull);
    });

    test('o celular fechar a conexão volta ao início sem erro', () async {
      await controller().connect('192.168.0.7:47821');
      platform.send(const EndedUpdate());
      await tick();

      expect(state().phase, ReceiverPhase.idle);
      expect(state().error, isNull);
    });

    test('falha vira erro visível e libera para tentar de novo', () async {
      await controller().connect('192.168.0.7:47821');
      platform.send(
        const FailedUpdate('o ffmpeg parou: Device or resource busy'),
      );
      await tick();

      expect(state().phase, ReceiverPhase.idle);
      expect(state().error, contains('Device or resource busy'));

      await controller().connect('192.168.0.7:47821');
      expect(state().error, isNull);
      expect(state().phase, ReceiverPhase.connecting);
    });

    test(
      'o fluxo fechar sem Ended nem Failed não deixa a tela presa',
      () async {
        await controller().connect('192.168.0.7:47821');
        platform.send(const NoticeUpdate('algo'));
        await tick();
        expect(state().notice, 'algo');

        await platform.endSession();
        await tick();

        expect(state().phase, ReceiverPhase.idle);
        expect(state().error, contains('inesperada'));
      },
    );

    test('Ended seguido do fim do fluxo não vira erro', () async {
      await controller().connect('192.168.0.7:47821');

      platform.send(const EndedUpdate());
      await platform.endSession();
      await tick();

      expect(state().phase, ReceiverPhase.idle);
      expect(state().error, isNull);
    });

    test('endereço mal escrito é recusado antes de conectar', () async {
      for (final ruim in [
        'a b',
        '999.1.1.1',
        '[fe80::1',
        '192.168.0.7:',
        ':47821',
        '1.2.3.4:99999',
        '1.2.3.4:0',
      ]) {
        await controller().connect(ruim);
        expect(state().phase, ReceiverPhase.idle, reason: ruim);
        expect(state().error, contains('Endereço inválido'), reason: ruim);
      }
      expect(platform.lastAddress, isNull);
    });

    test('endereço sem porta usa a porta padrão do celular', () async {
      await controller().connect('192.168.0.7');

      expect(state().error, isNull);
      expect(platform.lastAddress, '192.168.0.7:47821');
    });

    test('fechar o erro limpa a mensagem', () async {
      await controller().connect('a b');
      expect(state().error, isNotNull);

      controller().dismissError();

      expect(state().error, isNull);
    });

    test('endereço vazio não faz nada', () async {
      await controller().connect('   ');

      expect(state().error, isNull);
      expect(platform.lastAddress, isNull);
    });

    test('sem ffmpeg não conecta a uma webcam virtual', () async {
      platform.ffmpeg = false;
      container.dispose();
      container = ProviderContainer(
        overrides: [
          receiverPlatformProvider.overrideWithValue(platform),
          receiverSettingsStoreProvider.overrideWithValue(store),
        ],
      );
      container.listen(receiverControllerProvider, (_, _) {});
      await controller().start();

      await controller().connect('192.168.0.7:47821');

      expect(state().error, contains('ffmpeg'));
      expect(platform.lastAddress, isNull);
    });

    test('sem dispositivo escolhido, conecta só para medir', () async {
      controller().selectDevice(null);

      await controller().connect('192.168.0.7:47821');

      expect(platform.lastDevice, isNull);
      expect(state().phase, ReceiverPhase.connecting);
    });

    test('não troca de dispositivo durante a conexão', () async {
      await controller().connect('192.168.0.7:47821');

      controller().selectDevice('/dev/video0');

      expect(state().selectedDevice, ReceiverController.automaticDevice);
    });

    test('uma segunda conexão enquanto há uma é ignorada', () async {
      await controller().connect('192.168.0.7:47821');
      final primeira = platform.lastAddress;

      await controller().connect('192.168.0.9:47821');

      expect(platform.lastAddress, primeira);
    });
  });

  group('prévia', () {
    setUp(() async {
      await controller().start();
    });

    test('o último quadro fica disponível e some ao desconectar', () async {
      await controller().connect('192.168.0.7:47821');
      platform.send(PreviewUpdate(Uint8List.fromList([1, 2, 3])));
      await tick();
      expect(container.read(previewFrameProvider), [1, 2, 3]);

      platform.send(const EndedUpdate());
      await tick();
      expect(container.read(previewFrameProvider), isNull);
    });

    test('um quadro novo não reconstrói o estado principal', () async {
      await controller().connect('192.168.0.7:47821');
      final antes = state();

      platform.send(PreviewUpdate(Uint8List.fromList([9])));
      await tick();

      expect(identical(state(), antes), isTrue);
    });
  });

  group('conexão automática', () {
    const outro = Phone(
      id: 'ConectDroidCam Galaxy._conectdroidcam._tcp.local.',
      name: 'ConectDroidCam Galaxy',
      address: '192.168.0.8:47821',
    );

    test(
      'na primeira vez não conecta sozinho e depois de pareado lembra o celular',
      () async {
        await controller().start();

        platform.phoneFound(pixel);
        await tick();
        expect(platform.connects, 0);
        expect(state().trustedPhones, isEmpty);

        await controller().connect(
          pixel.address,
          name: pixel.name,
          id: pixel.id,
        );
        platform.send(
          const HelloUpdate(deviceName: 'Pixel', platform: 'android'),
        );
        await tick();
        expect(state().trustedPhones, isEmpty);

        platform.send(const PairedUpdate('abc123'));
        await tick();

        expect(state().trustedPhones, {pixel.id});
        expect(store.settings.trustedPhones, {pixel.id});
        expect(store.settings.fingerprints, {pixel.id: 'abc123'});
      },
    );

    test('um celular já usado conecta sozinho assim que aparece', () async {
      store.settings = ReceiverSettings(trustedPhones: {pixel.id});
      await controller().start();

      platform.phoneFound(pixel);
      await tick();

      expect(platform.connects, 1);
      expect(platform.lastAddress, pixel.address);
      expect(state().phase, ReceiverPhase.connecting);
    });

    test('um celular desconhecido não conecta sozinho', () async {
      store.settings = ReceiverSettings(trustedPhones: {pixel.id});
      await controller().start();

      platform.phoneFound(outro);
      await tick();

      expect(platform.connects, 0);
    });

    test('com a opção desligada não conecta sozinho', () async {
      store.settings = ReceiverSettings(
        autoConnect: false,
        trustedPhones: {pixel.id},
      );
      await controller().start();

      platform.phoneFound(pixel);
      await tick();

      expect(platform.connects, 0);
    });

    test(
      'ligar a opção conecta a um celular usado que já está na lista',
      () async {
        store.settings = ReceiverSettings(
          autoConnect: false,
          trustedPhones: {pixel.id},
        );
        await controller().start();
        platform.phoneFound(pixel);
        await tick();
        expect(platform.connects, 0);

        await controller().setAutoConnect(true);
        await tick();

        expect(platform.connects, 1);
        expect(store.settings.autoConnect, isTrue);
      },
    );

    test(
      'não reconecta sozinho depois de o usuário desconectar, até o celular sair e voltar',
      () async {
        store.settings = ReceiverSettings(trustedPhones: {pixel.id});
        await controller().start();
        platform.phoneFound(pixel);
        await tick();
        platform.send(
          const HelloUpdate(deviceName: 'Pixel', platform: 'android'),
        );
        await tick();

        await controller().disconnect();
        await tick();
        expect(state().phase, ReceiverPhase.idle);

        platform.phoneFound(pixel);
        await tick();
        expect(platform.connects, 1);

        platform.phoneLost(pixel.id);
        await tick();
        platform.phoneFound(pixel);
        await tick();
        expect(platform.connects, 2);
      },
    );

    test(
      'quando o celular para a transmissão, não tenta de novo antes de ele sair e voltar',
      () async {
        store.settings = ReceiverSettings(trustedPhones: {pixel.id});
        await controller().start();
        platform.phoneFound(pixel);
        await tick();
        platform.send(
          const HelloUpdate(deviceName: 'Pixel', platform: 'android'),
        );
        await tick();

        platform.send(const EndedUpdate());
        await tick();
        platform.phoneFound(pixel);
        await tick();

        expect(platform.connects, 1);
        expect(state().error, isNull);
      },
    );

    test('uma falha não vira um laço de tentativas', () async {
      store.settings = ReceiverSettings(trustedPhones: {pixel.id});
      await controller().start();
      platform.phoneFound(pixel);
      await tick();
      platform.send(const FailedUpdate('conexão recusada'));
      await tick();

      for (var i = 0; i < 3; i++) {
        platform.phoneFound(pixel);
        await tick();
      }

      expect(platform.connects, 1);
      expect(state().error, contains('recusada'));
    });

    test('esquecer os celulares limpa a lista lembrada', () async {
      store.settings = ReceiverSettings(trustedPhones: {pixel.id});
      await controller().start();

      await controller().forgetPhones();

      expect(state().trustedPhones, isEmpty);
      expect(store.settings.trustedPhones, isEmpty);
    });
  });

  group('procurar de novo', () {
    test(
      'com a lista vazia, procura de novo sozinho depois de um tempo',
      () async {
        await controller().start();
        final buscas = platform.discoveries;

        await Future<void>.delayed(
          ReceiverController.rediscoverEvery +
              const Duration(milliseconds: 200),
        );

        expect(platform.discoveries, greaterThan(buscas));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'com um celular na lista, não reinicia a busca sozinho',
      () async {
        await controller().start();
        platform.phoneFound(pixel);
        await tick();
        final buscas = platform.discoveries;

        await Future<void>.delayed(
          ReceiverController.rediscoverEvery +
              const Duration(milliseconds: 200),
        );

        expect(platform.discoveries, buscas);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('o botão procura de novo na hora e limpa a lista', () async {
      await controller().start();
      platform.phoneFound(pixel);
      await tick();
      final buscas = platform.discoveries;

      await controller().rediscover();

      expect(platform.discoveries, buscas + 1);
      expect(state().phones, isEmpty);
    });
  });

  group('formato da imagem', () {
    setUp(() async {
      await controller().start();
    });

    test('o padrão é automático', () {
      expect(state().format, ImageFormat.auto);
    });

    test('a escolha é lembrada para a próxima vez', () async {
      await controller().setFormat(ImageFormat.vertical);

      expect(store.settings.format, ImageFormat.vertical);
    });

    test('a escolha salva volta quando o app abre de novo', () async {
      store.settings = const ReceiverSettings(format: ImageFormat.horizontal);
      container.dispose();
      container = ProviderContainer(
        overrides: [
          receiverPlatformProvider.overrideWithValue(platform),
          receiverSettingsStoreProvider.overrideWithValue(store),
        ],
      );
      container.listen(receiverControllerProvider, (_, _) {});
      await controller().start();

      expect(state().format, ImageFormat.horizontal);
    });

    test('conecta com o formato escolhido', () async {
      await controller().setFormat(ImageFormat.horizontal);

      await controller().connect('192.168.0.7:47821');

      expect(platform.lastFormat, ImageFormat.horizontal);
    });

    test('trocar o formato com o celular conectado reconecta a ele', () async {
      await controller().connect('192.168.0.7:47821', name: 'Pixel');
      platform.send(
        const HelloUpdate(deviceName: 'Pixel', platform: 'android'),
      );
      await tick();
      expect(platform.connects, 1);

      await controller().setFormat(ImageFormat.vertical);
      await tick();

      expect(platform.disconnects, 1);
      expect(platform.connects, 2);
      expect(platform.lastFormat, ImageFormat.vertical);
      expect(platform.lastAddress, '192.168.0.7:47821');
      expect(state().phase, ReceiverPhase.connecting);
      expect(state().error, isNull);
    });

    test('escolher o mesmo formato não reconecta', () async {
      await controller().connect('192.168.0.7:47821');

      await controller().setFormat(ImageFormat.auto);

      expect(platform.disconnects, 0);
      expect(platform.connects, 1);
    });

    test('a reconexão do formato não impede a automática depois', () async {
      store.settings = ReceiverSettings(trustedPhones: {pixel.id});
      container.dispose();
      container = ProviderContainer(
        overrides: [
          receiverPlatformProvider.overrideWithValue(platform),
          receiverSettingsStoreProvider.overrideWithValue(store),
        ],
      );
      container.listen(receiverControllerProvider, (_, _) {});
      await controller().start();
      platform.phoneFound(pixel);
      await tick();
      platform.send(
        const HelloUpdate(deviceName: 'Pixel', platform: 'android'),
      );
      await tick();

      await controller().setFormat(ImageFormat.vertical);
      await tick();
      expect(platform.connects, 2);

      platform.send(const EndedUpdate());
      await tick();
      platform.phoneLost(pixel.id);
      await tick();
      platform.phoneFound(pixel);
      await tick();
      expect(platform.connects, 3);
    });
  });

  group('tamanho da saída', () {
    setUp(() async {
      await controller().start();
    });

    test('o padrão é Full HD, independente do celular', () {
      expect(state().outputSize, OutputSize.fullHd);
    });

    test('a escolha é lembrada e usada ao conectar', () async {
      await controller().setOutputSize(OutputSize.qhd);
      expect(store.settings.outputSize, OutputSize.qhd);

      await controller().connect('192.168.0.7:47821');

      expect(platform.lastSize, OutputSize.qhd);
    });

    test('trocar o tamanho com o celular conectado reconecta a ele', () async {
      await controller().connect('192.168.0.7:47821', name: 'Pixel');
      platform.send(
        const HelloUpdate(deviceName: 'Pixel', platform: 'android'),
      );
      await tick();

      await controller().setOutputSize(OutputSize.hd);
      await tick();

      expect(platform.disconnects, 1);
      expect(platform.connects, 2);
      expect(platform.lastSize, OutputSize.hd);
    });

    test('a escolha salva volta quando o app abre de novo', () async {
      store.settings = const ReceiverSettings(outputSize: OutputSize.hd);
      container.dispose();
      container = ProviderContainer(
        overrides: [
          receiverPlatformProvider.overrideWithValue(platform),
          receiverSettingsStoreProvider.overrideWithValue(store),
        ],
      );
      container.listen(receiverControllerProvider, (_, _) {});
      await controller().start();

      expect(state().outputSize, OutputSize.hd);
    });

    test('os nomes mostram a resolução e o 2K nunca aparece sozinho', () {
      expect(OutputSize.hd.label, 'HD (1280×720)');
      expect(OutputSize.fullHd.label, 'Full HD (1920×1080)');
      expect(OutputSize.qhd.label, '2K (2560×1440)');
      expect(OutputSize.hd.name, 'hd');
    });
  });

  group('webcams por tamanho e formato', () {
    test('lê o tamanho e o formato pelo nome da webcam', () {
      const d = VideoDevice(
        path: '/dev/video13',
        name: 'ConectDroidCam HD Vertical',
      );
      expect(d.shape?.size, OutputSize.hd);
      expect(d.shape?.vertical, isTrue);
      expect(d.shape?.path, '/dev/video13');
      expect(
        const VideoDevice(
          path: '/dev/video14',
          name: 'ConectDroidCam 2K Horizontal',
        ).shape?.size,
        OutputSize.qhd,
      );
      expect(
        const VideoDevice(
          path: '/dev/video10',
          name: 'ConectDroidCam FHD Horizontal',
        ).shape?.vertical,
        isFalse,
      );
    });

    test(
      'a webcam única das versões anteriores e as comuns não têm formato',
      () {
        expect(
          const VideoDevice(path: '/dev/video10', name: 'ConectDroidCam').shape,
          isNull,
        );
        expect(
          const VideoDevice(
            path: '/dev/video0',
            name: 'Dummy video device (0x0000)',
          ).shape,
          isNull,
        );
      },
    );

    test(
      'só com a webcam única antiga, escolhe ela e conecta sem a família',
      () async {
        platform.devices = const [
          VideoDevice(path: '/dev/video0', name: 'Dummy video device (0x0000)'),
          VideoDevice(path: '/dev/video10', name: 'ConectDroidCam'),
        ];
        await controller().start();

        expect(state().selectedDevice, '/dev/video10');
        expect(state().hasDeviceFamily, isFalse);

        await controller().connect('192.168.0.7:47821');

        expect(platform.lastDevice, '/dev/video10');
        expect(platform.lastShapeDevices, isEmpty);
      },
    );

    test('escolher um dispositivo à mão conecta só nele', () async {
      await controller().start();
      controller().selectDevice('/dev/video12');

      await controller().connect('192.168.0.7:47821');

      expect(platform.lastDevice, '/dev/video12');
      expect(platform.lastShapeDevices, isEmpty);
    });

    test(
      'a escolha automática continua valendo depois de atualizar a lista',
      () async {
        await controller().start();

        await controller().refreshDevices();

        expect(state().selectedDevice, ReceiverController.automaticDevice);
      },
    );

    test('se a família sumir, a escolha automática deixa de valer', () async {
      await controller().start();
      platform.devices = const [
        VideoDevice(path: '/dev/video0', name: 'Dummy video device (0x0000)'),
      ];

      await controller().refreshDevices();

      expect(state().selectedDevice, isNull);
    });
  });
}

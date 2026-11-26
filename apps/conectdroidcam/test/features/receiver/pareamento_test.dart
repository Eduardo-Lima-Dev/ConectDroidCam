import 'package:conectdroidcam/features/receiver/application/receiver_controller.dart';
import 'package:conectdroidcam/features/receiver/domain/receiver_models.dart';
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

  Future<void> iniciar([ReceiverSettings? settings]) async {
    platform = FakeReceiverPlatform();
    store = FakeSettingsStore(settings ?? const ReceiverSettings());
    container = ProviderContainer(
      overrides: [
        receiverPlatformProvider.overrideWithValue(platform),
        receiverSettingsStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    container.listen(receiverControllerProvider, (_, _) {});
    await controller().start();
  }

  test(
    'celular novo: conecta sem impressão fixada e mostra o código',
    () async {
      await iniciar();
      await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
      expect(platform.lastPinned, isNull);

      platform.send(
        const PairingCodeUpdate(code: '482913', phoneFingerprint: 'fp-celular'),
      );
      await tick();
      expect(state().pairing!.code, '482913');
    },
  );

  test('confirmar manda a resposta e guarda a impressão ao parear', () async {
    await iniciar();
    await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
    platform.send(
      const PairingCodeUpdate(code: '482913', phoneFingerprint: 'fp-celular'),
    );
    await tick();

    await controller().confirmPairing(true);
    expect(platform.pairingAnswers, [true]);

    platform.send(const PairedUpdate('fp-celular'));
    await tick();
    expect(state().pairing, isNull);
    expect(state().fingerprints, {pixel.id: 'fp-celular'});
    expect(store.settings.fingerprints, {pixel.id: 'fp-celular'});
    expect(state().trustedPhones, {pixel.id});
  });

  test('"não é o mesmo" recusa, fecha a tela e desconecta', () async {
    await iniciar();
    await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
    platform.send(
      const PairingCodeUpdate(code: '482913', phoneFingerprint: 'fp-celular'),
    );
    await tick();

    await controller().confirmPairing(false);
    await tick();
    expect(platform.pairingAnswers, [false]);
    expect(state().pairing, isNull);
    expect(platform.disconnects, greaterThan(0));
    expect(state().fingerprints, isEmpty);
  });

  test('celular que recusa o pareamento mostra o motivo', () async {
    await iniciar();
    await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
    platform.send(
      const PairingCodeUpdate(code: '482913', phoneFingerprint: 'fp-celular'),
    );
    platform.send(const PairingDeniedUpdate('recusado no celular'));
    await tick();
    expect(state().pairing, isNull);
    expect(state().error, contains('recusado no celular'));
  });

  test('celular já pareado conecta com a impressão registrada', () async {
    await iniciar(
      ReceiverSettings(
        trustedPhones: {pixel.id},
        fingerprints: {pixel.id: 'fp-celular'},
      ),
    );
    await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
    expect(platform.lastPinned, 'fp-celular');
  });

  test('endereço digitado é lembrado pelo endereço', () async {
    await iniciar();
    await controller().connect('10.0.0.9:47821');
    platform.send(const PairedUpdate('fp-x'));
    await tick();
    expect(state().fingerprints, {'addr:10.0.0.9:47821': 'fp-x'});
    await controller().disconnect();
    await tick();
    await controller().connect('10.0.0.9:47821');
    expect(platform.lastPinned, 'fp-x');
  });

  test('desparear faz o celular voltar a pedir o código', () async {
    await iniciar(
      ReceiverSettings(
        trustedPhones: {pixel.id},
        fingerprints: {pixel.id: 'fp-celular'},
      ),
    );
    await controller().unpair(pixel.id);
    expect(state().fingerprints, isEmpty);
    expect(state().trustedPhones, isEmpty);
    await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
    expect(platform.lastPinned, isNull);
  });

  test('esquecer os celulares apaga também as impressões', () async {
    await iniciar(
      ReceiverSettings(
        trustedPhones: {pixel.id},
        fingerprints: {pixel.id: 'fp-celular'},
      ),
    );
    await controller().forgetPhones();
    expect(store.settings.fingerprints, isEmpty);
  });

  test('o nome do celular pareado é guardado e apagado junto', () async {
    await iniciar();
    await controller().connect(pixel.address, name: pixel.name, id: pixel.id);
    platform.send(const PairedUpdate('fp-celular'));
    await tick();
    expect(store.settings.phoneNames, {pixel.id: pixel.name});

    await controller().unpair(pixel.id);
    expect(store.settings.phoneNames, isEmpty);
  });

  group('nome mostrado de um celular pareado', () {
    test('usa o nome guardado', () {
      expect(pairedPhoneLabel('k', {'k': 'Pixel 8'}), 'Pixel 8');
    });

    test('sem nome guardado, limpa o nome do serviço mDNS', () {
      expect(
        pairedPhoneLabel(
          'ConectDroidCam\\0322201117SL._conectdroidcam._tcp.local.',
          const {},
        ),
        '2201117SL',
      );
    });

    test('endereço digitado mostra o endereço', () {
      expect(
        pairedPhoneLabel('addr:10.0.0.9:47821', const {}),
        '10.0.0.9:47821',
      );
    });
  });

  group('endereço digitado', () {
    test('completa a porta e aceita IPv6', () {
      expect(normalizeAddress('192.168.0.7'), '192.168.0.7:47821');
      expect(normalizeAddress(' 192.168.0.7:5000 '), '192.168.0.7:5000');
      expect(normalizeAddress('pixel.local'), 'pixel.local:47821');
      expect(normalizeAddress('fe80::1'), '[fe80::1]:47821');
      expect(normalizeAddress('[fe80::1]'), '[fe80::1]:47821');
      expect(normalizeAddress('[fe80::1%wlan0]:5000'), '[fe80::1%wlan0]:5000');
    });

    test('recusa o que não é endereço', () {
      for (final ruim in [
        '',
        'a b',
        '1.2.3',
        '256.1.1.1',
        '1.2.3.4:0',
        '1.2.3.4:70000',
        '[fe80::1',
        '[fe80::1]x',
        '-pixel',
      ]) {
        expect(normalizeAddress(ruim), isNull, reason: ruim);
      }
    });
  });

  test('celular de IP novo é reconhecido pela impressão digital', () async {
    await iniciar(
      const ReceiverSettings(
        trustedPhones: {'addr:10.0.0.9:47821'},
        fingerprints: {'addr:10.0.0.9:47821': 'fp-celular'},
        phoneNames: {'addr:10.0.0.9:47821': 'Pixel 8'},
      ),
    );
    await controller().connect('10.0.0.23');
    expect(platform.lastPinned, isNull);

    platform.send(const PhoneIdentityUpdate('fp-celular'));
    await tick();

    expect(store.settings.trustedPhones, {'addr:10.0.0.23:47821'});
    expect(store.settings.fingerprints, {'addr:10.0.0.23:47821': 'fp-celular'});
    expect(store.settings.phoneNames, {'addr:10.0.0.23:47821': 'Pixel 8'});
  });

  test('impressão digital desconhecida não vira pareamento', () async {
    await iniciar(
      const ReceiverSettings(
        trustedPhones: {'addr:10.0.0.9:47821'},
        fingerprints: {'addr:10.0.0.9:47821': 'fp-celular'},
      ),
    );
    await controller().connect('10.0.0.23');

    platform.send(const PhoneIdentityUpdate('fp-outro'));
    await tick();

    expect(store.settings.trustedPhones, {'addr:10.0.0.9:47821'});
  });

  test(
    'celular achado na rede mantém a chave dele e herda o pareamento',
    () async {
      await iniciar(
        const ReceiverSettings(
          trustedPhones: {'addr:10.0.0.9:47821'},
          fingerprints: {'addr:10.0.0.9:47821': 'fp-celular'},
        ),
      );
      await controller().connect(pixel.address, name: pixel.name, id: pixel.id);

      platform.send(const PhoneIdentityUpdate('fp-celular'));
      await tick();

      expect(store.settings.trustedPhones, {pixel.id});
      expect(store.settings.fingerprints[pixel.id], 'fp-celular');
    },
  );
}

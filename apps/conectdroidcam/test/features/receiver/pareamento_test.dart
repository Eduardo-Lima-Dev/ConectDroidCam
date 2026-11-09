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
}

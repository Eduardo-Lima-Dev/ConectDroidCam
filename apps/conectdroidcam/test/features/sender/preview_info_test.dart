import 'package:conectdroidcam/features/sender/domain/sender_models.dart';
import 'package:flutter_test/flutter_test.dart';

PreviewInfo preview({int sensor = 90, int rotation = 0}) => PreviewInfo(
  textureId: 1,
  width: 1280,
  height: 720,
  sensorOrientation: sensor,
  displayRotation: rotation,
);

void main() {
  group('proporção da textura', () {
    test('sensor girado 90° entrega a textura em retrato (9:16)', () {
      expect(preview(sensor: 90).textureAspectRatio, closeTo(9 / 16, 1e-9));
      expect(preview(sensor: 270).textureAspectRatio, closeTo(9 / 16, 1e-9));
    });

    test('sensor sem giro entrega a textura em paisagem (16:9)', () {
      expect(preview(sensor: 0).textureAspectRatio, closeTo(16 / 9, 1e-9));
      expect(preview(sensor: 180).textureAspectRatio, closeTo(16 / 9, 1e-9));
    });

    test('tamanho zero não gera divisão por zero', () {
      const vazio = PreviewInfo(textureId: 1, width: 0, height: 0);
      expect(vazio.textureAspectRatio, closeTo(16 / 9, 1e-9));
    });
  });

  group('giro da tela', () {
    test('em retrato não gira', () {
      expect(preview(rotation: 0).quarterTurns, 0);
    });

    test(
      'paisagem para a esquerda gira 90° anti-horário (3 giros horários)',
      () {
        expect(preview(rotation: 1).quarterTurns, 3);
      },
    );

    test('de cabeça para baixo gira 180°', () {
      expect(preview(rotation: 2).quarterTurns, 2);
    });

    test('paisagem para a direita gira 90° horário', () {
      expect(preview(rotation: 3).quarterTurns, 1);
    });
  });

  test('uma textura 9:16 girada fica 16:9 na tela', () {
    // Como o RotatedBox troca largura e altura, o resultado em paisagem é o inverso.
    final info = preview(sensor: 90, rotation: 1);
    expect(info.quarterTurns.isOdd, isTrue);
    expect(1 / info.textureAspectRatio, closeTo(16 / 9, 1e-9));
  });
}

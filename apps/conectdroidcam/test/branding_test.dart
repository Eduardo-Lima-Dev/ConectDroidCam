import 'dart:io';

import 'package:conectdroidcam/shared/widgets/brand_logo.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Largura, altura e tipo de cor de um PNG, lidos do cabeçalho (IHDR).
({int width, int height, int colorType}) lerPng(Uint8List bytes) {
  const assinatura = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  expect(bytes.sublist(0, 8), assinatura, reason: 'não é um PNG');
  final dados = ByteData.sublistView(bytes);
  return (
    width: dados.getUint32(16),
    height: dados.getUint32(20),
    // 2 = RGB, 6 = RGBA (com transparência).
    colorType: bytes[25],
  );
}

({int width, int height, int colorType}) png(String caminho) {
  final arquivo = File(caminho);
  expect(arquivo.existsSync(), isTrue, reason: 'faltando: $caminho');
  return lerPng(arquivo.readAsBytesSync());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a logo e o ícone da janela estão empacotados como assets', () async {
    final logo = await rootBundle.load(BrandLogo.asset);
    final icone = await rootBundle.load('assets/branding/app_icon.png');

    expect(lerPng(logo.buffer.asUint8List()).width, 512);
    expect(lerPng(icone.buffer.asUint8List()).width, 256);
  });

  group('Android', () {
    const res = 'android/app/src/main/res';
    const densidades = {
      'mdpi': 1.0,
      'hdpi': 1.5,
      'xhdpi': 2.0,
      'xxhdpi': 3.0,
      'xxxhdpi': 4.0,
    };

    test('ícone clássico, adaptativo e monocromático em cada densidade', () {
      densidades.forEach((nome, escala) {
        expect(
          png('$res/mipmap-$nome/ic_launcher.png').width,
          (48 * escala).round(),
        );
        expect(
          png('$res/mipmap-$nome/ic_launcher_foreground.png').width,
          (108 * escala).round(),
        );
        expect(
          png('$res/mipmap-$nome/ic_launcher_monochrome.png').width,
          (108 * escala).round(),
        );
      });
    });

    test(
      'ícone de notificação de 24 dp em cada densidade, com transparência',
      () {
        densidades.forEach((nome, escala) {
          final icone = png('$res/drawable-$nome/ic_stat_cdc.png');
          expect(icone.width, (24 * escala).round());
          expect(icone.colorType, 6, reason: 'precisa de canal alfa');
        });
      },
    );

    test(
      'o ícone adaptativo aponta para o primeiro plano e o monocromático',
      () {
        final xml = File(
          '$res/mipmap-anydpi-v26/ic_launcher.xml',
        ).readAsStringSync();
        expect(xml, contains('@color/ic_launcher_background'));
        expect(xml, contains('@mipmap/ic_launcher_foreground'));
        expect(xml, contains('@mipmap/ic_launcher_monochrome'));
      },
    );

    test('o manifesto usa o ícone e o nome certos', () {
      final manifesto = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifesto, contains('android:icon="@mipmap/ic_launcher"'));
      expect(manifesto, contains('android:label="ConectDroidCam"'));
    });
  });

  group('iOS', () {
    test('nenhum ícone tem transparência, que a Apple rejeita', () {
      final pasta = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
      final icones = pasta
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      expect(icones, isNotEmpty);
      for (final arquivo in icones) {
        expect(
          lerPng(arquivo.readAsBytesSync()).colorType,
          2,
          reason: '${arquivo.path} tem canal alfa',
        );
      }
    });

    test('o ícone da loja tem 1024 px', () {
      final icone = png(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
      );
      expect((icone.width, icone.height), (1024, 1024));
    });
  });

  test('macOS tem todos os tamanhos do ícone', () {
    for (final px in [16, 32, 64, 128, 256, 512, 1024]) {
      final icone = png(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$px.png',
      );
      expect((icone.width, icone.height), (px, px));
    }
  });
}

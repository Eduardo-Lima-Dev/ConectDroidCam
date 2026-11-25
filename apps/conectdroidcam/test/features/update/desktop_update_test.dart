import 'package:conectdroidcam/features/update/application/desktop_update_controller.dart';
import 'package:conectdroidcam/features/update/application/update_controller.dart';
import 'package:conectdroidcam/features/update/data/update_sources.dart';
import 'package:conectdroidcam/features/update/domain/update_models.dart';
import 'package:conectdroidcam/features/update/presentation/desktop_update_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSource implements ReleaseSource {
  ReleaseAsset? next;
  Object? error;
  final List<String> suffixes = [];

  @override
  Future<ReleaseAsset?> latest({String suffix = '.apk'}) async {
    suffixes.add(suffix);
    if (error != null) throw error!;
    return next;
  }
}

const release9 = ReleaseAsset(
  build: 9,
  tag: 'build-9',
  assetUrl: 'https://example.com/ConectDroidCam-9.flatpak',
  size: 100,
  pageUrl: '',
);

void main() {
  late FakeSource source;

  ProviderContainer container({bool enabled = true, int build = 7}) {
    final c = ProviderContainer(
      overrides: [
        desktopUpdateEnabledProvider.overrideWithValue(enabled),
        desktopBuildProvider.overrideWithValue(build),
        releaseSourceProvider.overrideWithValue(source),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => source = FakeSource()..next = release9);

  test('release mais nova que o build instalado vira aviso', () async {
    final c = container();
    await c.read(desktopUpdateProvider.notifier).check();
    expect(c.read(desktopUpdateProvider)?.build, 9);
    expect(source.suffixes, ['.flatpak']);
  });

  test('mesmo build: nada a avisar', () async {
    final c = container(build: 9);
    await c.read(desktopUpdateProvider.notifier).check();
    expect(c.read(desktopUpdateProvider), isNull);
  });

  test('fora do Flatpak de uma release, nem procura', () async {
    final c = container(enabled: false);
    await c.read(desktopUpdateProvider.notifier).check();
    expect(c.read(desktopUpdateProvider), isNull);
    expect(source.suffixes, isEmpty);
  });

  test('sem internet, não avisa e não quebra', () async {
    source.error = Exception('sem rede');
    final c = container();
    await c.read(desktopUpdateProvider.notifier).check();
    expect(c.read(desktopUpdateProvider), isNull);
  });

  test('fechar o aviso o esconde', () async {
    final c = container();
    await c.read(desktopUpdateProvider.notifier).check();
    c.read(desktopUpdateProvider.notifier).dismiss();
    expect(c.read(desktopUpdateProvider), isNull);
  });

  testWidgets('o aviso mostra o build e o comando de atualizar', (
    tester,
  ) async {
    final c = container();
    await c.read(desktopUpdateProvider.notifier).check();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: DesktopUpdateBanner())),
      ),
    );
    expect(find.text('Nova versão disponível (build 9)'), findsOneWidget);
    expect(find.text(desktopUpdateCommand), findsOneWidget);

    await tester.tap(find.byTooltip('Fechar'));
    await tester.pump();
    expect(find.textContaining('Nova versão'), findsNothing);
  });
}

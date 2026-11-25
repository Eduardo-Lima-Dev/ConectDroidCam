import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/brand_logo.dart';
import '../application/receiver_controller.dart';
import '../domain/receiver_models.dart';
import '../../update/application/desktop_update_controller.dart';
import '../../update/presentation/desktop_update_banner.dart';

class ReceiverPage extends ConsumerStatefulWidget {
  const ReceiverPage({super.key});

  @override
  ConsumerState<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends ConsumerState<ReceiverPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(receiverControllerProvider.notifier).start();
      ref.read(desktopUpdateProvider.notifier).check();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(receiverControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: switch (state.phase) {
              ReceiverPhase.starting => const Center(
                child: CircularProgressIndicator(),
              ),
              ReceiverPhase.unavailable => _Unavailable(state: state),
              _ => _Content(state: state),
            },
          ),
        ),
      ),
    );
  }
}

class _Unavailable extends ConsumerWidget {
  const _Unavailable({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandLogo(size: 96),
          const SizedBox(height: 16),
          Text(
            'O app não conseguiu iniciar',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          SelectableText(
            state.error ?? 'Erro desconhecido.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: ref.read(receiverControllerProvider.notifier).start,
            child: const Text('Tentar de novo'),
          ),
        ],
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const BrandLogo(size: 48),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ConectDroidCam', style: theme.textTheme.headlineSmall),
                  Text(
                    'Use a câmera do celular como webcam',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (state.error != null)
          _Banner(
            icon: Icons.error_outline,
            text: state.error!,
            color: theme.colorScheme.errorContainer,
            onColor: theme.colorScheme.onErrorContainer,
          ),
        if (state.notice != null)
          _Banner(
            icon: Icons.info_outline,
            text: state.notice!,
            color: theme.colorScheme.secondaryContainer,
            onColor: theme.colorScheme.onSecondaryContainer,
          ),
        if (!state.ffmpegOk)
          _Banner(
            icon: Icons.warning_amber_outlined,
            text:
                'O ffmpeg não está instalado. Instale o pacote "ffmpeg" da sua '
                'distribuição: ele decodifica o vídeo e escreve na webcam virtual.',
            color: theme.colorScheme.errorContainer,
            onColor: theme.colorScheme.onErrorContainer,
          ),
        if (state.pairing != null) ...[
          _PairingCard(state: state),
          const SizedBox(height: 16),
        ],
        const DesktopUpdateBanner(),
        _StatusBar(state: state),
        const SizedBox(height: 16),
        _PhoneCard(state: state),
        const SizedBox(height: 16),
        _OutputCard(state: state),
        const SizedBox(height: 16),
        Text(
          'A conexão é criptografada (TLS). Na primeira vez, confira o código de '
          'pareamento nas duas telas; depois, só o celular pareado é aceito.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.color,
    required this.onColor,
  });

  final IconData icon;
  final String text;
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: onColor, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(text, style: TextStyle(color: onColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _PhoneCard extends ConsumerWidget {
  const _PhoneCard({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SectionCard(
      title: state.isBusy ? 'Celular conectado' : 'Celular',
      child: state.isBusy ? _Connected(state: state) : _Finder(state: state),
    );
  }
}

class _Finder extends ConsumerStatefulWidget {
  const _Finder({required this.state});

  final ReceiverState state;

  @override
  ConsumerState<_Finder> createState() => _FinderState();
}

class _FinderState extends ConsumerState<_Finder> {
  final _address = TextEditingController();

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ref.read(receiverControllerProvider.notifier);
    final phones = widget.state.phones;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (phones.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.state.discoveryError ??
                  'Nenhum celular encontrado. No celular, abra o ConectDroidCam e '
                      'toque em "Iniciar transmissão". Ele aparece aqui sozinho '
                      'quando estiver na mesma rede.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final phone in phones)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smartphone),
              title: Text(phone.name),
              subtitle: Text(
                widget.state.trustedPhones.contains(phone.id)
                    ? '${phone.address} · já usado antes'
                    : phone.address,
              ),
              trailing: FilledButton(
                onPressed: () => controller.connect(
                  phone.address,
                  name: phone.name,
                  id: phone.id,
                ),
                child: const Text('Conectar'),
              ),
            ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Conectar sozinho aos celulares já usados'),
          subtitle: const Text(
            'Depois da primeira conexão, o celular conecta assim que aparecer na rede. '
            'Não é uma proteção: sem pareamento, outro aparelho pode usar o mesmo nome.',
          ),
          value: widget.state.autoConnect,
          onChanged: controller.setAutoConnect,
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: controller.rediscover,
              icon: const Icon(Icons.refresh),
              label: const Text('Procurar de novo'),
            ),
            if (widget.state.trustedPhones.isNotEmpty)
              TextButton.icon(
                onPressed: controller.forgetPhones,
                icon: const Icon(Icons.delete_outline),
                label: Text(
                  'Esquecer celulares pareados (${widget.state.trustedPhones.length})',
                ),
              ),
          ],
        ),
        const Divider(height: 24),
        Text(
          'Ou digite o endereço mostrado no celular',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('endereco'),
                controller: _address,
                decoration: const InputDecoration(
                  hintText: '192.168.0.7:47821',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => controller.connect(v),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => controller.connect(_address.text),
              child: const Text('Conectar'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PairingCard extends ConsumerWidget {
  const _PairingCard({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(receiverControllerProvider.notifier);
    final prompt = state.pairing!;
    final code = '${prompt.code.substring(0, 3)} ${prompt.code.substring(3)}';
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Parear com ${state.phoneName ?? 'o celular'}',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Confira se este código é o mesmo que aparece no celular. '
              'Se for diferente, alguém pode estar no meio da conexão: toque em '
              '"Não é o mesmo".',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: SelectableText(
                code,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 6,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => controller.confirmPairing(true),
                  icon: const Icon(Icons.check),
                  label: const Text('É o mesmo'),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.confirmPairing(false),
                  icon: const Icon(Icons.close),
                  label: const Text('Não é o mesmo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Connected extends ConsumerWidget {
  const _Connected({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(receiverControllerProvider.notifier);
    final connecting = state.phase == ReceiverPhase.connecting;
    final incoming = state.incoming;
    final outgoing = state.outgoing;
    final stats = state.stats;
    final lines = <String>[
      if (state.connectedTo != null) 'Endereço: ${state.connectedTo}',
      if (state.phonePlatform != null) 'Sistema: ${state.phonePlatform}',
      if (incoming != null)
        'Recebendo ${incoming.width}×${incoming.height} a ${incoming.fps} FPS',
      if (incoming != null && incoming.rotation != 0)
        'Imagem girada ${incoming.rotation}° para ficar em pé',
      if (outgoing != null)
        'Saída: ${outgoing.width}×${outgoing.height}'
            '${outgoing.device != null ? ' em ${_deviceLabel(state, outgoing.device!)}' : ' (sem webcam virtual)'}',
      if (stats != null)
        '${stats.fps.toStringAsFixed(1)} FPS · ${stats.kbps.round()} kb/s · '
            'atraso da rede ${stats.delayMs.round()} ms',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.circle,
              size: 10,
              color: connecting ? Colors.amberAccent : Colors.greenAccent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                connecting
                    ? 'Conectando a ${state.connectedTo}…'
                    : 'Conectado a ${state.phoneName ?? state.connectedTo}',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PreviewBox(state: state),
        if (lines.isNotEmpty) const SizedBox(height: 12),
        for (final line in lines) Text(line, style: theme.textTheme.bodyMedium),
        if (state.capabilities != null) ...[
          const SizedBox(height: 14),
          _PhoneControls(state: state),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: controller.disconnect,
          icon: const Icon(Icons.link_off),
          label: const Text('Desconectar'),
        ),
      ],
    );
  }
}

class _PhoneControls extends ConsumerWidget {
  const _PhoneControls({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(receiverControllerProvider.notifier);
    final caps = state.capabilities!;
    final streaming = caps.streaming;
    final mode = state.remoteMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Controle do celular', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (streaming)
              FilledButton.tonalIcon(
                onPressed: controller.stopPhoneStream,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Parar transmissão'),
              )
            else
              FilledButton.icon(
                onPressed: mode == null ? null : controller.startPhoneStream,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Iniciar transmissão'),
              ),
            if (caps.canSwitch)
              OutlinedButton.icon(
                onPressed: controller.switchPhoneCamera,
                icon: const Icon(Icons.cameraswitch_outlined),
                label: Text(
                  caps.front
                      ? 'Usar a câmera traseira'
                      : 'Usar a câmera frontal',
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownMenu<PhoneMode>(
              key: ValueKey('mode-${mode?.label}'),
              label: const Text('Resolução'),
              initialSelection: mode,
              dropdownMenuEntries: [
                for (final m in caps.modes)
                  DropdownMenuEntry(
                    value: m,
                    label: m.label,
                    enabled: m.available,
                    trailingIcon: m.available
                        ? null
                        : Tooltip(
                            message: m.reason ?? 'Indisponível neste celular',
                            child: const Icon(Icons.info_outline, size: 18),
                          ),
                  ),
              ],
              onSelected: (m) {
                if (m != null) controller.selectRemoteMode(m);
              },
            ),
            DropdownMenu<int>(
              key: ValueKey('fps-${state.remoteFps}'),
              label: const Text('Quadros por segundo'),
              initialSelection: state.remoteFps,
              dropdownMenuEntries: [
                for (final f in caps.fpsOptions)
                  DropdownMenuEntry(
                    value: f,
                    label: '$f FPS',
                    enabled: mode == null || f <= mode.maxFps,
                  ),
              ],
              onSelected: (f) {
                if (f != null) controller.selectRemoteFps(f);
              },
            ),
          ],
        ),
        if (streaming)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Trocar a resolução reinicia a transmissão por um instante; '
              'a webcam virtual mantém o tamanho e o OBS não percebe.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _OutputCard extends ConsumerWidget {
  const _OutputCard({required this.state});

  final ReceiverState state;

  static String get setupCommand => virtualWebcamSetupCommand();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(receiverControllerProvider.notifier);
    final busy = state.isBusy;
    return _SectionCard(
      title: 'Webcam virtual',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!state.hasDeviceFamily)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _Banner(
                icon: Icons.videocam_off_outlined,
                text: state.devices.isEmpty
                    ? 'Nenhuma webcam virtual encontrada. Crie as do ConectDroidCam com:\n$setupCommand'
                    : state.hasConectDroidCamDevice
                    ? 'Há só uma webcam "ConectDroidCam", de uma versão anterior. Com ela, trocar o '
                          'tamanho ou o formato exige reabrir a fonte no OBS. Crie uma por tamanho e '
                          'formato (feche o OBS antes) com:\n$setupCommand'
                    : 'As webcams do ConectDroidCam ainda não existem. Crie com:\n$setupCommand',
                color: theme.colorScheme.secondaryContainer,
                onColor: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: DropdownMenu<String?>(
                  key: ValueKey(
                    'device-${state.selectedDevice}-${state.devices.length}',
                  ),
                  enabled: !busy,
                  width: double.infinity,
                  label: const Text('Dispositivo'),
                  initialSelection: state.selectedDevice,
                  requestFocusOnTap: false,
                  onSelected: controller.selectDevice,
                  dropdownMenuEntries: [
                    if (state.hasDeviceFamily)
                      const DropdownMenuEntry<String?>(
                        value: ReceiverController.automaticDevice,
                        label: 'Automático (a do tamanho e formato certos)',
                      ),
                    const DropdownMenuEntry<String?>(
                      value: null,
                      label: 'Nenhum (só testar a conexão)',
                    ),
                    for (final d in state.devices)
                      DropdownMenuEntry<String?>(value: d.path, label: d.label),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Atualizar a lista',
                onPressed: busy ? null : controller.refreshDevices,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Copiar o comando de instalação',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: setupCommand)),
                icon: const Icon(Icons.content_copy),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Tamanho da imagem', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<OutputSize>(
            showSelectedIcon: false,
            segments: [
              for (final size in OutputSize.values)
                ButtonSegment(value: size, label: Text(size.label)),
            ],
            selected: {state.outputSize},
            onSelectionChanged: (v) => controller.setOutputSize(v.first),
          ),
          const SizedBox(height: 4),
          Text(
            'A webcam virtual tem sempre este tamanho, seja qual for a resolução do '
            'celular: dá para trocar a resolução no celular sem o OBS perder a imagem. '
            'Uma resolução maior que esta é reduzida.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Text('Formato da imagem', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ImageFormat>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ImageFormat.auto,
                icon: Icon(Icons.screen_rotation),
                label: Text('Automático'),
              ),
              ButtonSegment(
                value: ImageFormat.horizontal,
                icon: Icon(Icons.crop_landscape),
                label: Text('Horizontal'),
              ),
              ButtonSegment(
                value: ImageFormat.vertical,
                icon: Icon(Icons.crop_portrait),
                label: Text('Vertical'),
              ),
            ],
            selected: {state.format},
            onSelectionChanged: (v) => controller.setFormat(v.first),
          ),
          const SizedBox(height: 4),
          Text(
            'Automático usa vertical quando o celular está em pé e horizontal quando '
            'está deitado, na hora de conectar. Se o celular girar depois, a imagem é '
            'girada de volta e ganha barras pretas. Trocar o tamanho ou o formato '
            'reconecta o celular.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _Banner(
            icon: Icons.info_outline,
            text: state.hasDeviceFamily
                ? 'No OBS, adicione a webcam do tamanho e formato que você usa, por exemplo '
                      '"ConectDroidCam FHD Vertical". Cada uma tem sempre o mesmo tamanho, então '
                      'trocar a resolução, o tamanho ou girar o celular não exige reabrir nada. '
                      'Se você usar outro tamanho ou formato, adicione também a webcam dele.'
                : 'No OBS: depois de trocar o tamanho ou o formato, esconda e mostre a fonte de '
                      'vídeo, ou feche e abra o OBS. A webcam virtual mantém o tamanho com que o '
                      'OBS a abriu. Trocar só a resolução do celular não exige isso.',
            color: theme.colorScheme.surfaceContainerHighest,
            onColor: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, text, color) = switch (state.phase) {
      ReceiverPhase.connected => (
        Icons.check_circle,
        'Conectado a ${state.phoneName ?? state.connectedTo}',
        Colors.greenAccent,
      ),
      ReceiverPhase.connecting => (
        Icons.sync,
        'Conectando a ${state.phoneName ?? state.connectedTo}…',
        Colors.amberAccent,
      ),
      _ when state.phones.isNotEmpty => (
        Icons.smartphone,
        state.phones.length == 1
            ? '1 celular encontrado na rede'
            : '${state.phones.length} celulares encontrados na rede',
        theme.colorScheme.primary,
      ),
      _ => (
        Icons.search,
        'Procurando celulares na rede…',
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: theme.textTheme.titleMedium)),
          ],
        ),
      ),
    );
  }
}

class _PreviewBox extends ConsumerWidget {
  const _PreviewBox({required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frame = ref.watch(previewFrameProvider);
    final out = state.outgoing;
    final ratio = out == null || out.height == 0
        ? 16 / 9
        : out.width / out.height;
    final maxHeight = previewMaxHeight(MediaQuery.sizeOf(context).height);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(
          aspectRatio: ratio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: Colors.black,
              child: frame == null
                  ? const Center(
                      child: Text(
                        'Aguardando a imagem do celular…',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : Image.memory(
                      frame,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

double previewMaxHeight(double windowHeight) =>
    (windowHeight * 0.5).clamp(180.0, double.infinity);

String virtualWebcamSetupCommand({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final flatpakId = env['FLATPAK_ID'];
  if (flatpakId != null && flatpakId.isNotEmpty) {
    return 'flatpak run --command=cat $flatpakId '
        '/app/share/conectdroidcam/linux-webcam-virtual.sh | sudo bash';
  }
  return 'sudo scripts/setup/linux-webcam-virtual.sh';
}

String _deviceLabel(ReceiverState state, String path) {
  for (final d in state.devices) {
    if (d.path == path) return d.label;
  }
  return path;
}

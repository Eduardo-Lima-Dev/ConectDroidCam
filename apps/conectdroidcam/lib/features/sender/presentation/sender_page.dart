import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/sender_controller.dart';
import '../../../shared/widgets/brand_logo.dart';
import '../domain/sender_models.dart';
import '../../update/application/update_controller.dart';
import '../../update/presentation/update_banner.dart';

class SenderPage extends ConsumerStatefulWidget {
  const SenderPage({super.key});

  @override
  ConsumerState<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends ConsumerState<SenderPage> {
  bool _pairingDialogOpen = false;

  void _syncPairingDialog(PairingRequestEvent? prompt) {
    if (prompt != null && !_pairingDialogOpen) {
      _pairingDialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _PairingDialog(),
      ).whenComplete(() => _pairingDialogOpen = false);
    } else if (prompt == null && _pairingDialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final updater = ref.read(updateControllerProvider.notifier);
      ref
          .read(senderControllerProvider.notifier)
          .start()
          .whenComplete(updater.enableBackgroundChecks);
      updater.check();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(senderControllerProvider);
    final controller = ref.read(senderControllerProvider.notifier);
    ref.listen(
      senderControllerProvider.select((s) => s.pairing),
      (_, prompt) => _syncPairingDialog(prompt),
    );

    return Scaffold(
      body: SafeArea(
        child: switch (state.phase) {
          SenderPhase.initial ||
          SenderPhase.needsPermission ||
          SenderPhase.starting => const _Message(
            icon: null,
            title: 'Abrindo a câmera…',
            body: 'Se o sistema pedir, permita o acesso à câmera.',
          ),
          SenderPhase.permissionDenied => _Message(
            icon: Icons.no_photography_outlined,
            title: 'Sem acesso à câmera',
            body:
                'O ConectDroidCam precisa da câmera para funcionar. '
                'Permita em Configurações › Apps › ConectDroidCam › Permissões.',
            actionLabel: 'Tentar de novo',
            onAction: controller.start,
          ),
          SenderPhase.failed => _Message(
            icon: Icons.error_outline,
            title: 'Algo deu errado',
            body: state.error ?? 'Erro desconhecido.',
            actionLabel: 'Tentar de novo',
            onAction: controller.start,
          ),
          SenderPhase.ready || SenderPhase.streaming => _Console(state: state),
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData? icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLogo(size: 88),
              const SizedBox(height: 20),
              if (icon == null)
                const SizedBox.square(
                  dimension: 32,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              else
                Icon(icon, size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (onAction != null) ...[
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Console extends ConsumerStatefulWidget {
  const _Console({required this.state});

  final SenderState state;

  @override
  ConsumerState<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends ConsumerState<_Console> {
  bool _fullscreen = false;
  bool _menuOpen = false;

  void _setFullscreen(bool value) {
    if (_fullscreen == value) return;
    setState(() {
      _fullscreen = value;
      _menuOpen = false;
    });
    SystemChrome.setEnabledSystemUIMode(
      value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  void dispose() {
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setFullscreen(false);
      },
      child: _fullscreen ? _buildFullscreen(state) : _buildNormal(state),
    );
  }

  Widget _buildNormal(SenderState state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= constraints.maxHeight;
        final preview = _PreviewBox(
          info: state.preview,
          onTap: () => _setFullscreen(true),
          showFullscreenHint: true,
        );
        final panel = _ControlPanel(state: state);
        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: preview),
                const SizedBox(width: 16),
                SizedBox(width: 340, child: panel),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: preview),
              const SizedBox(height: 16),
              Expanded(flex: 6, child: panel),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFullscreen(SenderState state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            _PreviewBox(
              info: state.preview,
              onTap: _menuOpen ? () => setState(() => _menuOpen = false) : null,
              rounded: false,
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.preview?.canSwitch ?? false) ...[
                    _OverlayButton(
                      icon: Icons.cameraswitch_outlined,
                      tooltip: 'Trocar de câmera',
                      onPressed: state.busy
                          ? null
                          : ref
                                .read(senderControllerProvider.notifier)
                                .switchCamera,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _OverlayButton(
                    icon: _menuOpen ? Icons.close : Icons.tune,
                    tooltip: _menuOpen ? 'Fechar o menu' : 'Abrir o menu',
                    onPressed: () => setState(() => _menuOpen = !_menuOpen),
                  ),
                  const SizedBox(width: 8),
                  _OverlayButton(
                    icon: Icons.fullscreen_exit,
                    tooltip: 'Sair da tela cheia',
                    onPressed: () => _setFullscreen(false),
                  ),
                ],
              ),
            ),
            if (_menuOpen)
              Positioned(
                top: 64,
                right: 8,
                left: wide ? null : 8,
                bottom: 8,
                width: wide ? 340 : null,
                child: _MenuCard(state: state),
              ),
          ],
        );
      },
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        foregroundColor: Colors.white,
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 6,
      color: theme.colorScheme.surface.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: _ControlPanel(state: state),
      ),
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({
    required this.info,
    this.onTap,
    this.showFullscreenHint = false,
    this.rounded = true,
  });

  final PreviewInfo? info;
  final VoidCallback? onTap;
  final bool showFullscreenHint;
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final radius = rounded ? BorderRadius.circular(12) : BorderRadius.zero;
    return Semantics(
      button: onTap != null,
      label: showFullscreenHint
          ? 'Prévia da câmera. Toque para tela cheia.'
          : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.black, borderRadius: radius),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: info == null
                      ? const SizedBox.shrink()
                      : Transform.flip(
                          flipX: info!.isFront,
                          child: RotatedBox(
                            quarterTurns: info!.quarterTurns,
                            child: AspectRatio(
                              aspectRatio: info!.textureAspectRatio,
                              child: Texture(textureId: info!.textureId),
                            ),
                          ),
                        ),
                ),
                if (showFullscreenHint)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(
                          Icons.fullscreen,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlPanel extends ConsumerWidget {
  const _ControlPanel({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(senderControllerProvider.notifier);
    final theme = Theme.of(context);
    final caps = state.capabilities;

    return ListView(
      shrinkWrap: true,
      children: [
        Row(
          children: [
            const BrandLogo(size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Text('ConectDroidCam', style: theme.textTheme.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _StatusLine(state: state),
        const SizedBox(height: 8),
        const UpdateBanner(),
        const SizedBox(height: 12),
        if (state.isStreaming)
          FilledButton.tonalIcon(
            onPressed: state.busy ? null : controller.stopStreaming,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Parar transmissão'),
          )
        else
          FilledButton.icon(
            onPressed: state.busy || !state.canStart
                ? null
                : controller.startStreaming,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Iniciar transmissão'),
          ),
        if (state.preview?.canSwitch ?? false) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: state.busy ? null : controller.switchCamera,
            icon: const Icon(Icons.cameraswitch_outlined),
            label: Text(
              state.preview!.isFront
                  ? 'Usar a câmera traseira'
                  : 'Usar a câmera frontal',
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'A conexão é criptografada. O computador novo só consegue ver a câmera depois '
          'que você confirmar o código de pareamento.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Text('Resolução', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        if (state.isStreaming)
          _ModeTile(
            item:
                caps.find(state.selected) ??
                ModeAvailability(mode: state.selected, available: true),
            selected: true,
            enabled: false,
            inUse: true,
            onTap: () {},
          )
        else ...[
          for (final item in caps.mainModes)
            _ModeTile(
              item: item,
              selected: item.mode == state.selected,
              enabled: !state.busy,
              onTap: () => controller.select(item.mode),
            ),
          if (caps.extraModes.isNotEmpty)
            _ExtraModes(
              extras: caps.extraModes,
              selected: state.selected,
              enabled: !state.busy,
              onSelected: controller.select,
            ),
        ],
        const SizedBox(height: 16),
        Text('Quadros por segundo', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        _FpsSelector(
          options: caps.fpsFor(state.selected),
          selected: state.selectedFps,
          enabled: !state.busy,
          onSelected: controller.selectFps,
        ),
        if (state.notice != null) ...[
          const SizedBox(height: 8),
          Text(
            state.notice!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (state.isStreaming || state.phase == SenderPhase.ready)
          _ConnectionInfo(state: state),
        const SizedBox(height: 16),
        _PairedList(state: state),
      ],
    );
  }
}

class _PairingDialog extends ConsumerWidget {
  const _PairingDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompt = ref.watch(senderControllerProvider.select((s) => s.pairing));
    final controller = ref.read(senderControllerProvider.notifier);
    final theme = Theme.of(context);
    if (prompt == null) return const SizedBox.shrink();
    final code = '${prompt.code.substring(0, 3)} ${prompt.code.substring(3)}';
    return AlertDialog(
      title: Text('Parear com ${prompt.computer}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Veja se este código é o mesmo que aparece no computador. '
            'Se for diferente, não confirme: alguém pode estar no meio da conexão.',
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              code,
              style: theme.textTheme.displaySmall?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 4,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => controller.confirmPairing(false),
          child: const Text('Não é o mesmo'),
        ),
        FilledButton(
          onPressed: () => controller.confirmPairing(true),
          child: const Text('É o mesmo'),
        ),
      ],
    );
  }
}

class _PairedList extends ConsumerWidget {
  const _PairedList({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(senderControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Computadores pareados', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        if (state.pairedComputers.isEmpty)
          Text(
            'Nenhum ainda. Ao conectar pela primeira vez, o computador mostra um '
            'código que você confirma aqui.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final computer in state.pairedComputers)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.computer_outlined),
              title: Text(computer.name),
              subtitle: Text('Certificado ${computer.shortFingerprint}'),
              trailing: IconButton(
                tooltip: 'Remover pareamento',
                icon: const Icon(Icons.link_off),
                onPressed: () => controller.unpair(computer.fingerprint),
              ),
            ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, color) = switch (state) {
      SenderState(isStreaming: true, clientPeer: final peer?) => (
        'Transmitindo para $peer',
        Colors.greenAccent,
      ),
      SenderState(isStreaming: true) => (
        'Aguardando o computador conectar',
        Colors.amberAccent,
      ),
      SenderState(phase: SenderPhase.ready, clientPeer: final peer?) => (
        'Conectado a $peer: o computador comanda a transmissão',
        Colors.greenAccent,
      ),
      SenderState(phase: SenderPhase.ready) => (
        'Pronto: inicie aqui ou pelo computador',
        theme.colorScheme.onSurfaceVariant,
      ),
      _ => ('Pronto', theme.colorScheme.onSurfaceVariant),
    };
    return Row(
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.item,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.inUse = false,
  });

  final ModeAvailability item;
  final bool selected;
  final bool enabled;
  final bool inUse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = item.available && enabled;
    final highlighted = selected && item.available;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        enabled: usable || inUse,
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: highlighted
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        selected: highlighted,
        leading: Icon(
          highlighted
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
        ),
        title: Text(item.mode.label),
        subtitle: item.available
            ? (inUse ? const Text('Em uso') : null)
            : Text(item.reason ?? 'Indisponível neste aparelho'),
        onTap: usable ? onTap : null,
      ),
    );
  }
}

class _ExtraModes extends StatelessWidget {
  const _ExtraModes({
    required this.extras,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final List<ModeAvailability> extras;
  final VideoMode selected;
  final bool enabled;
  final ValueChanged<VideoMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DropdownMenu<VideoMode>(
        key: ValueKey('extras-${selected.isMain ? 'none' : selected}'),
        enabled: enabled,
        width: double.infinity,
        label: const Text('Outras resoluções'),
        initialSelection: selected.isMain ? null : selected,
        requestFocusOnTap: false,
        onSelected: (mode) {
          if (mode != null) onSelected(mode);
        },
        dropdownMenuEntries: [
          for (final item in extras)
            DropdownMenuEntry<VideoMode>(
              value: item.mode,
              label: item.mode.label,
              trailingIcon: Text('até ${item.maxFps} FPS'),
            ),
        ],
      ),
    );
  }
}

class _FpsSelector extends StatelessWidget {
  const _FpsSelector({
    required this.options,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final List<int> options;
  final int selected;
  final bool enabled;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (final fps in options)
          ButtonSegment<int>(value: fps, label: Text('$fps')),
      ],
      selected: {if (options.contains(selected)) selected},
      emptySelectionAllowed: true,
      onSelectionChanged: enabled
          ? (values) {
              if (values.isNotEmpty) onSelected(values.first);
            }
          : null,
    );
  }
}

class _ConnectionInfo extends StatelessWidget {
  const _ConnectionInfo({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stream = state.stream;
    final address = state.lanAddress;
    final mono = theme.textTheme.titleMedium?.copyWith(fontFamily: 'monospace');

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Endereço deste celular', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(
              address == null
                  ? 'Sem rede local'
                  : '${address.address}:${stream?.port ?? 47821}',
              style: mono,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  state.visibleAs != null
                      ? Icons.wifi_tethering
                      : Icons.wifi_tethering_off,
                  size: 16,
                  color: state.visibleAs != null
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(switch ((
                    state.visibleAs,
                    state.visibilityError,
                  )) {
                    (final nome?, _) => 'Visível na rede como "$nome"',
                    (_, final erro?) =>
                      'Não apareceu na rede ($erro): use o endereço acima',
                    _ => 'Anunciando na rede…',
                  }, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
            if (stream != null) ...[
              const SizedBox(height: 12),
              Text(
                'Entregando ${stream.width}×${stream.height} a ${state.selectedFps} FPS',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 2),
              Text(
                state.clientPeer == null
                    ? 'Sem computador conectado'
                    : '${state.measuredFps.toStringAsFixed(1)} FPS · '
                          '${state.bitrateKbps.round()} kb/s · '
                          '${state.dropped} descartados',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

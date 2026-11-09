import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/sender_controller.dart';
import '../domain/sender_models.dart';

/// Tela do celular: prévia da câmera, escolha da resolução e controle da transmissão.
class SenderPage extends ConsumerStatefulWidget {
  const SenderPage({super.key});

  @override
  ConsumerState<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends ConsumerState<SenderPage> {
  @override
  void initState() {
    super.initState();
    // Depois do primeiro frame, para o pedido de permissão não competir com a montagem.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(senderControllerProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(senderControllerProvider);
    final controller = ref.read(senderControllerProvider.notifier);

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

class _Console extends ConsumerWidget {
  const _Console({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= constraints.maxHeight;
        final preview = _PreviewBox(info: state.preview);
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
              AspectRatio(aspectRatio: 16 / 9, child: preview),
              const SizedBox(height: 16),
              Expanded(child: panel),
            ],
          ),
        );
      },
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.info});

  final PreviewInfo? info;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Center(
          child: info == null
              ? const SizedBox.shrink()
              : AspectRatio(
                  aspectRatio: info!.aspectRatio,
                  child: Texture(textureId: info!.textureId),
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

    return ListView(
      children: [
        Text('ConectDroidCam', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        _StatusLine(state: state),
        const SizedBox(height: 20),
        Text('Resolução', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        for (final item in state.profiles)
          _ProfileTile(
            item: item,
            selected: item.profile == state.selected,
            enabled: !state.isStreaming && !state.busy,
            onTap: () => controller.select(item.profile),
          ),
        const SizedBox(height: 16),
        if (state.isStreaming) _ConnectionInfo(state: state),
        const SizedBox(height: 16),
        if (state.isStreaming)
          FilledButton.tonalIcon(
            onPressed: state.busy ? null : controller.stopStreaming,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Parar transmissão'),
          )
        else
          FilledButton.icon(
            onPressed: state.busy || state.profiles.every((p) => !p.available)
                ? null
                : controller.startStreaming,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Iniciar transmissão'),
          ),
        const SizedBox(height: 16),
        Text(
          'Esta versão ainda não tem pareamento nem criptografia: '
          'use apenas em uma rede em que você confia.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.item,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ProfileAvailability item;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = item.available && enabled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        enabled: usable,
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected && item.available
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        selected: selected && item.available,
        leading: Icon(
          selected && item.available
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
        ),
        title: Text(item.profile.label),
        subtitle: item.available
            ? null
            : Text(item.reason ?? 'Indisponível neste aparelho'),
        onTap: usable ? onTap : null,
      ),
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
                  : '${address.address}:${stream?.port ?? ''}',
              style: mono,
            ),
            if (stream != null) ...[
              const SizedBox(height: 12),
              Text(
                'Entregando ${stream.width}×${stream.height} a ${stream.fps} FPS',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 2),
              Text(
                state.clientPeer == null
                    ? 'Sem computador conectado'
                    : '${state.fps.toStringAsFixed(1)} FPS · '
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

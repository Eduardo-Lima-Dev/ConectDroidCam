import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/sender_controller.dart';
import '../../../shared/widgets/brand_logo.dart';
import '../../../shared/widgets/pairing_countdown.dart';
import '../../../shared/widgets/status_colors.dart';
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
  late final AppLifecycleListener _lifecycle;

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
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(senderControllerProvider.notifier).onResumed(),
    );
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
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(senderControllerProvider);
    final controller = ref.read(senderControllerProvider.notifier);
    ref.listen(
      senderControllerProvider.select((s) => s.pairing),
      (_, prompt) => _syncPairingDialog(prompt),
    );
    ref.listen(senderControllerProvider.select((s) => s.success), (_, text) {
      if (text == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      controller.clearSuccess();
    });

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
                'O ConectDroidCam precisa da câmera para funcionar. Toque em '
                '"Abrir configurações", entre em Permissões e permita a câmera. '
                'Ao voltar para cá, o app continua sozinho.',
            actionLabel: 'Abrir configurações',
            onAction: controller.openAppSettings,
            secondaryLabel: 'Tentar de novo',
            onSecondary: controller.start,
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
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData? icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

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
              if (onSecondary != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onSecondary,
                  child: Text(secondaryLabel!),
                ),
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
          state: state,
          onFullscreen: () => _setFullscreen(true),
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
              state: state,
              onBackgroundTap: _menuOpen
                  ? () => setState(() => _menuOpen = false)
                  : null,
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

class _PreviewBox extends ConsumerStatefulWidget {
  const _PreviewBox({
    required this.state,
    this.onFullscreen,
    this.onBackgroundTap,
    this.rounded = true,
  });

  final SenderState state;
  final VoidCallback? onFullscreen;
  final VoidCallback? onBackgroundTap;
  final bool rounded;

  @override
  ConsumerState<_PreviewBox> createState() => _PreviewBoxState();
}

class _PreviewBoxState extends ConsumerState<_PreviewBox> {
  final _area = GlobalKey();
  Offset? _ring;
  Timer? _ringTimer;
  double _zoomAtStart = 1;
  bool _pinching = false;

  @override
  void dispose() {
    _ringTimer?.cancel();
    super.dispose();
  }

  void _showRing(Offset global) {
    final box = _area.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    setState(() => _ring = box.globalToLocal(global));
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _ring = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.state.preview;
    final controls = widget.state.controls;
    final controller = ref.read(senderControllerProvider.notifier);
    final radius = widget.rounded
        ? BorderRadius.circular(12)
        : BorderRadius.zero;
    final focusEnabled =
        widget.onBackgroundTap == null && controls.focusSupported;
    return Semantics(
      label: 'Prévia da câmera. Toque para focar; use dois dedos para zoom.',
      child: GestureDetector(
        key: _area,
        behavior: HitTestBehavior.opaque,
        onTap: widget.onBackgroundTap,
        onScaleStart: (_) => _zoomAtStart = controls.zoom,
        onScaleUpdate: (details) {
          if (details.pointerCount < 2 || !controls.canZoom) return;
          if (!_pinching) setState(() => _pinching = true);
          controller.setZoom(_zoomAtStart * details.scale);
        },
        onScaleEnd: (_) {
          if (_pinching) setState(() => _pinching = false);
        },
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
                          flipX: info.isFront,
                          child: RotatedBox(
                            quarterTurns: info.quarterTurns,
                            child: AspectRatio(
                              aspectRatio: info.textureAspectRatio,
                              child: LayoutBuilder(
                                builder: (context, constraints) =>
                                    GestureDetector(
                                      onTapUp: focusEnabled
                                          ? (details) {
                                              final size = constraints.biggest;
                                              controller.focusAt(
                                                details.localPosition.dx /
                                                    size.width,
                                                details.localPosition.dy /
                                                    size.height,
                                              );
                                              _showRing(details.globalPosition);
                                            }
                                          : null,
                                      child: Texture(textureId: info.textureId),
                                    ),
                              ),
                            ),
                          ),
                        ),
                ),
                if (_ring case final ring?)
                  Positioned(
                    left: ring.dx - 28,
                    top: ring.dy - 28,
                    child: IgnorePointer(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
                if (controls.canZoom && info != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: Center(
                      child: _pinching
                          ? _ZoomBadge(text: zoomLabel(controls.zoom))
                          : _ZoomPresets(
                              controls: controls,
                              onSelected: controller.setZoom,
                            ),
                    ),
                  ),
                if (widget.onFullscreen != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: _OverlayButton(
                      icon: Icons.fullscreen,
                      tooltip: 'Tela cheia',
                      onPressed: widget.onFullscreen,
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

class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ZoomPresets extends StatelessWidget {
  const _ZoomPresets({required this.controls, required this.onSelected});

  final CameraControls controls;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    final presets = controls.zoomPresets;
    if (presets.length < 2) return const SizedBox.shrink();
    double distance(double z) => (z - controls.zoom).abs();
    final nearest = presets.reduce(
      (a, b) => distance(a) <= distance(b) ? a : b,
    );
    final exact = distance(nearest) < 0.05;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final z in presets)
              _ZoomPresetButton(
                label: z == nearest && !exact
                    ? zoomLabel(controls.zoom)
                    : zoomLabel(z),
                selected: z == nearest,
                onTap: () => onSelected(z),
              ),
          ],
        ),
      ),
    );
  }
}

class _ZoomPresetButton extends StatelessWidget {
  const _ZoomPresetButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Zoom $label',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 36,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.amberAccent : Colors.white,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraAdjustments extends ConsumerWidget {
  const _CameraAdjustments({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(senderControllerProvider.notifier);
    final c = state.controls;
    final enabled = state.preview != null;
    if (!c.canZoom &&
        !c.canExpose &&
        !c.focusSupported &&
        !c.aeLockSupported &&
        !c.awbLockSupported &&
        !c.torchSupported) {
      return const SizedBox.shrink();
    }
    final hint = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ajustes da câmera', style: theme.textTheme.labelLarge),
        if (c.focusSupported || c.canZoom)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (c.focusSupported) 'Toque na imagem para focar',
                if (c.canZoom) 'use dois dedos para o zoom',
              ].join('; '),
              style: hint,
            ),
          ),
        if (c.canZoom) ...[
          const SizedBox(height: 8),
          Text('Zoom: ${zoomLabel(c.zoom)}', style: theme.textTheme.bodyMedium),
          Slider(
            value: c.zoom.clamp(c.zoomMin, c.zoomMax),
            min: c.zoomMin,
            max: c.zoomMax,
            label: zoomLabel(c.zoom),
            onChanged: enabled ? controller.setZoom : null,
          ),
        ],
        if (c.canExpose) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Exposição: ${exposureLabel(c.exposureEv)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (c.exposure != 0)
                TextButton(
                  onPressed: enabled ? () => controller.setExposure(0) : null,
                  child: const Text('Voltar ao normal'),
                ),
            ],
          ),
          Slider(
            value: c.exposure.toDouble(),
            min: c.exposureMin.toDouble(),
            max: c.exposureMax.toDouble(),
            divisions: c.exposureMax - c.exposureMin,
            label: exposureLabel(c.exposureEv),
            onChanged: enabled
                ? (v) => controller.setExposure(v.round())
                : null,
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (c.focusSupported)
              ActionChip(
                avatar: const Icon(
                  Icons.center_focus_strong_outlined,
                  size: 18,
                ),
                label: Text(
                  c.focusLocked
                      ? 'Voltar ao foco automático'
                      : 'Foco automático',
                ),
                onPressed: enabled && c.focusLocked
                    ? controller.focusAuto
                    : null,
              ),
            if (c.aeLockSupported)
              FilterChip(
                avatar: const Icon(Icons.exposure_outlined, size: 18),
                label: const Text('Travar exposição'),
                selected: c.aeLock,
                showCheckmark: false,
                onSelected: enabled ? controller.setAeLock : null,
              ),
            if (c.awbLockSupported)
              FilterChip(
                avatar: const Icon(Icons.wb_auto_outlined, size: 18),
                label: const Text('Travar cor'),
                selected: c.awbLock,
                showCheckmark: false,
                onSelected: enabled ? controller.setAwbLock : null,
              ),
            if (c.torchSupported)
              FilterChip(
                avatar: Icon(
                  c.torch ? Icons.flashlight_on : Icons.flashlight_off_outlined,
                  size: 18,
                ),
                label: const Text('Lanterna'),
                selected: c.torch,
                showCheckmark: false,
                onSelected: enabled ? controller.setTorch : null,
              ),
          ],
        ),
      ],
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
        const SizedBox(height: 16),
        _CameraAdjustments(state: state),
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
          const SizedBox(height: 12),
          Center(
            child: PairingCountdown(
              key: ValueKey(prompt.code),
              expiredText: 'O código expirou. Conecte de novo pelo computador.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
                onPressed: () async {
                  final ok = await _confirmUnpair(context, computer.name);
                  if (ok) await controller.unpair(computer.fingerprint);
                },
              ),
            ),
      ],
    );
  }
}

Future<bool> _confirmUnpair(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remover o pareamento com $name?'),
      content: const Text(
        'Este computador não vai mais ver a câmera. Para usar de novo, será '
        'preciso parear outra vez, conferindo o código nas duas telas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remover'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});

  final SenderState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, color) = switch (state) {
      SenderState(isStreaming: true, clientPeer: final peer?) => (
        'Transmitindo para ${state.clientName ?? peer}',
        StatusColors.ok(context),
      ),
      SenderState(isStreaming: true) => (
        'Aguardando o computador conectar',
        StatusColors.warning(context),
      ),
      SenderState(phase: SenderPhase.ready, clientPeer: final peer?) => (
        'Conectado a ${state.clientName ?? peer}: o computador comanda a transmissão',
        StatusColors.ok(context),
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
                  ? 'Sem Wi-Fi. Conecte o celular ao mesmo Wi-Fi do computador.'
                  : '${address.address}:${stream?.port ?? 47821}',
              style: address == null ? theme.textTheme.bodyMedium : mono,
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
              const SizedBox(height: 8),
              Text(
                'A transmissão continua com a tela apagada ou em outro app. '
                'Para parar, use o botão acima ou a notificação.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

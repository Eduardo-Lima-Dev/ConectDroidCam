import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/brand_logo.dart';
import '../../../shared/widgets/status_colors.dart';
import '../../desktop/application/desktop_shell.dart';
import '../../receiver/application/receiver_controller.dart';
import '../../receiver/presentation/receiver_page.dart';
import '../data/system_probe.dart';
import '../domain/system_check.dart';

final systemProbeProvider = Provider<SystemProbe>((ref) => const SystemProbe());

class SetupWizardPage extends ConsumerStatefulWidget {
  const SetupWizardPage({super.key});

  @override
  ConsumerState<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends ConsumerState<SetupWizardPage> {
  bool _moduleLoaded = false;
  bool? _secureBoot;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _probe();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _probe() {
    final probe = ref.read(systemProbeProvider);
    _moduleLoaded = probe.moduleLoaded();
    _secureBoot = probe.secureBoot();
  }

  Future<void> _refresh() async {
    setState(() => _checking = true);
    try {
      await ref.read(receiverControllerProvider.notifier).refreshDevices();
    } on Object catch (_) {}
    if (!mounted) return;
    setState(() {
      _probe();
      _checking = false;
    });
  }

  Future<void> _finish() async {
    await ref.read(receiverControllerProvider.notifier).markSetupDone();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receiver = ref.watch(receiverControllerProvider);
    final shell = ref.watch(desktopShellProvider);
    final checks = evaluateSystem(
      SystemFacts(
        ffmpegOk: receiver.ffmpegOk,
        ffmpegHint: ffmpegMissingText(),
        moduleLoaded: _moduleLoaded || receiver.hasDeviceFamily,
        secureBoot: _secureBoot,
        hasDeviceFamily: receiver.hasDeviceFamily,
        hasLegacyDevice: receiver.hasConectDroidCamDevice,
        trayAvailable: shell.started ? shell.trayAvailable : null,
        setupCommand: virtualWebcamSetupCommand(),
      ),
    );
    final blocked = hasBlockingProblem(checks);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Row(
                  children: [
                    const BrandLogo(size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Preparar este computador',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Confira se está tudo pronto para usar a câmera do celular como '
                  'webcam. Dá para abrir esta tela de novo pelo botão "Verificar o '
                  'sistema".',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                for (final check in checks) ...[
                  _CheckCard(check: check),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _checking ? null : _refresh,
                      icon: _checking
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: const Text('Verificar de novo'),
                    ),
                    FilledButton(
                      onPressed: _finish,
                      child: Text(
                        blocked ? 'Continuar mesmo assim' : 'Concluir',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.check});

  final SystemCheck check;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label) = switch (check.status) {
      CheckStatus.ok => (
        Icons.check_circle,
        StatusColors.ok(context),
        'Pronto',
      ),
      CheckStatus.warning => (
        Icons.warning_amber_rounded,
        StatusColors.warning(context),
        'Atenção',
      ),
      CheckStatus.problem => (
        Icons.error,
        theme.colorScheme.error,
        'Falta resolver',
      ),
      CheckStatus.info => (
        Icons.info_outline,
        theme.colorScheme.primary,
        'Dica',
      ),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: label,
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(check.title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  SelectableText(check.detail),
                  if (check.command case final command?) ...[
                    const SizedBox(height: 10),
                    _CommandBox(command: command),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandBox extends StatelessWidget {
  const _CommandBox({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                command,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copiar o comando',
              icon: const Icon(Icons.content_copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(content: Text('Comando copiado.')),
                  );
              },
            ),
          ],
        ),
      ),
    );
  }
}

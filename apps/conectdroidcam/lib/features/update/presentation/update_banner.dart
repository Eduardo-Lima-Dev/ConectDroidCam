import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/update_controller.dart';

class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final theme = Theme.of(context);
    final release = state.release;

    final (String text, Widget? action) = switch (state.phase) {
      UpdatePhase.available => (
        'Nova versão disponível (build ${release?.build}).',
        FilledButton.tonal(
          onPressed: controller.download,
          child: const Text('Atualizar'),
        ),
      ),
      UpdatePhase.downloading => (
        'Baixando a atualização… ${(state.progress * 100).round()}%',
        null,
      ),
      UpdatePhase.needsPermission => (
        'Para atualizar, permita que o ConectDroidCam instale apps. Depois volte '
            'aqui e toque em Instalar.',
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: controller.openInstallSettings,
              child: const Text('Permitir'),
            ),
            FilledButton.tonal(
              onPressed: controller.install,
              child: const Text('Instalar'),
            ),
          ],
        ),
      ),
      UpdatePhase.ready => (
        state.message ?? 'Atualização baixada.',
        FilledButton.tonal(
          onPressed: controller.install,
          child: const Text('Instalar'),
        ),
      ),
      UpdatePhase.installing => (
        'Confirme a instalação na tela do Android.',
        null,
      ),
      UpdatePhase.failed => (
        state.message ?? 'A atualização falhou.',
        TextButton(
          onPressed: controller.download,
          child: const Text('Tentar de novo'),
        ),
      ),
      _ => ('', null),
    };
    if (text.isEmpty) return const SizedBox.shrink();

    return Card(
      color: state.phase == UpdatePhase.failed
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
              ],
            ),
            if (state.phase == UpdatePhase.downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: state.progress),
            ],
            if (action != null) ...[const SizedBox(height: 8), action],
          ],
        ),
      ),
    );
  }
}

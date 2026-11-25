import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/desktop_update_controller.dart';

class DesktopUpdateBanner extends ConsumerWidget {
  const DesktopUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(desktopUpdateProvider);
    if (release == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final controller = ref.read(desktopUpdateProvider.notifier);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Nova versão disponível (build ${release.build})',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Fechar',
                  icon: const Icon(Icons.close),
                  onPressed: controller.dismiss,
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Atualize pela loja do sistema (GNOME Software, Discover) ou rode o '
              'comando abaixo. Depois, feche e abra o ConectDroidCam de novo.',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    desktopUpdateCommand,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copiar o comando',
                  icon: const Icon(Icons.copy),
                  onPressed: () => Clipboard.setData(
                    const ClipboardData(text: desktopUpdateCommand),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

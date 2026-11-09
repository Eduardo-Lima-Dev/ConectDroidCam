import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/receiver/presentation/receiver_page.dart';
import '../features/receiver/presentation/receiver_placeholder_page.dart';
import '../features/sender/presentation/sender_page.dart';

class ConectDroidCamApp extends StatelessWidget {
  const ConectDroidCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ConectDroidCam',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const _RoleGate(),
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      // Verde do anel da logo.
      seedColor: const Color(0xFF62F713),
      brightness: brightness,
    ),
  );
}

/// Escolhe o papel pela plataforma: celular é emissor, computador é receptor.
class _RoleGate extends StatelessWidget {
  const _RoleGate();

  @override
  Widget build(BuildContext context) {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => const SenderPage(),
      TargetPlatform.iOS => const PlaceholderPage(
        title: 'Emissor para iPhone em desenvolvimento',
        message:
            'A câmera do iPhone entra em uma fase seguinte. '
            'Por enquanto, o emissor funciona no Android.',
      ),
      TargetPlatform.linux => const ReceiverPage(),
      _ => const PlaceholderPage(
        title: 'Receptor em desenvolvimento',
        message:
            'O app do computador ainda não existe para este sistema. '
            'No momento, o receptor funciona no Linux.',
      ),
    };
  }
}

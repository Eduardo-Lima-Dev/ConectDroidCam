import 'dart:convert';
import 'dart:io';

import '../domain/receiver_models.dart';

/// Guarda as configurações do receptor entre execuções.
abstract interface class ReceiverSettingsStore {
  Future<ReceiverSettings> load();
  Future<void> save(ReceiverSettings settings);
}

/// Um arquivo JSON em `$XDG_CONFIG_HOME/conectdroidcam/receptor.json` (ou `~/.config/...`).
class FileReceiverSettingsStore implements ReceiverSettingsStore {
  FileReceiverSettingsStore({File? file}) : _file = file ?? _defaultFile();

  final File _file;

  static File _defaultFile() {
    final env = Platform.environment;
    final base =
        env['XDG_CONFIG_HOME'] ??
        (env['HOME'] != null
            ? '${env['HOME']}/.config'
            : Directory.systemTemp.path);
    return File('$base/conectdroidcam/receptor.json');
  }

  @override
  Future<ReceiverSettings> load() async {
    try {
      if (!_file.existsSync()) return const ReceiverSettings();
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map<String, Object?>) return const ReceiverSettings();
      final phones = json['trustedPhones'];
      return ReceiverSettings(
        autoConnect: json['autoConnect'] is bool
            ? json['autoConnect']! as bool
            : true,
        trustedPhones: {if (phones is List) ...phones.whereType<String>()},
        outputSize: OutputSize.values.firstWhere(
          (z) => z.name == json['outputSize'],
          orElse: () => OutputSize.fullHd,
        ),
        format: ImageFormat.values.firstWhere(
          (f) => f.name == json['format'],
          orElse: () => ImageFormat.auto,
        ),
      );
    } on Object {
      // Arquivo corrompido ou ilegível: começa do zero, sem travar o app.
      return const ReceiverSettings();
    }
  }

  @override
  Future<void> save(ReceiverSettings settings) async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'autoConnect': settings.autoConnect,
          'format': settings.format.name,
          'outputSize': settings.outputSize.name,
          'trustedPhones': settings.trustedPhones.toList()..sort(),
        }),
      );
    } on Object {
      // Não conseguir gravar não pode derrubar a conexão.
    }
  }
}

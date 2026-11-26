import 'dart:convert';
import 'dart:io';

import '../domain/receiver_models.dart';

abstract interface class ReceiverSettingsStore {
  Future<ReceiverSettings> load();
  Future<void> save(ReceiverSettings settings);
}

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
      final prints = json['fingerprints'];
      final names = json['phoneNames'];
      return ReceiverSettings(
        autoConnect: json['autoConnect'] is bool
            ? json['autoConnect']! as bool
            : true,
        trustedPhones: {if (phones is List) ...phones.whereType<String>()},
        fingerprints: {
          if (prints is Map)
            for (final e in prints.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
        },
        phoneNames: {
          if (names is Map)
            for (final e in names.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
        },
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
          'fingerprints': settings.fingerprints,
          'phoneNames': settings.phoneNames,
        }),
      );
    } on Object {
      return;
    }
  }
}

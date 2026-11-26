import 'dart:io';

class SystemProbe {
  const SystemProbe({this.root = ''});

  final String root;

  static const _secureBootVar =
      '/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-e98032b8c39c';

  bool moduleLoaded() =>
      Directory('$root/sys/module/v4l2loopback').existsSync();

  bool? secureBoot() {
    final file = File('$root$_secureBootVar');
    try {
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      if (bytes.isEmpty) return null;
      return bytes.last == 1;
    } on FileSystemException {
      return null;
    }
  }
}

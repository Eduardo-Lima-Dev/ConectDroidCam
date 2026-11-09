import 'dart:typed_data';

/// Um celular achado na rede, ou digitado à mão.
class Phone {
  const Phone({required this.id, required this.name, required this.address});

  final String id;
  final String name;

  /// `ip:porta` para conectar.
  final String address;
}

/// Uma webcam virtual de tamanho fixo: a de um tamanho e um formato.
class ShapeDevice {
  const ShapeDevice({
    required this.size,
    required this.vertical,
    required this.path,
  });

  final OutputSize size;
  final bool vertical;
  final String path;
}

/// Um dispositivo de vídeo virtual (V4L2) onde o app pode escrever a imagem do celular.
class VideoDevice {
  const VideoDevice({required this.path, required this.name});

  /// Por exemplo `/dev/video10`.
  final String path;
  final String name;

  /// Qualquer dispositivo criado por `scripts/setup/linux-webcam-virtual.sh`.
  bool get isConectDroidCam => name.contains('ConectDroidCam');

  static final _shapeName = RegExp(
    r'^ConectDroidCam (HD|FHD|2K) (Horizontal|Vertical)$',
  );

  /// Se este dispositivo é o de um tamanho e formato ("ConectDroidCam FHD Vertical"), qual.
  /// O dispositivo único das versões anteriores ("ConectDroidCam") devolve `null`.
  ShapeDevice? get shape {
    final m = _shapeName.firstMatch(name);
    if (m == null) return null;
    final size = switch (m.group(1)) {
      'HD' => OutputSize.hd,
      '2K' => OutputSize.qhd,
      _ => OutputSize.fullHd,
    };
    return ShapeDevice(
      size: size,
      vertical: m.group(2) == 'Vertical',
      path: path,
    );
  }

  String get label => '$name ($path)';
}

/// O que o celular está entregando.
class IncomingVideo {
  const IncomingVideo({
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    required this.rotation,
  });

  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;

  /// Graus, no sentido horário, que a imagem precisa girar para ficar em pé.
  final int rotation;
}

/// O vídeo que sai para a webcam virtual.
class OutgoingVideo {
  const OutgoingVideo({
    required this.width,
    required this.height,
    required this.rotation,
    this.device,
  });

  /// Dispositivo em que a imagem está sendo escrita, ou `null` se nenhum.
  final String? device;

  final int width;
  final int height;
  final int rotation;
}

class LiveStats {
  const LiveStats({
    required this.fps,
    required this.kbps,
    required this.delayMs,
    required this.frames,
  });

  final double fps;
  final double kbps;

  /// Maior atraso da rede no último segundo, além do melhor caso.
  final double delayMs;
  final int frames;
}

/// O que acontece durante uma conexão.
sealed class ReceiverUpdate {
  const ReceiverUpdate();
}

class HelloUpdate extends ReceiverUpdate {
  const HelloUpdate({required this.deviceName, required this.platform});

  final String deviceName;
  final String platform;
}

class ProfileUpdate extends ReceiverUpdate {
  const ProfileUpdate(this.video);

  final IncomingVideo video;
}

class OutputUpdate extends ReceiverUpdate {
  const OutputUpdate(this.video);

  final OutgoingVideo video;
}

class StatsUpdate extends ReceiverUpdate {
  const StatsUpdate(this.stats);

  final LiveStats stats;
}

/// Um quadro JPEG da prévia, cerca de 10 por segundo.
class PreviewUpdate extends ReceiverUpdate {
  const PreviewUpdate(this.jpeg);

  final Uint8List jpeg;
}

class SenderErrorUpdate extends ReceiverUpdate {
  const SenderErrorUpdate(this.message);

  final String message;
}

class NoticeUpdate extends ReceiverUpdate {
  const NoticeUpdate(this.message);

  final String message;
}

/// A conexão terminou normalmente.
class EndedUpdate extends ReceiverUpdate {
  const EndedUpdate();
}

/// A conexão terminou por erro, com uma explicação para o usuário.
class FailedUpdate extends ReceiverUpdate {
  const FailedUpdate(this.message);

  final String message;
}

/// Um celular que apareceu ou saiu da rede.
class PhoneChange {
  const PhoneChange.found(Phone this.phone) : lostId = null;
  const PhoneChange.lost(String this.lostId) : phone = null;

  final Phone? phone;
  final String? lostId;
}

/// Formato do quadro entregue à webcam virtual.
enum ImageFormat {
  /// Vertical se o celular estiver em pé ao conectar, horizontal se estiver deitado.
  auto,
  horizontal,
  vertical,
}

/// Tamanho do quadro entregue à webcam virtual. Não acompanha a resolução do celular:
/// assim dá para trocar a resolução do celular sem o OBS perder a webcam.
enum OutputSize {
  hd('HD', 1280, 720),
  fullHd('Full HD', 1920, 1080),
  qhd('2K', 2560, 1440);

  const OutputSize(this.title, this.long, this.short);

  /// Nome comercial; o "2K" aparece sempre com a resolução.
  final String title;
  final int long;
  final int short;

  String get label => '$title ($long×$short)';
}

/// O que o app lembra entre uma execução e outra.
class ReceiverSettings {
  const ReceiverSettings({
    this.autoConnect = true,
    this.trustedPhones = const {},
    this.format = ImageFormat.auto,
    this.outputSize = OutputSize.fullHd,
  });

  /// Formato da imagem escolhido pelo usuário.
  final ImageFormat format;

  /// Tamanho da imagem entregue à webcam virtual.
  final OutputSize outputSize;

  /// Conectar sozinho quando um celular já usado aparecer na rede.
  final bool autoConnect;

  /// Identificadores (nome mDNS) dos celulares a que o usuário já conectou.
  ///
  /// Isto **não é segurança**: é só uma lista de conveniência. Sem pareamento, qualquer
  /// aparelho da rede pode se anunciar com o mesmo nome.
  final Set<String> trustedPhones;

  ReceiverSettings copyWith({
    bool? autoConnect,
    Set<String>? trustedPhones,
    ImageFormat? format,
    OutputSize? outputSize,
  }) => ReceiverSettings(
    autoConnect: autoConnect ?? this.autoConnect,
    trustedPhones: trustedPhones ?? this.trustedPhones,
    format: format ?? this.format,
    outputSize: outputSize ?? this.outputSize,
  );
}

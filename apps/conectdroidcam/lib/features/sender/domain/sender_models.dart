/// Perfis de vídeo do protocolo v1.
enum VideoProfile {
  hd('hd', 'HD', 1280, 720, 3000),
  fullHd('fullHd', 'Full HD', 1920, 1080, 6000),
  qhd('qhd', '2K', 2560, 1440, 9000);

  const VideoProfile(
    this.id,
    this.name,
    this.width,
    this.height,
    this.bitrateKbps,
  );

  final String id;
  final String name;
  final int width;
  final int height;
  final int bitrateKbps;

  /// Nome mostrado ao usuário. O "2K" sempre aparece com a resolução.
  String get label => '$name ($width×$height)';

  static VideoProfile? fromId(String id) {
    for (final profile in values) {
      if (profile.id == id) return profile;
    }
    return null;
  }
}

/// Se um perfil pode ser usado neste aparelho, e o motivo quando não pode.
class ProfileAvailability {
  const ProfileAvailability({
    required this.profile,
    required this.available,
    this.reason,
  });

  final VideoProfile profile;
  final bool available;
  final String? reason;
}

/// Câmera aberta para a prévia: textura do Flutter e tamanho do buffer.
class PreviewInfo {
  const PreviewInfo({
    required this.textureId,
    required this.width,
    required this.height,
  });

  final int textureId;
  final int width;
  final int height;

  double get aspectRatio => height == 0 ? 16 / 9 : width / height;
}

/// O que o emissor realmente está entregando.
class StreamInfo {
  const StreamInfo({
    required this.profile,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    required this.port,
  });

  final VideoProfile profile;
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;
  final int port;
}

/// Endereço IPv4 de uma interface de rede do celular.
class LocalAddress {
  const LocalAddress({required this.interfaceName, required this.address});

  final String interfaceName;
  final String address;

  /// Interfaces de Wi-Fi e Ethernet; dados móveis (rmnet) não servem para a rede local.
  bool get isLan =>
      interfaceName.startsWith('wlan') ||
      interfaceName.startsWith('eth') ||
      interfaceName.startsWith('ap');
}

/// Eventos que chegam do código nativo durante a transmissão.
sealed class SenderEvent {
  const SenderEvent();
}

class ClientEvent extends SenderEvent {
  const ClientEvent({required this.connected, this.peer});

  final bool connected;
  final String? peer;
}

class StatsEvent extends SenderEvent {
  const StatsEvent({
    required this.fps,
    required this.bitrateKbps,
    required this.dropped,
  });

  final double fps;
  final double bitrateKbps;
  final int dropped;
}

class ErrorEvent extends SenderEvent {
  const ErrorEvent(this.message);

  final String message;
}

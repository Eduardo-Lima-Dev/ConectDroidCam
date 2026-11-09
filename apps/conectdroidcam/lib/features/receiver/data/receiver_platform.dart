import '../domain/receiver_models.dart';

/// Contrato com o núcleo do receptor. Existe para o controlador poder ser testado sem o
/// núcleo em Rust, sem rede e sem webcam virtual.
abstract interface class ReceiverPlatform {
  /// Carrega o núcleo. Lança se a biblioteca não foi encontrada.
  Future<void> init();

  /// Celulares que aparecem e somem na rede, até [stopDiscovery].
  Stream<PhoneChange> discover();
  Future<void> stopDiscovery();

  /// Conecta e entrega o vídeo a [videoDevice] (sem ele, só mede). O fluxo termina com
  /// [EndedUpdate] ou [FailedUpdate].
  Stream<ReceiverUpdate> connect({
    required String address,
    required String? videoDevice,
    required ImageFormat format,
    required OutputSize size,
    required List<ShapeDevice> shapeDevices,
  });

  Future<void> disconnect();

  // Comandos ao celular da conexão em andamento. Cada um devolve o motivo da falha, ou
  // `null` se foi enviado; o resultado de verdade chega depois, como [CapabilitiesUpdate].

  /// Pede que o celular comece a transmitir neste tamanho e FPS.
  Future<String?> startStream(int width, int height, int fps);

  /// Pede que o celular pare de transmitir, mantendo a conexão.
  Future<String?> stopStream();

  Future<String?> setFps(int fps);

  /// Troca a câmera do celular; sem [front], alterna.
  Future<String?> switchCamera({bool? front});

  /// O `ffmpeg` está instalado?
  Future<bool> ffmpegAvailable();

  Future<List<VideoDevice>> listVideoDevices();

  Future<String> computerName();
}

import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/sender_models.dart';

abstract interface class SenderPlatform {
  Future<bool> hasCameraPermission();
  Future<bool> requestCameraPermission();
  Future<void> openAppSettings();
  Future<SenderCapabilities> listModes();
  Future<List<LocalAddress>> localAddresses();
  Future<PreviewInfo> startPreview();
  Future<void> stopPreview();
  Future<StreamInfo> startStreaming(VideoMode mode, int fps);

  Future<void> setFps(int fps);

  Future<PreviewInfo> switchCamera({bool? front});
  Future<void> stopStreaming();

  Future<void> confirmPairing(bool accept);
  Future<List<PairedComputer>> listPaired();

  Future<void> unpair(String fingerprint);
  Stream<SenderEvent> get events;
}

class SenderException implements Exception {
  const SenderException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ChannelSenderPlatform implements SenderPlatform {
  ChannelSenderPlatform({MethodChannel? methods, EventChannel? eventChannel})
    : _methods = methods ?? const MethodChannel('cdc/sender'),
      _events = eventChannel ?? const EventChannel('cdc/sender/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Future<T> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      final result = await _methods.invokeMethod<T>(method, arguments);
      return result as T;
    } on PlatformException catch (e) {
      throw SenderException(e.message ?? 'Falha em $method');
    }
  }

  @override
  Future<bool> hasCameraPermission() => _call<bool>('hasCameraPermission');

  @override
  Future<bool> requestCameraPermission() =>
      _call<bool>('requestCameraPermission');

  @override
  Future<void> openAppSettings() => _call<void>('openAppSettings');

  @override
  Future<SenderCapabilities> listModes() async {
    final raw = await _call<Map<Object?, Object?>>('listModes');
    final modes = (raw['modes']! as List<Object?>)
        .cast<Map<Object?, Object?>>();
    final fps = (raw['fpsOptions']! as List<Object?>).cast<int>();
    return SenderCapabilities(
      modes: [
        for (final item in modes)
          ModeAvailability(
            mode: VideoMode(item['width']! as int, item['height']! as int),
            available: item['available']! as bool,
            reason: item['reason'] as String?,
            maxFps: (item['maxFps'] as int?) ?? 30,
          ),
      ],
      fpsOptions: fps.isEmpty ? const [30] : fps,
    );
  }

  @override
  Future<List<LocalAddress>> localAddresses() async {
    final raw = await _call<List<Object?>>('localAddresses');
    return [
      for (final item in raw.cast<Map<Object?, Object?>>())
        LocalAddress(
          interfaceName: item['interface']! as String,
          address: item['address']! as String,
        ),
    ];
  }

  @override
  Future<PreviewInfo> startPreview() async =>
      _parsePreview(await _call<Map<Object?, Object?>>('startPreview'));

  @override
  Future<PreviewInfo> switchCamera({bool? front}) async => _parsePreview(
    await _call<Map<Object?, Object?>>('switchCamera', {'front': front}),
  );

  PreviewInfo _parsePreview(Map<Object?, Object?> raw) => PreviewInfo(
    textureId: (raw['textureId']! as num).toInt(),
    width: raw['width']! as int,
    height: raw['height']! as int,
    sensorOrientation: (raw['sensorOrientation'] as int?) ?? 90,
    displayRotation: (raw['displayRotation'] as int?) ?? 0,
    isFront: (raw['isFront'] as bool?) ?? false,
    canSwitch: (raw['canSwitch'] as bool?) ?? false,
  );

  @override
  Future<void> stopPreview() => _call<void>('stopPreview');

  @override
  Future<StreamInfo> startStreaming(VideoMode mode, int fps) async {
    final raw = await _call<Map<Object?, Object?>>('startStreaming', {
      'width': mode.width,
      'height': mode.height,
      'fps': fps,
    });
    return StreamInfo(
      mode: VideoMode(raw['width']! as int, raw['height']! as int),
      fps: raw['fps']! as int,
      bitrateKbps: raw['bitrateKbps']! as int,
      port: raw['port']! as int,
    );
  }

  @override
  Future<void> setFps(int fps) => _call<void>('setFps', {'fps': fps});

  @override
  Future<void> stopStreaming() => _call<void>('stopStreaming');

  @override
  Future<void> confirmPairing(bool accept) =>
      _call<void>('confirmPairing', {'accept': accept});

  @override
  Future<List<PairedComputer>> listPaired() async {
    final raw = await _call<List<Object?>>('listPaired');
    return [
      for (final item in raw.cast<Map<Object?, Object?>>())
        PairedComputer(
          fingerprint: item['fingerprint']! as String,
          name: item['name']! as String,
          since: DateTime.fromMillisecondsSinceEpoch(
            (item['since'] as num?)?.toInt() ?? 0,
          ),
        ),
    ];
  }

  @override
  Future<void> unpair(String fingerprint) =>
      _call<void>('unpair', {'fingerprint': fingerprint});

  @override
  Stream<SenderEvent> get events => _events
      .receiveBroadcastStream()
      .map((raw) => _parseEvent(raw as Map<Object?, Object?>))
      .where((event) => event != null)
      .cast<SenderEvent>();

  SenderEvent? _parseEvent(Map<Object?, Object?> raw) {
    switch (raw['event']) {
      case 'client':
        return ClientEvent(
          connected: raw['connected']! as bool,
          peer: raw['peer'] as String?,
        );
      case 'stats':
        return StatsEvent(
          fps: (raw['fps']! as num).toDouble(),
          bitrateKbps: (raw['bitrateKbps']! as num).toDouble(),
          dropped: (raw['dropped']! as num).toInt(),
        );
      case 'rotation':
        return RotationEvent((raw['displayRotation']! as num).toInt());
      case 'discovery':
        return DiscoveryEvent(
          registered: raw['registered']! as bool,
          name: raw['name'] as String?,
          error: raw['error'] as String?,
        );
      case 'remote':
        final streaming = raw['streaming']! as bool;
        return RemoteStreamEvent(
          streaming: streaming,
          stream: streaming
              ? StreamInfo(
                  mode: VideoMode(raw['width']! as int, raw['height']! as int),
                  fps: raw['fps']! as int,
                  bitrateKbps: raw['bitrateKbps']! as int,
                  port: raw['port']! as int,
                )
              : null,
        );
      case 'camera':
        return CameraChangedEvent(_parsePreview(raw));
      case 'pairing':
        return PairingRequestEvent(
          code: raw['code']! as String,
          computer: (raw['computer'] as String?) ?? 'computador',
        );
      case 'pairingEnded':
        return PairingEndedEvent(
          paired: raw['paired']! as bool,
          computer: (raw['computer'] as String?) ?? 'computador',
          reason: raw['reason'] as String?,
        );
      case 'error':
        return ErrorEvent(raw['message']! as String);
      default:
        return null;
    }
  }
}

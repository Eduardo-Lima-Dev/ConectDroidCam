import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/sender_models.dart';

/// Contrato com o emissor nativo. Existe para o controlador poder ser testado
/// com uma versão falsa, sem câmera.
abstract interface class SenderPlatform {
  Future<bool> hasCameraPermission();
  Future<bool> requestCameraPermission();
  Future<List<ProfileAvailability>> listProfiles();
  Future<List<LocalAddress>> localAddresses();
  Future<PreviewInfo> startPreview();
  Future<void> stopPreview();
  Future<StreamInfo> startStreaming(VideoProfile profile);
  Future<void> stopStreaming();
  Stream<SenderEvent> get events;
}

/// Falha vinda do código nativo, com mensagem já pronta para o usuário.
class SenderException implements Exception {
  const SenderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Implementação por MethodChannel e EventChannel (Android).
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
  Future<List<ProfileAvailability>> listProfiles() async {
    final raw = await _call<List<Object?>>('listProfiles');
    return [
      for (final item in raw.cast<Map<Object?, Object?>>())
        if (VideoProfile.fromId(item['profile']! as String) case final profile?)
          ProfileAvailability(
            profile: profile,
            available: item['available']! as bool,
            reason: item['reason'] as String?,
          ),
    ];
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
  Future<PreviewInfo> startPreview() async {
    final raw = await _call<Map<Object?, Object?>>('startPreview');
    return PreviewInfo(
      textureId: (raw['textureId']! as num).toInt(),
      width: raw['width']! as int,
      height: raw['height']! as int,
    );
  }

  @override
  Future<void> stopPreview() => _call<void>('stopPreview');

  @override
  Future<StreamInfo> startStreaming(VideoProfile profile) async {
    final raw = await _call<Map<Object?, Object?>>('startStreaming', {
      'profile': profile.id,
    });
    return StreamInfo(
      profile: profile,
      width: raw['width']! as int,
      height: raw['height']! as int,
      fps: raw['fps']! as int,
      bitrateKbps: raw['bitrateKbps']! as int,
      port: raw['port']! as int,
    );
  }

  @override
  Future<void> stopStreaming() => _call<void>('stopStreaming');

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
      case 'error':
        return ErrorEvent(raw['message']! as String);
      default:
        return null;
    }
  }
}

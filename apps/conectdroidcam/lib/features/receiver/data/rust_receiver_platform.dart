import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;

import '../../../src/rust/api.dart' as api;
import '../../../src/rust/frb_generated.dart';
import '../domain/receiver_models.dart';
import 'receiver_platform.dart';

class RustReceiverPlatform implements ReceiverPlatform {
  RustReceiverPlatform({this.libraryPath});

  final String? libraryPath;

  @override
  Future<void> init() async {
    await CdcCore.init(
      externalLibrary: ExternalLibrary.open(libraryPath ?? 'libcdc_ffi.so'),
    );
  }

  @override
  Stream<PhoneChange> discover() {
    return api.startDiscovery().map((info) {
      if (info.error case final erro?) throw StateError(erro);
      if (info.lost) return PhoneChange.lost(info.id);
      return PhoneChange.found(
        Phone(
          id: info.id,
          name: info.name,
          address: info.address ?? '${info.host}:${info.port}',
        ),
      );
    });
  }

  @override
  Future<void> stopDiscovery() => api.stopDiscovery();

  @override
  Stream<ReceiverUpdate> connect({
    required String address,
    required String? videoDevice,
    required ImageFormat format,
    required OutputSize size,
    required List<ShapeDevice> shapeDevices,
    String? pinnedFingerprint,
  }) {
    return api
        .connectPhone(
          address: address,
          v4L2Device: videoDevice,
          format: switch (format) {
            ImageFormat.auto => api.OutputFormat.auto,
            ImageFormat.horizontal => api.OutputFormat.horizontal,
            ImageFormat.vertical => api.OutputFormat.vertical,
          },
          size: switch (size) {
            OutputSize.hd => api.OutputSize.hd,
            OutputSize.fullHd => api.OutputSize.fullHd,
            OutputSize.qhd => api.OutputSize.qhd,
          },
          shapeDevices: [
            for (final d in shapeDevices)
              api.ShapeDevice(
                size: switch (d.size) {
                  OutputSize.hd => api.OutputSize.hd,
                  OutputSize.fullHd => api.OutputSize.fullHd,
                  OutputSize.qhd => api.OutputSize.qhd,
                },
                vertical: d.vertical,
                path: d.path,
              ),
          ],
          preview: true,
          pinnedFingerprint: pinnedFingerprint,
        )
        .map(_toUpdate)
        .transform(
          StreamTransformer.fromHandlers(
            handleError: (error, stack, sink) {
              sink.add(FailedUpdate(_explain(error)));
              sink.close();
            },
          ),
        );
  }

  ReceiverUpdate _toUpdate(api.ReceiverEvent e) {
    switch (e.kind) {
      case api.ReceiverEventKind.hello:
        return HelloUpdate(deviceName: e.text, platform: e.text2);
      case api.ReceiverEventKind.profile:
        return ProfileUpdate(
          IncomingVideo(
            width: e.width,
            height: e.height,
            fps: e.fps,
            bitrateKbps: e.bitrateKbps,
            rotation: e.rotation,
          ),
        );
      case api.ReceiverEventKind.output:
        return OutputUpdate(
          OutgoingVideo(
            width: e.canvasWidth,
            height: e.canvasHeight,
            rotation: e.rotation,
            device: e.text.isEmpty ? null : e.text,
          ),
        );
      case api.ReceiverEventKind.stats:
        return StatsUpdate(
          LiveStats(
            fps: e.statsFps,
            kbps: e.statsKbps,
            delayMs: e.statsDelayMs,
            frames: e.frames.toInt(),
          ),
        );
      case api.ReceiverEventKind.preview:
        return PreviewUpdate(e.preview);
      case api.ReceiverEventKind.capabilities:
        return CapabilitiesUpdate(
          PhoneCapabilities(
            modes: [
              for (final m in e.modes)
                PhoneMode(
                  width: m.width,
                  height: m.height,
                  available: m.available,
                  maxFps: m.maxFps,
                  reason: m.reason.isEmpty ? null : m.reason,
                ),
            ],
            fpsOptions: e.fpsOptions.toList(),
            front: e.front,
            canSwitch: e.canSwitch,
            streaming: e.streaming,
          ),
        );
      case api.ReceiverEventKind.pairingCode:
        return PairingCodeUpdate(code: e.text, phoneFingerprint: e.text2);
      case api.ReceiverEventKind.paired:
        return PairedUpdate(e.text);
      case api.ReceiverEventKind.pairingDenied:
        return PairingDeniedUpdate(e.text);
      case api.ReceiverEventKind.senderError:
        return SenderErrorUpdate(e.text2.isEmpty ? e.text : e.text2);
      case api.ReceiverEventKind.notice:
        return NoticeUpdate(e.text);
      case api.ReceiverEventKind.ended:
        return const EndedUpdate();
      case api.ReceiverEventKind.failed:
        return FailedUpdate(e.text);
    }
  }

  String _explain(Object error) {
    final text = error.toString();
    return text
        .replaceFirst(RegExp(r'^(AnyhowException|PanicException)\(?'), '')
        .replaceAll(RegExp(r'\)$'), '')
        .trim();
  }

  @override
  Future<void> disconnect() => api.disconnectPhone();

  @override
  Future<String?> startIdleFeed(String device, int width, int height) =>
      api.startIdleFeed(device: device, width: width, height: height);

  @override
  Future<void> stopIdleFeed() => api.stopIdleFeed();

  @override
  Future<String?> confirmPairing(bool accept) async =>
      api.confirmPairing(accept: accept);

  @override
  Future<String?> startStream(int width, int height, int fps) async =>
      api.phoneStartStream(width: width, height: height, fps: fps);

  @override
  Future<String?> stopStream() async => api.phoneStopStream();

  @override
  Future<String?> setFps(int fps) async => api.phoneSetFps(fps: fps);

  @override
  Future<String?> switchCamera({bool? front}) async =>
      api.phoneSwitchCamera(front: front);

  @override
  Future<bool> ffmpegAvailable() => api.ffmpegAvailable();

  @override
  Future<String> computerName() => api.computerName();

  @override
  Future<List<VideoDevice>> listVideoDevices() async {
    final sysfs = Directory('/sys/class/video4linux');
    if (!sysfs.existsSync()) return const [];
    final devices = <VideoDevice>[];
    for (final entry in sysfs.listSync().whereType<Directory>()) {
      final id = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^video\d+$').hasMatch(id)) continue;
      final nameFile = File('${entry.path}/name');
      final name = nameFile.existsSync()
          ? nameFile.readAsStringSync().trim()
          : id;
      devices.add(VideoDevice(path: '/dev/$id', name: name));
    }
    devices.sort((a, b) {
      if (a.isConectDroidCam != b.isConectDroidCam) {
        return a.isConectDroidCam ? -1 : 1;
      }
      return _number(a.path).compareTo(_number(b.path));
    });
    return devices;
  }

  int _number(String path) =>
      int.tryParse(RegExp(r'\d+$').firstMatch(path)?.group(0) ?? '') ?? 0;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/update_models.dart';

/// Onde o app procura versões novas.
abstract interface class ReleaseSource {
  /// A versão mais nova publicada, ou `null` se não há nenhuma com APK.
  Future<ReleaseApk?> latest();
}

/// Releases públicas do repositório no GitHub.
class GitHubReleaseSource implements ReleaseSource {
  GitHubReleaseSource({HttpClient Function()? client})
    : _client = client ?? HttpClient.new;

  static final _url = Uri.parse(
    'https://api.github.com/repos/Eduardo-Lima-Dev/ConectDroidCam/releases?per_page=20',
  );

  final HttpClient Function() _client;

  @override
  Future<ReleaseApk?> latest() async {
    final client = _client()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(_url);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'ConectDroidCam');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw HttpException('GitHub respondeu ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      return json is List ? latestApk(json) : null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Baixa o APK, informando o progresso de 0 a 1.
abstract interface class UpdateDownloader {
  Future<void> download(
    String url,
    String destination, {
    required int expectedSize,
    void Function(double progress)? onProgress,
  });
}

class HttpUpdateDownloader implements UpdateDownloader {
  @override
  Future<void> download(
    String url,
    String destination, {
    required int expectedSize,
    void Function(double progress)? onProgress,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final file = File(destination);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'ConectDroidCam');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('download respondeu ${response.statusCode}');
      }
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (expectedSize > 0) onProgress?.call(received / expectedSize);
        }
      } finally {
        await sink.close();
      }
      // Um download interrompido não pode virar uma instalação.
      if (expectedSize > 0 && received != expectedSize) {
        await file.delete();
        throw const HttpException('o download veio incompleto');
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// Lado nativo: versão instalada, permissão de instalar e a instalação.
abstract interface class UpdaterPlatform {
  Future<int> installedBuild();
  Future<bool> canInstall();
  Future<void> openInstallSettings();
  Future<String> downloadDir();
  Future<void> install(String path);
  Stream<(InstallStatus, String?)> get installStatus;
}

class ChannelUpdaterPlatform implements UpdaterPlatform {
  ChannelUpdaterPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('cdc/updater') {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'installStatus') return;
      final args = (call.arguments as Map<Object?, Object?>?) ?? const {};
      final status = switch (args['status']) {
        'pendingUser' => InstallStatus.pendingUser,
        'success' => InstallStatus.success,
        'conflict' => InstallStatus.conflict,
        'aborted' => InstallStatus.aborted,
        _ => InstallStatus.failure,
      };
      _status.add((status, args['message'] as String?));
    });
  }

  final MethodChannel _channel;
  final _status = StreamController<(InstallStatus, String?)>.broadcast();

  @override
  Future<int> installedBuild() async {
    final info = await _channel.invokeMapMethod<String, Object?>('info');
    return ((info?['versionCode'] as num?) ?? 0).toInt();
  }

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  @override
  Future<String> downloadDir() async =>
      (await _channel.invokeMethod<String>('downloadDir'))!;

  @override
  Future<void> install(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});

  @override
  Stream<(InstallStatus, String?)> get installStatus => _status.stream;
}

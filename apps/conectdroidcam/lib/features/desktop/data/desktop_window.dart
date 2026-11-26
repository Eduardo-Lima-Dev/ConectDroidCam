import 'dart:async';

import 'package:flutter/services.dart';

abstract interface class DesktopWindow {
  Future<void> setInterceptClose(bool value);
  Future<void> show();
  Future<void> hide();
  Future<void> quit();
  Stream<void> get closeRequests;
}

class ChannelDesktopWindow implements DesktopWindow {
  ChannelDesktopWindow({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('cdc/window') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closeRequested') _close.add(null);
    });
  }

  final MethodChannel _channel;
  final _close = StreamController<void>.broadcast();

  @override
  Future<void> setInterceptClose(bool value) =>
      _channel.invokeMethod<void>('setInterceptClose', value);

  @override
  Future<void> show() => _channel.invokeMethod<void>('show');

  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');

  @override
  Future<void> quit() => _channel.invokeMethod<void>('quit');

  @override
  Stream<void> get closeRequests => _close.stream;
}

import 'dart:async';

import 'package:flutter/material.dart';

const pairingCodeLifetime = Duration(minutes: 2);

class PairingCountdown extends StatefulWidget {
  const PairingCountdown({
    super.key,
    required this.expiredText,
    this.lifetime = pairingCodeLifetime,
    this.style,
  });

  final String expiredText;
  final Duration lifetime;
  final TextStyle? style;

  @override
  State<PairingCountdown> createState() => _PairingCountdownState();
}

class _PairingCountdownState extends State<PairingCountdown> {
  late int _seconds = widget.lifetime.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _seconds--);
      if (_seconds <= 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _seconds < 0 ? 0 : _seconds;
    final text = seconds == 0
        ? widget.expiredText
        : 'O código expira em ${seconds ~/ 60}:'
              '${(seconds % 60).toString().padLeft(2, '0')}.';
    return Semantics(
      liveRegion: seconds == 0,
      child: Text(text, style: widget.style),
    );
  }
}

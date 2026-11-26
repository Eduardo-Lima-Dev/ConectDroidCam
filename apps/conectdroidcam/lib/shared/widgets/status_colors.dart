import 'package:flutter/material.dart';

abstract final class StatusColors {
  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color ok(BuildContext context) =>
      _dark(context) ? Colors.greenAccent : const Color(0xFF2E7D32);

  static Color warning(BuildContext context) =>
      _dark(context) ? Colors.amberAccent : const Color(0xFFB45309);
}

import 'package:flutter/material.dart';

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 48});

  static const asset = 'assets/branding/logo.png';

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'Logo do ConectDroidCam',
      errorBuilder: (context, error, stack) => SizedBox.square(
        dimension: size,
        child: Icon(Icons.videocam_outlined, size: size * 0.7),
      ),
    );
  }
}

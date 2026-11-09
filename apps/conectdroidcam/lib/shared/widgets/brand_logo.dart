import 'package:flutter/material.dart';

/// A logo do ConectDroidCam, a mesma usada nos ícones do app.
///
/// O arquivo é gerado por `tools/branding/gerar_icones.py` a partir de
/// `branding/LogoCDC.png`.
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
      // Sem a imagem, o app continua usável.
      errorBuilder: (context, error, stack) => SizedBox.square(
        dimension: size,
        child: Icon(Icons.videocam_outlined, size: size * 0.7),
      ),
    );
  }
}

/// Um arquivo de uma versão publicada nas releases do GitHub: o APK do Android ou o
/// `.flatpak` do Linux.
class ReleaseAsset {
  const ReleaseAsset({
    required this.build,
    required this.tag,
    required this.assetUrl,
    required this.size,
    required this.pageUrl,
  });

  /// Número do build. Vem da tag `build-N`; no Android é também o `versionCode`.
  final int build;
  final String tag;
  final String assetUrl;

  /// Tamanho do arquivo em bytes, para conferir o download.
  final int size;

  /// Página da release, com as notas.
  final String pageUrl;
}

/// Escolhe, entre as releases do GitHub (a resposta de `GET /repos/.../releases`), a mais
/// nova que tenha um APK.
ReleaseAsset? latestApk(List<Object?> releases) =>
    latestRelease(releases, suffix: '.apk');

/// A release mais nova que tenha um arquivo terminado em [suffix]. Só valem as tags
/// `build-N`, que o workflow cria a cada push na `main`; rascunhos e pré-lançamentos ficam de
/// fora.
ReleaseAsset? latestRelease(List<Object?> releases, {required String suffix}) {
  final tagRe = RegExp(r'^build-(\d+)$');
  ReleaseAsset? best;
  for (final item in releases.whereType<Map<String, Object?>>()) {
    if (item['draft'] == true || item['prerelease'] == true) continue;
    final tag = item['tag_name'];
    if (tag is! String) continue;
    final match = tagRe.firstMatch(tag);
    if (match == null) continue;
    final build = int.parse(match.group(1)!);
    final assets = item['assets'];
    if (assets is! List) continue;
    final apk = assets.whereType<Map<String, Object?>>().where((a) {
      final name = a['name'];
      return name is String && name.toLowerCase().endsWith(suffix);
    }).firstOrNull;
    if (apk == null) continue;
    final url = apk['browser_download_url'];
    final size = apk['size'];
    if (url is! String || size is! int) continue;
    if (best == null || build > best.build) {
      best = ReleaseAsset(
        build: build,
        tag: tag,
        assetUrl: url,
        size: size,
        pageUrl: item['html_url'] is String ? item['html_url']! as String : '',
      );
    }
  }
  return best;
}

/// Resultado da instalação, informado pelo Android.
enum InstallStatus {
  /// O Android abriu a tela de confirmação.
  pendingUser,
  success,

  /// A versão instalada tem outra assinatura: o Android recusa atualizar por cima.
  conflict,

  /// O usuário cancelou.
  aborted,
  failure,
}

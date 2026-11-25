/// Uma versão do app Android publicada nas releases do GitHub.
class ReleaseApk {
  const ReleaseApk({
    required this.build,
    required this.tag,
    required this.apkUrl,
    required this.size,
    required this.pageUrl,
  });

  /// Número do build (`versionCode` do Android). Vem da tag `build-N`.
  final int build;
  final String tag;
  final String apkUrl;

  /// Tamanho do APK em bytes, para conferir o download.
  final int size;

  /// Página da release, com as notas.
  final String pageUrl;
}

/// Escolhe, entre as releases do GitHub (a resposta de `GET /repos/.../releases`), a mais
/// nova que tenha um APK. Só valem as tags `build-N`, que o workflow cria a cada push na
/// `main`; rascunhos e pré-lançamentos ficam de fora.
ReleaseApk? latestApk(List<Object?> releases) {
  final tagRe = RegExp(r'^build-(\d+)$');
  ReleaseApk? best;
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
      return name is String && name.toLowerCase().endsWith('.apk');
    }).firstOrNull;
    if (apk == null) continue;
    final url = apk['browser_download_url'];
    final size = apk['size'];
    if (url is! String || size is! int) continue;
    if (best == null || build > best.build) {
      best = ReleaseApk(
        build: build,
        tag: tag,
        apkUrl: url,
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

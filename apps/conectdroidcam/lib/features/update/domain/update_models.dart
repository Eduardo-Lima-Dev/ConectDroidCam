class ReleaseAsset {
  const ReleaseAsset({
    required this.build,
    required this.tag,
    required this.assetUrl,
    required this.size,
    required this.pageUrl,
  });

  final int build;
  final String tag;
  final String assetUrl;

  final int size;

  final String pageUrl;
}

ReleaseAsset? latestApk(List<Object?> releases) =>
    latestRelease(releases, suffix: '.apk');

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

enum InstallStatus { pendingUser, success, conflict, aborted, failure }

/// Mục danh mục game từ `/v1/config` → `games[]` (server đã lọc).
class GameCatalogEntry {
  const GameCatalogEntry({
    required this.id,
    required this.version,
    required this.url,
    required this.sha256,
    required this.sig,
    required this.nameVi,
    required this.nameEn,
    this.size,
    this.apiLevel = 1,
    this.mode = 'turn',
    this.disabled = false,
  });

  final String id;
  final String version;
  final String url;
  final String sha256;
  final String sig;
  final String nameVi;
  final String nameEn;
  final int? size;
  final int apiLevel;
  final String mode;
  final bool disabled;

  String name(String lang) => lang == 'vi' ? nameVi : nameEn;

  static GameCatalogEntry? tryParse(Map<String, dynamic> m) {
    final id = m['id'], version = m['version'], url = m['url'], sha = m['sha256'], sig = m['sig'];
    if (id is! String || version is! String || url is! String || sha is! String || sig is! String) return null;
    final name = m['name'];
    final vi = name is Map && name['vi'] is String ? name['vi'] as String : id;
    final en = name is Map && name['en'] is String ? name['en'] as String : vi;
    return GameCatalogEntry(
      id: id,
      version: version,
      url: url,
      sha256: sha,
      sig: sig,
      nameVi: vi,
      nameEn: en,
      size: m['size'] is int ? m['size'] as int : null,
      apiLevel: m['apiLevel'] is int ? m['apiLevel'] as int : 1,
      mode: m['mode'] is String ? m['mode'] as String : 'turn',
      disabled: m['disabled'] == true,
    );
  }

  static List<GameCatalogEntry> parseAll(List<Map<String, dynamic>> raw) =>
      raw.map(tryParse).whereType<GameCatalogEntry>().where((e) => !e.disabled).toList(growable: false);
}

/// Bản game đã cài trên máy (thư mục đã giải nén).
class InstalledGame {
  const InstalledGame({required this.id, required this.version, required this.sha256, required this.dir});
  final String id;
  final String version;
  final String sha256;
  final String dir;
}

/// API level mà app này hỗ trợ; game đòi cao hơn sẽ bị bỏ qua.
const int kGameApiLevel = 1;

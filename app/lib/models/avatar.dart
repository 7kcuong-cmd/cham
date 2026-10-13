/// Ảnh đại diện: ảnh có sẵn (`preset`, mã `p01`…`p12`) hoặc ảnh tải lên (`upload`, kèm phiên bản để cache).
class Avatar {
  const Avatar.preset(String id)
      : kind = 'preset',
        presetId = id,
        ver = 0;
  const Avatar.upload(int version)
      : kind = 'upload',
        presetId = null,
        ver = version;

  final String kind;
  final String? presetId;
  final int ver;

  bool get isPreset => kind == 'preset';

  /// `null` nếu chưa đặt ảnh hoặc dữ liệu sai.
  static Avatar? tryParse(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    if (kind == 'preset' && json['id'] is String) return Avatar.preset(json['id'] as String);
    if (kind == 'upload' && json['ver'] is num) return Avatar.upload((json['ver'] as num).toInt());
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Avatar && other.kind == kind && other.presetId == presetId && other.ver == ver;

  @override
  int get hashCode => Object.hash(kind, presetId, ver);
}

/// Mã ảnh có sẵn (khớp `^p\d{2}$` của server).
const List<String> kPresetAvatarIds = <String>[
  'p01', 'p02', 'p03', 'p04', 'p05', 'p06', 'p07', 'p08', 'p09', 'p10', 'p11', 'p12',
];

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/media_pick_guard.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';
import '../watch/watch_runtime.dart';

/// Kết quả của bộ chọn trong app: đã chọn / người dùng đóng / không đọc được thư viện (xin quyền bị từ chối).
sealed class MediaPickResult {
  const MediaPickResult();
}

final class MediaPicked extends MediaPickResult {
  const MediaPicked(this.media);
  final PickedMedia media;
}

final class MediaPickCancelled extends MediaPickResult {
  const MediaPickCancelled();
}

final class MediaPickUnavailable extends MediaPickResult {
  const MediaPickUnavailable();
}

/// Bộ chọn video/nhạc NẰM TRONG app (hộp trượt lên): không mở màn hình hệ thống nên cuộc gọi không bị đưa ra nền.
/// Quyền đọc media do hệ thống hỏi một lần (hộp thoại nhỏ, cũng được [MediaPickGuard] che).
Future<MediaPickResult> showMediaPicker(BuildContext context, {required bool audio}) async {
  final type = audio ? RequestType.audio : RequestType.video;
  final PermissionState perm;
  try {
    perm = await MediaPickGuard.run(
      () => PhotoManager.requestPermissionExtend(
        requestOption: PermissionRequestOption(androidPermission: AndroidPermission(type: type, mediaLocation: false)),
      ),
    );
  } on Object {
    return const MediaPickUnavailable();
  }
  if (!perm.hasAccess) return const MediaPickUnavailable();
  if (!context.mounted) return const MediaPickCancelled();
  final r = await showModalBottomSheet<PickedMedia>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceHigh,
    builder: (ctx) => _MediaPickerBody(audio: audio),
  );
  return r == null ? const MediaPickCancelled() : MediaPicked(r);
}

class _MediaPickerBody extends StatefulWidget {
  const _MediaPickerBody({required this.audio});
  final bool audio;

  @override
  State<_MediaPickerBody> createState() => _MediaPickerBodyState();
}

class _MediaPickerBodyState extends State<_MediaPickerBody> {
  static const _page = 60;
  final List<AssetEntity> _items = <AssetEntity>[];
  AssetPathEntity? _album;
  int _next = 0;
  bool _loading = true;
  bool _more = true;
  bool _picking = false;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) unawaited(_load());
    });
    unawaited(_init());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final albums = await PhotoManager.getAssetPathList(
        type: widget.audio ? RequestType.audio : RequestType.video,
        onlyAll: true,
      );
      _album = albums.isEmpty ? null : albums.first;
    } on Object {
      _album = null;
    }
    await _load();
  }

  Future<void> _load() async {
    final a = _album;
    if (a == null) {
      if (mounted) setState(() { _loading = false; _more = false; });
      return;
    }
    if (!_more || (_loading && _items.isNotEmpty)) return;
    _loading = true;
    try {
      final got = await a.getAssetListPaged(page: _next, size: _page);
      _next++;
      if (!mounted) return;
      setState(() {
        _items.addAll(got);
        _more = got.length == _page;
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() { _loading = false; _more = false; });
    }
  }

  Future<void> _choose(AssetEntity e) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final File? f = await e.originFile;
      if (f == null) {
        if (mounted) setState(() => _picking = false);
        return;
      }
      final name = (await e.titleAsync).isNotEmpty ? await e.titleAsync : f.uri.pathSegments.last;
      final size = await f.length();
      if (mounted) Navigator.of(context).pop(PickedMedia(path: f.path, name: name, size: size));
    } on Object {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height * 0.7;
    return SafeArea(
      child: SizedBox(
        height: h,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Text(
                widget.audio ? tr(context, 'Chọn bài hát', 'Pick a song') : tr(context, 'Chọn video', 'Pick a video'),
                style: AppText.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: _loading
                          ? const CircularProgressIndicator()
                          : Text(tr(context, 'Không có tệp nào trên máy.', 'No files on this device.'),
                              style: AppText.body.copyWith(color: AppColors.textSecondary)),
                    )
                  : widget.audio
                      ? ListView.builder(
                          controller: _scroll,
                          itemCount: _items.length,
                          itemBuilder: (_, i) => _AudioTile(asset: _items[i], onTap: () => _choose(_items[i])),
                        )
                      : GridView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(AppSpace.xs),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => _VideoTile(asset: _items[i], onTap: () => _choose(_items[i])),
                        ),
            ),
            if (_picking) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

String _dur(int sec) => '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.asset, required this.onTap});
  final AssetEntity asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(const ThumbnailSize(240, 240)),
            builder: (_, snap) => snap.data == null
                ? const ColoredBox(color: AppColors.bg)
                : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: AppColors.scrim, borderRadius: BorderRadius.circular(4)),
              child: Text(_dur(asset.duration), style: const TextStyle(color: AppColors.textPrimary, fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioTile extends StatelessWidget {
  const _AudioTile({required this.asset, required this.onTap});
  final AssetEntity asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: asset.titleAsync,
      builder: (_, snap) => ListTile(
        leading: const Icon(Icons.music_note_rounded),
        title: Text(snap.data ?? '…', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Text(_dur(asset.duration), style: AppText.caption),
        onTap: onTap,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/haptics.dart';
import '../core/plurals.dart';
import '../models/download_models.dart';
import '../services/compress_service.dart';
import '../services/device_media_service.dart';
import '../state/downloads_controller.dart';
import '../theme/duck_theme.dart';
import '../widgets/duck_motion.dart';
import '../widgets/media/media_thumb.dart';

/// How the file list is ordered.
enum _FolderSort {
  newest('Newest'),
  oldest('Oldest'),
  name('Name'),
  largest('Largest');

  const _FolderSort(this.label);
  final String label;
}

/// Browses one device media folder, with rename, delete and multi-select.
///
/// These act on files the user owns rather than on Duck's own downloads, so
/// every destructive step is confirmed and every platform refusal is reported
/// back plainly — under scoped storage the system, not the app, has the final
/// say on whether an edit happens.
class DeviceFolderSheet extends StatefulWidget {
  const DeviceFolderSheet({
    super.key,
    required this.folder,
    required this.controller,
  });

  final DeviceMediaFolder folder;
  final DuckDownloadsController controller;

  @override
  State<DeviceFolderSheet> createState() => _DeviceFolderSheetState();
}

class _DeviceFolderSheetState extends State<DeviceFolderSheet> {
  late List<DownloadItem> _items = List.of(widget.folder.items);

  /// Library metadata (size, duration) keyed by path.
  ///
  /// MediaStore already returned these with the folder listing, so the size
  /// and duration on every row cost nothing extra to show.
  late Map<String, DeviceMediaEntry> _entries = {
    for (final entry in widget.folder.entries) entry.path: entry,
  };

  final Set<String> _selected = {};
  bool _selecting = false;
  bool _busy = false;
  _FolderSort _sort = _FolderSort.newest;
  String _query = '';
  double? _jobProgress;

  bool get _hasSelection => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.controller.addBackInterceptor(_handleBack);
  }

  @override
  void dispose() {
    widget.controller.removeBackInterceptor(_handleBack);
    super.dispose();
  }

  /// Back undoes the last thing the user turned on, before it closes the sheet.
  ///
  /// Closing the whole folder because someone tapped back while half a dozen
  /// files were selected — or while a search was narrowing the list — throws
  /// away work they have to redo by hand. Selection first, since it is the
  /// mode most likely to have cost them taps.
  bool _handleBack() {
    if (_selecting) {
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      return true;
    }
    if (_query.isNotEmpty) {
      setState(() => _query = '');
      return true;
    }
    return false;
  }

  /// The rows actually on screen, after the search box and sort order.
  ///
  /// Selection is tracked by id rather than index precisely so that filtering
  /// and re-sorting cannot silently retarget an action at the wrong file.
  List<DownloadItem> get _visible {
    final needle = _query.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? List.of(_items)
        : _items
            .where((item) => item.title.toLowerCase().contains(needle))
            .toList();

    int bySize(DownloadItem a, DownloadItem b) {
      final sizeA = _entries[a.filePath]?.size ?? 0;
      final sizeB = _entries[b.filePath]?.size ?? 0;
      return sizeB.compareTo(sizeA);
    }

    switch (_sort) {
      case _FolderSort.newest:
        filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _FolderSort.oldest:
        filtered.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _FolderSort.name:
        filtered.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case _FolderSort.largest:
        filtered.sort(bySize);
    }
    return filtered;
  }

  void _toggleSelectionMode() {
    DuckHaptics.selection();
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleSelected(DownloadItem item) {
    DuckHaptics.selection();
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  void _selectAll() {
    DuckHaptics.selection();
    final visible = _visible;
    setState(() {
      // Scoped to the filtered list: with a search active, "ALL" meaning
      // every file in the folder — including ones the user cannot see — is a
      // very easy way to delete the wrong thing.
      if (visible.every((item) => _selected.contains(item.id))) {
        _selected.removeAll(visible.map((item) => item.id));
      } else {
        _selected.addAll(visible.map((item) => item.id));
      }
    });
  }

  List<DownloadItem> get _selectedItems =>
      _items.where((item) => _selected.contains(item.id)).toList();

  void _report(String message, {bool success = true}) {
    if (!mounted) return;
    success ? DuckHaptics.success() : DuckHaptics.error();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Maps the platform's tri-state answer onto user-facing copy.
  ///
  /// A decline is not a failure: on Android 11+ the system asks the user
  /// directly, and saying no is a perfectly ordinary outcome that must not be
  /// dressed up as an error.
  void _reportEdit(DeviceMediaEditOutcome outcome, String successMessage) {
    switch (outcome.result) {
      case DeviceMediaEditResult.success:
        _report(successMessage);
      case DeviceMediaEditResult.declined:
        _report('Permission denied by the system.', success: false);
      case DeviceMediaEditResult.failed:
        // Prefer the native reason: "Could not delete 2 of 5 files" tells the
        // user what actually happened, the generic line tells them nothing.
        _report(
          outcome.message ?? 'Could not complete that change.',
          success: false,
        );
    }
  }

  /// Pulls this folder back from the media library after an edit.
  ///
  /// Nothing here patches the list from what the app *asked* Android to do.
  /// Every previous version did, and it is why rename and move looked broken:
  /// the row redrew with the new name the instant the call returned, while the
  /// library — the thing every other screen and every other app reads — still
  /// held the old one, or held a name Android had uniquified, or had not
  /// changed at all because the write was refused after the consent dialog.
  /// Re-reading costs one MediaStore query and cannot drift.
  Future<void> _reload() async {
    final type = widget.folder.type;
    // A type-agnostic listing (the move-destination picker builds those) has
    // nothing to re-read itself against.
    if (type == null) return;

    final fresh = await widget.controller.refreshDeviceFolder(
      path: widget.folder.path,
      type: type,
    );
    if (!mounted) return;
    setState(() {
      _items = fresh == null ? const [] : List.of(fresh.items);
      _entries = {
        for (final entry in fresh?.entries ?? const <DeviceMediaEntry>[])
          entry.path: entry,
      };
      // Selection is keyed on the file path, and both rename and move change
      // it — so anything that no longer exists under its old path has to drop
      // out rather than sit there aimed at a file that is gone.
      final live = _items.map((item) => item.id).toSet();
      _selected.retainWhere(live.contains);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  // ── Move ──────────────────────────────────────────────────────────────────

  Future<void> _move(List<DownloadItem> targets) async {
    if (targets.isEmpty) return;
    final colors = DuckColors.of(context);
    final folders = await widget.controller.deviceDestinationFolders();
    if (!mounted) return;

    final candidates = folders
        .where((folder) => folder.path != widget.folder.path)
        .toList();
    if (candidates.isEmpty) {
      _report('No other folders to move into.', success: false);
      return;
    }

    final destination = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: colors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Move ${plural(targets.length, 'file')} to…',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (context, index) {
                  final folder = candidates[index];
                  return ListTile(
                    leading: Icon(Icons.folder_rounded, color: colors.gold),
                    title: Text(
                      folder.name,
                      style: TextStyle(color: colors.text),
                    ),
                    subtitle: Text(
                      folder.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                    onTap: () => Navigator.pop(context, folder.path),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (destination == null || !mounted) return;

    setState(() => _busy = true);
    final outcome = await widget.controller.moveDeviceMedia(
      paths: [
        for (final item in targets)
          if (item.filePath != null) item.filePath!,
      ],
      targetFolder: destination,
    );
    if (outcome.result == DeviceMediaEditResult.success) await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    _reportEdit(outcome, 'Moved ${plural(targets.length, 'file')}');
  }

  // ── Tags ──────────────────────────────────────────────────────────────────

  Future<void> _editTags(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) return;
    final colors = DuckColors.of(context);

    final title = TextEditingController(text: item.title);
    final artist = TextEditingController(text: item.artist ?? '');
    final album = TextEditingController(text: item.album ?? '');

    InputDecoration field(String label) => InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: colors.textMuted),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: colors.border),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: colors.gold),
          ),
        );

    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Edit details', style: TextStyle(color: colors.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              style: TextStyle(color: colors.text),
              decoration: field('Title'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: artist,
              style: TextStyle(color: colors.text),
              decoration: field('Artist'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: album,
              style: TextStyle(color: colors.text),
              decoration: field('Album'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('CANCEL', style: TextStyle(color: colors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('SAVE', style: TextStyle(color: colors.gold)),
          ),
        ],
      ),
    );
    if (save != true || !mounted) return;

    setState(() => _busy = true);
    final outcome = await widget.controller.updateDeviceMediaTags(
      path: path,
      title: title.text.trim().isEmpty ? null : title.text.trim(),
      artist: artist.text.trim().isEmpty ? null : artist.text.trim(),
      album: album.text.trim().isEmpty ? null : album.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (outcome.result == DeviceMediaEditResult.success) {
        _items = [
          for (final entry in _items)
            if (entry.id == item.id)
              entry.copyWith(
                title: title.text.trim(),
                artist: artist.text.trim(),
                album: album.text.trim(),
              )
            else
              entry,
        ];
      }
    });
    _reportEdit(outcome, 'Details updated');
  }

  // ── Compress ──────────────────────────────────────────────────────────────

  Future<void> _compress(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) return;
    final colors = DuckColors.of(context);
    final isAudio = item.type == DownloadType.audio;

    final level = await showModalBottomSheet<CompressLevel>(
      context: context,
      backgroundColor: colors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Compress',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final option in CompressLevel.values)
              ListTile(
                leading: Icon(Icons.compress_rounded, color: colors.gold),
                title: Text(option.label, style: TextStyle(color: colors.text)),
                subtitle: Text(
                  isAudio
                      ? '${option.audioBitrate} kbps'
                      : option.scale == null
                          ? 'Original size, lighter encoding'
                          : 'Up to ${option.scale}p',
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
                onTap: () => Navigator.pop(context, option),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'The original is kept — the smaller copy is saved separately.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
    if (level == null || !mounted) return;

    setState(() {
      _busy = true;
      _jobProgress = 0;
    });
    try {
      final result = isAudio
          ? await CompressService.compressAudio(
              inputPath: path,
              bitrate: level.audioBitrate,
              onProgress: (value) {
                if (mounted) setState(() => _jobProgress = value);
              },
            )
          : await CompressService.compressVideo(
              inputPath: path,
              level: level,
              onProgress: (value) {
                if (mounted) setState(() => _jobProgress = value);
              },
            );
      if (!mounted) return;
      final saved = (result.savedFraction * 100).round();
      _report('Compressed — $saved% smaller');
    } catch (error) {
      if (!mounted) return;
      _report(_readableError(error), success: false);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _jobProgress = null;
        });
      }
    }
  }

  /// Strips Dart's "Exception: " prefix so the message reads as a sentence.
  String _readableError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  Future<void> _rename(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) return;

    final extension = p.extension(path);
    final controller = TextEditingController(
      text: p.basenameWithoutExtension(path),
    );
    final colors = DuckColors.of(context);

    final newBaseName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Rename', style: TextStyle(color: colors.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: colors.text),
          decoration: InputDecoration(
            // The extension is fixed: changing it would leave a file the
            // system can no longer identify.
            suffixText: extension,
            suffixStyle: TextStyle(color: colors.textMuted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colors.border),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colors.gold),
            ),
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: TextStyle(color: colors.textMuted)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim()),
            child: Text('RENAME', style: TextStyle(color: colors.gold)),
          ),
        ],
      ),
    );

    final trimmed = newBaseName?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (trimmed == p.basenameWithoutExtension(path)) return;

    setState(() => _busy = true);
    final outcome = await widget.controller.renameDeviceMedia(
      path: path,
      newName: '$trimmed$extension',
    );
    // Re-read rather than write '$trimmed$extension' into the row. Android may
    // have landed on a different name — it appends " (1)" rather than failing
    // when something else claimed the name in between — and a row showing a
    // name no file has is worse than no rename at all.
    if (outcome.result == DeviceMediaEditResult.success) await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    _reportEdit(outcome, 'Renamed');
  }

  Future<void> _deleteItems(List<DownloadItem> targets) async {
    if (targets.isEmpty) return;
    final colors = DuckColors.of(context);
    final many = targets.length > 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          many ? 'Delete ${plural(targets.length, 'file')}?' : 'Delete this file?',
          style: TextStyle(color: colors.text),
        ),
        content: Text(
          'This removes the file from your device. It cannot be undone.',
          style: TextStyle(color: colors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('CANCEL', style: TextStyle(color: colors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'DELETE',
              style: TextStyle(color: DuckColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    // One call for the whole batch: Android shows a single consent sheet
    // rather than one dialog per file.
    final outcome = await widget.controller.deleteDeviceMedia([
      for (final item in targets)
        if (item.filePath != null) item.filePath!,
    ]);
    if (outcome.result == DeviceMediaEditResult.success) await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    _reportEdit(
      outcome,
      'Deleted ${plural(targets.length, 'file')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.78,
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          _buildHeader(colors),
          if (_items.length > 8 || _query.isNotEmpty) _buildSearch(colors),
          if (_busy)
            LinearProgressIndicator(
              color: colors.gold,
              minHeight: 2,
              // Determinate while a compress job reports progress, so a long
              // encode does not look like a hang.
              value: _jobProgress,
            ),
          Divider(height: 1, color: colors.divider),
          Expanded(child: _buildList(colors)),
        ],
      ),
    );
  }



  bool get _allVisibleSelected {
    final visible = _visible;
    return visible.isNotEmpty &&
        visible.every((item) => _selected.contains(item.id));
  }

  /// "128 items · 2.4 GB", or the filtered count while searching.
  String _folderSubtitle() {
    if (_selecting) return '${_selected.length} selected';
    final visible = _visible.length;
    if (_query.isNotEmpty) {
      return '$visible of ${plural(_items.length, 'item')}';
    }
    final bytes = _items.fold<int>(
      0,
      (sum, item) => sum + (_entries[item.filePath]?.size ?? 0),
    );
    final size = bytes <= 0 ? '' : ' \u00b7 ${_formatBytes(bytes)}';
    return '${plural(_items.length, 'item')}$size';
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (minutes < 60) return '$minutes:$seconds';
    final hours = duration.inHours;
    final mins = minutes.remainder(60).toString().padLeft(2, '0');
    return '$hours:$mins:$seconds';
  }

  Widget _buildList(DuckColors colors) {
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? 'This folder is empty.' : 'No files match "$_query".',
          style: TextStyle(color: colors.textMuted, fontSize: 15),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => EntranceFade(
        index: index,
        child: _buildRow(visible[index], colors),
      ),
    );
  }

  Widget _buildSearch(DuckColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        style: TextStyle(color: colors.text, fontSize: 14),
        onChanged: (value) => setState(() => _query = value),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search this folder',
          hintStyle: TextStyle(color: colors.textMuted, fontSize: 14),
          prefixIcon: Icon(Icons.search, color: colors.textMuted, size: 20),
          filled: true,
          fillColor: colors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(DuckColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Icon(
            _selecting ? Icons.checklist_rounded : Icons.folder,
            color: colors.gold,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selecting ? '${_selected.length} selected' : widget.folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _folderSubtitle(),
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          if (_selecting) ...[
            TextButton(
              onPressed: _items.isEmpty ? null : _selectAll,
              child: Text(
                _allVisibleSelected ? 'NONE' : 'ALL',
                style: TextStyle(color: colors.gold, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Move selected',
              onPressed: _hasSelection && !_busy
                  ? () => _move(_selectedItems)
                  : null,
              icon: Icon(Icons.drive_file_move_outline, color: colors.text),
            ),
            IconButton(
              tooltip: 'Delete selected',
              onPressed: _hasSelection && !_busy
                  ? () => _deleteItems(_selectedItems)
                  : null,
              icon: const Icon(Icons.delete_outline, color: DuckColors.danger),
            ),
          ] else
            PopupMenuButton<_FolderSort>(
              tooltip: 'Sort',
              color: colors.panel,
              icon: Icon(Icons.sort_rounded, color: colors.text),
              onSelected: (value) => setState(() => _sort = value),
              itemBuilder: (context) => [
                for (final option in _FolderSort.values)
                  PopupMenuItem(
                    value: option,
                    child: Row(
                      children: [
                        Icon(
                          option == _sort
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: option == _sort ? colors.gold : colors.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Text(option.label, style: TextStyle(color: colors.text)),
                      ],
                    ),
                  ),
              ],
            ),
          IconButton(
            tooltip: _selecting ? 'Done' : 'Select',
            onPressed: _items.isEmpty ? null : _toggleSelectionMode,
            icon: Icon(
              _selecting ? Icons.close : Icons.checklist_rounded,
              color: colors.text,
            ),
          ),
        ],
      ),
    );
  }


  /// "MP4 · 12.4 MB · 3:24" — whatever the library actually knows.
  String _rowSubtitle(DownloadItem item) {
    final entry = _entries[item.filePath];
    final parts = <String>[];

    final extension = item.filePath == null
        ? ''
        : p.extension(item.filePath!).replaceFirst('.', '').toUpperCase();
    if (extension.isNotEmpty) parts.add(extension);
    if (entry != null && entry.size > 0) parts.add(entry.readableSize);
    if (entry?.duration != null) parts.add(_formatDuration(entry!.duration!));

    if (parts.isEmpty && item.filePath != null) {
      return p.basename(p.dirname(item.filePath!));
    }
    return parts.join(' \u00b7 ');
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label,
    DuckColors colors, {
    bool danger = false,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: danger ? DuckColors.danger : colors.gold, size: 18),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: colors.text)),
        ],
      ),
    );
  }

  Widget _buildRow(DownloadItem item, DuckColors colors) {
    final selected = _selected.contains(item.id);

    return Pressable(
      haptics: false,
      onTap: () {
        if (_selecting) {
          _toggleSelected(item);
        } else {
          widget.controller.openPlayer(item, galleryItems: _visible);
        }
      },
      // Long-press is the shortcut into selection mode everywhere else in the
      // system, so it works here too rather than forcing a trip to the toolbar.
      onLongPress: () {
        if (!_selecting) setState(() => _selecting = true);
        _toggleSelected(item);
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected
              ? colors.gold.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.gold : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            if (_selecting)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  color: selected ? colors.gold : colors.textMuted,
                  size: 22,
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: MediaThumb(
                url: item.thumbnail,
                filePath: item.filePath,
                width: 52,
                height: 52,
                radius: 8,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.text, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _rowSubtitle(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (!_selecting)
              PopupMenuButton<String>(
                enabled: !_busy,
                color: colors.panel,
                icon: Icon(Icons.more_vert, color: colors.textMuted, size: 20),
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      _rename(item);
                    case 'details':
                      _editTags(item);
                    case 'move':
                      _move([item]);
                    case 'compress':
                      _compress(item);
                    case 'delete':
                      _deleteItems([item]);
                  }
                },
                itemBuilder: (context) => [
                  _menuItem('rename', Icons.drive_file_rename_outline,
                      'Rename', colors),
                  _menuItem('details', Icons.edit_note_rounded,
                      'Edit details', colors),
                  _menuItem('move', Icons.drive_file_move_outline,
                      'Move to…', colors),
                  // Images have nothing to re-encode through this path.
                  if (item.type != DownloadType.image)
                    _menuItem('compress', Icons.compress_rounded,
                        'Compress', colors),
                  _menuItem('delete', Icons.delete_outline, 'Delete', colors,
                      danger: true),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

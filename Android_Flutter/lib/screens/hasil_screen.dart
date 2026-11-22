import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/image_service.dart';
import '../state/editor_controller.dart';
import '../widgets/checkerboard.dart';

/// Layar Hasil (PRD F3–F6, F8): pratinjau checkerboard + tahan lihat asli, ganti warna latar,
/// slider kehalusan tepi (feather) & ambang mask (threshold), simpan ke Galeri, dan Bagikan.
class HasilScreen extends StatefulWidget {
  const HasilScreen({super.key});

  @override
  State<HasilScreen> createState() => _HasilScreenState();
}

class _HasilScreenState extends State<HasilScreen> {
  bool _comparing = false;
  bool _edgePanelOpen = false;
  double _featherDraft = 1.5;
  bool _useHardThresholdDraft = false;
  double _thresholdDraft = 0.5;
  String? _syncedHistoryId;

  void _syncDraftFromResult(EditorResult res) {
    if (_syncedHistoryId == (res.historyId ?? res.sourceName)) return;
    _syncedHistoryId = res.historyId ?? res.sourceName;
    _featherDraft = res.feather;
    _useHardThresholdDraft = res.hardThreshold != null;
    _thresholdDraft = res.hardThreshold ?? 0.5;
  }

  String _formatMs(double ms) {
    if (ms < 1000) return '${ms.round()} ms';
    return '${(ms / 1000).toStringAsFixed(2).replaceAll('.', ',')} dtk';
  }

  Future<void> _pickCustomColor(EditorController ctrl) async {
    final picked = await showCustomColorDialog(context, ctrl.customColorRgb);
    if (picked != null) {
      ctrl.selectCustomColor(picked);
    }
  }

  Future<void> _applyEdgeDraft(EditorController ctrl) async {
    await ctrl.updateEdgeSettings(
      feather: double.parse(_featherDraft.toStringAsFixed(1)),
      hardThreshold: _useHardThresholdDraft
          ? double.parse(_thresholdDraft.toStringAsFixed(2))
          : null,
    );
  }

  Future<void> _resetEdgeDraft(EditorController ctrl) async {
    setState(() {
      _featherDraft = 1.5;
      _useHardThresholdDraft = false;
      _thresholdDraft = 0.5;
    });
    await _applyEdgeDraft(ctrl);
  }

  Future<void> _save(EditorController ctrl, ExportFormat format) async {
    final saved = await ctrl.saveResult(format: format);
    if (!mounted) return;
    if (saved != null) {
      final kb = (saved.byteSize / 1024).round();
      final sizeTxt = kb >= 1024
          ? '${(saved.byteSize / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB'
          : '$kb KB';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Tersimpan di Galeri › ${saved.album}/${saved.fileName} '
            '(${saved.width}×${saved.height}, $sizeTxt)',
          ),
        ),
      );
    } else if (ctrl.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ctrl.error!)),
      );
    }
  }

  Future<void> _share(EditorController ctrl) async {
    await ctrl.shareResult();
    if (!mounted) return;
    if (ctrl.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ctrl.error!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<EditorController>();
    final res = ctrl.result;
    final cs = Theme.of(context).colorScheme;

    if (res == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Hasil')),
        body: const Center(child: Text('Belum ada hasil.')),
      );
    }

    _syncDraftFromResult(res);

    final bgRgb = ctrl.bgColorRgb;
    final hasSolidBg = bgRgb != null;
    final busy = ctrl.isBusyAction;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hasil'),
        actions: [
          TextButton.icon(
            onPressed: busy
                ? null
                : () {
                    ctrl.resetSession();
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  },
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
            label: const Text('Foto lain'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
          children: [
            // Stage pratinjau + tahan untuk lihat asli (PRD F3)
            Listener(
              onPointerDown: (_) => setState(() => _comparing = true),
              onPointerUp: (_) => setState(() => _comparing = false),
              onPointerCancel: (_) => setState(() => _comparing = false),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  height: 320,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_comparing)
                        ColoredBox(
                          color: cs.surfaceContainerHighest,
                          child: Image.memory(res.originalBytes, fit: BoxFit.contain),
                        )
                      else if (bgRgb == null)
                        CheckerboardBackground(
                          child: Image.memory(res.previewCutoutPng, fit: BoxFit.contain),
                        )
                      else
                        ColoredBox(
                          color: Color(0xFF000000 | bgRgb),
                          child: Image.memory(res.previewCutoutPng, fit: BoxFit.contain),
                        ),
                      if (ctrl.isRefining)
                        ColoredBox(
                          color: Colors.black.withValues(alpha: 0.35),
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      Positioned(
                        left: 12,
                        bottom: 12,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.62),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _comparing ? 'Foto asli' : 'Tahan untuk lihat asli',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Pilihan warna latar (PRD F4)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final preset in BgPreset.defaults)
                  _SwatchItem(
                    label: preset.label,
                    rgb: preset.rgb,
                    selected: bgRgb == preset.rgb,
                    onTap: () => ctrl.selectBackground(preset.rgb),
                  ),
                _SwatchItem(
                  label: 'Kustom',
                  rgb: ctrl.customColorRgb,
                  isCustom: true,
                  selected: ctrl.isCustomBg,
                  onTap: () => _pickCustomColor(ctrl),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Pengaturan Kehalusan Tepi & Ambang Mask (PRD F8)
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: Column(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _edgePanelOpen = !_edgePanelOpen),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(
                        children: [
                          Icon(Icons.tune, size: 18, color: cs.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Pengaturan Tepi · Feather ${_featherDraft.toStringAsFixed(1).replaceAll('.', ',')} px'
                              '${_useHardThresholdDraft ? ' · Ambang ${_thresholdDraft.toStringAsFixed(2).replaceAll('.', ',')}' : ' · Halus'}',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                          ),
                          Icon(
                            _edgePanelOpen ? Icons.expand_less : Icons.expand_more,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_edgePanelOpen) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Kehalusan tepi (Feather)',
                                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                '${_featherDraft.toStringAsFixed(1).replaceAll('.', ',')} px',
                                style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700, fontSize: 12.5),
                              ),
                            ],
                          ),
                          Slider(
                            value: _featherDraft,
                            min: 0.0,
                            max: 5.0,
                            divisions: 10,
                            label: '${_featherDraft.toStringAsFixed(1)} px',
                            onChanged: busy ? null : (v) => setState(() => _featherDraft = v),
                            onChangeEnd: busy ? null : (_) => _applyEdgeDraft(ctrl),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Expanded(
                                child: Text(
                                  'Potong tegas (Ambang mask)',
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                ),
                              ),
                              Switch(
                                value: _useHardThresholdDraft,
                                onChanged: busy
                                    ? null
                                    : (v) {
                                        setState(() => _useHardThresholdDraft = v);
                                        _applyEdgeDraft(ctrl);
                                      },
                              ),
                            ],
                          ),
                          if (_useHardThresholdDraft) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Ambang probabilitas',
                                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                                ),
                                Text(
                                  _thresholdDraft.toStringAsFixed(2).replaceAll('.', ','),
                                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700, fontSize: 12.5),
                                ),
                              ],
                            ),
                            Slider(
                              value: _thresholdDraft,
                              min: 0.10,
                              max: 0.90,
                              divisions: 16,
                              label: _thresholdDraft.toStringAsFixed(2),
                              onChanged: busy ? null : (v) => setState(() => _thresholdDraft = v),
                              onChangeEnd: busy ? null : (_) => _applyEdgeDraft(ctrl),
                            ),
                          ],
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: busy ? null : () => _resetEdgeDraft(ctrl),
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Reset default (1,5 px)'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Statistik waktu & akselerator (PRD F2 & Keterlacakan)
            Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.outlineVariant),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              child: Row(
                children: [
                  _StatCell('AI', _formatMs(res.inferenceMs)),
                  _StatCell('Total', _formatMs(res.totalMs)),
                  _StatCell('Ukuran', '${res.width}×${res.height}'),
                  _StatCell('Mesin', res.accelerator.replaceAll(' thread', 'T')),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Tombol Simpan ke Galeri (F5) & Bagikan (F6)
            if (!hasSolidBg) ...[
              FilledButton.icon(
                onPressed: busy ? null : () => _save(ctrl, ExportFormat.png),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                icon: ctrl.isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(ctrl.isSaving ? 'Menyimpan PNG…' : 'Simpan PNG Transparan'),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: busy ? null : () => _save(ctrl, ExportFormat.jpg),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                icon: ctrl.isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(ctrl.isSaving ? 'Menyimpan…' : 'Simpan JPG ke Galeri'),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _share(ctrl),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: ctrl.isSharing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.share_outlined, size: 19),
                    label: Text(ctrl.isSharing ? 'Menyiapkan…' : 'Bagikan'),
                  ),
                ),
                if (hasSolidBg) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : () => _save(ctrl, ExportFormat.png),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      icon: const Icon(Icons.image_outlined, size: 19),
                      label: const Text('Simpan PNG'),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Disimpan dalam resolusi asli (${res.width}×${res.height} px) ke Galeri › Pichanter · '
              'Model ${res.modelVersion}',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwatchItem extends StatelessWidget {
  const _SwatchItem({
    required this.label,
    required this.rgb,
    required this.selected,
    required this.onTap,
    this.isCustom = false,
  });

  final String label;
  final int? rgb;
  final bool selected;
  final bool isCustom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer.withValues(alpha: 0.65) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? cs.primary : cs.outlineVariant,
                    width: selected ? 2.4 : 1.2,
                  ),
                ),
                child: ClipOval(
                  child: rgb == null
                      ? const CheckerboardBackground(tileSize: 7, child: SizedBox.expand())
                      : isCustom && !selected
                          ? const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: SweepGradient(
                                  colors: [
                                    Color(0xFFFF4444),
                                    Color(0xFFFFDD33),
                                    Color(0xFF44DD44),
                                    Color(0xFF33CCFF),
                                    Color(0xFF7744FF),
                                    Color(0xFFFF44CC),
                                    Color(0xFFFF4444),
                                  ],
                                ),
                              ),
                            )
                          : ColoredBox(color: Color(0xFF000000 | rgb!)),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5)),
        ],
      ),
    );
  }
}

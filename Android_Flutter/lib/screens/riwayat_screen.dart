import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/storage_service.dart';
import '../state/editor_controller.dart';
import '../state/history_controller.dart';
import '../widgets/checkerboard.dart';
import 'hasil_screen.dart';

/// Layar Riwayat Lokal (PRD F7): grid hasil terbaru; ketuk untuk membuka, tahan untuk menghapus.
class RiwayatScreen extends StatefulWidget {
  const RiwayatScreen({super.key});

  @override
  State<RiwayatScreen> createState() => _RiwayatScreenState();
}

class _RiwayatScreenState extends State<RiwayatScreen> {
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<HistoryController>().load();
    });
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'Baru saja';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mnt lalu';
    if (diff.inHours < 24) return '${diff.inHours} jam lalu';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/${dt.year} $h:$min';
  }

  Future<void> _openEntry(HistoryEntry entry) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final editor = context.read<EditorController>();
      final ok = await editor.openFromHistory(entry);
      if (!ok || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const HasilScreen()),
      );
      if (mounted) {
        await context.read<HistoryController>().load();
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _confirmDelete(HistoryEntry entry) async {
    final hist = context.read<HistoryController>();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus dari Riwayat?'),
        content: Text(
          'Hapus "${entry.sourceName}" (${entry.width}×${entry.height}) dari riwayat aplikasi? '
          'Foto yang sudah disimpan ke Galeri tidak ikut terhapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await hist.deleteItem(entry);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Riwayat dihapus.')),
      );
    }
  }

  Future<void> _confirmClearAll() async {
    final hist = context.read<HistoryController>();
    if (hist.items.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Semua Riwayat?'),
        content: Text(
          'Hapus seluruh ${hist.items.length} hasil dari penyimpanan lokal aplikasi?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Hapus Semua'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await hist.clearAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Semua riwayat lokal dihapus.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hist = context.watch<HistoryController>();
    final cs = Theme.of(context).colorScheme;
    final items = hist.items;

    return Scaffold(
      appBar: AppBar(
        title: Text('Riwayat (${items.length})'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              tooltip: 'Hapus semua',
              onPressed: _confirmClearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            if (hist.loading && items.isEmpty)
              const Center(child: CircularProgressIndicator())
            else if (items.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history_toggle_off, size: 54, color: cs.outline),
                      const SizedBox(height: 14),
                      const Text(
                        'Belum ada riwayat',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Setiap foto yang Anda hapus background-nya akan otomatis tersimpan di sini '
                        'agar bisa dibuka ulang, diganti warna latarnya, atau dibagikan kapan saja.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13.5, height: 1.4),
                      ),
                    ],
                  ),
                ),
              )
            else
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                    child: Row(
                      children: [
                        Icon(Icons.touch_app_outlined, size: 15, color: cs.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Ketuk kartu untuk membuka ulang · Tahan kartu untuk menghapus',
                            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.76,
                      ),
                      itemCount: items.length,
                      itemBuilder: (ctx, i) {
                        final item = items[i];
                        final bg = item.bgColorRgb;
                        final accelShort = item.accelerator.startsWith('GPU') ? 'GPU' : 'CPU';
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          margin: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(color: cs.outlineVariant),
                          ),
                          child: InkWell(
                            onTap: () => _openEntry(item),
                            onLongPress: () => _confirmDelete(item),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (bg == null)
                                        CheckerboardBackground(
                                          tileSize: 10,
                                          child: Image.file(
                                            File(item.thumbPath),
                                            fit: BoxFit.contain,
                                          ),
                                        )
                                      else
                                        ColoredBox(
                                          color: Color(0xFF000000 | bg),
                                          child: Image.file(
                                            File(item.thumbPath),
                                            fit: BoxFit.contain,
                                          ),
                                        ),
                                      Positioned(
                                        top: 8,
                                        left: 8,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.62),
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            '$accelShort · ${item.inferenceMs.round()} ms',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: IconButton(
                                          visualDensity: VisualDensity.compact,
                                          tooltip: 'Hapus',
                                          onPressed: () => _confirmDelete(item),
                                          icon: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.48),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.white,
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _formatDate(item.createdAt),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${item.width}×${item.height} px · ${(item.totalMs / 1000).toStringAsFixed(2).replaceAll('.', ',')} dtk',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            if (_opening)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

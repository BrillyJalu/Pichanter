import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/editor_controller.dart';
import 'hasil_screen.dart';

/// Layar Proses: pratinjau foto terpilih, tombol Hapus Background, indikator proses, tombol Batal.
class ProsesScreen extends StatelessWidget {
  const ProsesScreen({super.key});

  String _formatBytes(int n) {
    if (n < 1024 * 1024) {
      return '${(n / 1024).round().clamp(1, 99999)} KB';
    }
    return '${(n / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }

  Future<void> _start(BuildContext context) async {
    final ctrl = context.read<EditorController>();
    final ok = await ctrl.removeBackground();
    if (!ok || !context.mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const HasilScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<EditorController>();
    final cs = Theme.of(context).colorScheme;
    final photo = ctrl.selectedBytes;

    return PopScope(
      canPop: !ctrl.isProcessing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && ctrl.isProcessing) {
          ctrl.cancelProcessing();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pratinjau Foto'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (ctrl.isProcessing) {
                ctrl.cancelProcessing();
              }
              Navigator.of(context).pop();
            },
          ),
        ),
        body: SafeArea(
          child: photo == null
              ? const Center(child: Text('Belum ada foto yang dipilih.'))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (ctrl.error != null) ...[
                        Card(
                          color: cs.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              ctrl.error!,
                              style: TextStyle(color: cs.onErrorContainer),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(
                                color: cs.surfaceContainerHighest,
                                child: Image.memory(
                                  photo,
                                  fit: BoxFit.contain,
                                ),
                              ),
                              if (ctrl.isProcessing)
                                ColoredBox(
                                  color: Colors.black.withValues(alpha: 0.52),
                                  child: Center(
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(horizontal: 24),
                                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                                      decoration: BoxDecoration(
                                        color: cs.surface,
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: CircularProgressIndicator(strokeWidth: 3),
                                          ),
                                          const SizedBox(height: 14),
                                          Text(
                                            ctrl.stageLabel,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${ctrl.selectedName ?? 'Foto'} · ${_formatBytes(photo.length)}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 16),
                      if (!ctrl.isProcessing) ...[
                        FilledButton.icon(
                          onPressed: () => _start(context),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          icon: const Icon(Icons.auto_fix_high),
                          label: const Text('Hapus Background'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Ganti foto'),
                        ),
                      ] else ...[
                        OutlinedButton.icon(
                          onPressed: ctrl.cancelProcessing,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            foregroundColor: cs.error,
                          ),
                          icon: const Icon(Icons.close),
                          label: const Text('Batal'),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

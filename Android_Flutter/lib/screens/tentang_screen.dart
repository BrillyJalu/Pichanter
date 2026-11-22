import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/editor_controller.dart';

/// Halaman "Tentang model" (PRD F11): versi model, metrik test, uji ketahanan,
/// akselerator on-device, dan penjelasan privasi 100% offline.
class TentangScreen extends StatelessWidget {
  const TentangScreen({super.key});

  static const List<({String metrik, String mean, String globalOrTarget})> _testMetrics = [
    (metrik: 'Dice Score', mean: '0,9356 ± 0,0918', globalOrTarget: 'Global 0,9553 (Median 0,9650)'),
    (metrik: 'IoU (Jaccard)', mean: '0,8898 ± 0,1277', globalOrTarget: 'Global 0,9144 (Median 0,9324)'),
    (metrik: 'Precision', mean: '0,9354 ± 0,1009', globalOrTarget: '—'),
    (metrik: 'Recall', mean: '0,9469 ± 0,0892', globalOrTarget: '—'),
    (metrik: 'Pixel Accuracy', mean: '0,9781 ± 0,0389', globalOrTarget: '97,81%'),
    (metrik: 'MAD (Mean Abs Diff)', mean: '0,0219 ± 0,0389', globalOrTarget: 'Target ≤ 0,0300 (Lulus)'),
    (metrik: 'MSE', mean: '0,0216 ± 0,0388', globalOrTarget: 'Paper 0,0176'),
  ];

  static const List<({String kondisi, String dice, String drop})> _robustness = [
    (kondisi: 'Foto asli (tanpa gangguan)', dice: '0,9400', drop: '—'),
    (kondisi: 'Gelap (×0,35)', dice: '0,9324', drop: '−0,0075'),
    (kondisi: 'Grayscale', dice: '0,9290', drop: '−0,0109'),
    (kondisi: 'Noise Gaussian (σ=20)', dice: '0,8955', drop: '−0,0445'),
    (kondisi: 'Overexposed', dice: '0,8937', drop: '−0,0463'),
    (kondisi: 'Kompresi JPEG berat (q=15)', dice: '0,8921', drop: '−0,0479'),
    (kondisi: 'Blur (r=3)', dice: '0,8295', drop: '−0,1104'),
  ];

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<EditorController>();
    final cs = Theme.of(context).colorScheme;
    final gpuProbe = ctrl.lastGpuProbe;

    return Scaffold(
      appBar: AppBar(title: const Text('Tentang Model & Privasi')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            // Kartu Privasi 100% Offline
            Card(
              color: cs.primaryContainer.withValues(alpha: 0.6),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield_outlined, color: cs.primary),
                        const SizedBox(width: 8),
                        Text(
                          'Jaminan Privasi 100% Offline',
                          style: TextStyle(
                            color: cs.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                            fontSize: 15.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pichanter Mobile tidak meminta izin INTERNET sama sekali di AndroidManifest.xml. '
                      'Model AI dibundel langsung di dalam APK dan dijalankan sepenuhnya pada prosesor/GPU '
                      'perangkat Anda. Foto pribadi, KTP, maupun pas foto tidak pernah keluar dari HP.',
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Spesifikasi Model & Runtime On-Device
            _SectionCard(
              title: 'Spesifikasi Model AI (v2)',
              child: Column(
                children: [
                  _KvRow('Arsitektur', 'U-Net + MobileNetV3-Large'),
                  _KvRow('Versi model', ctrl.modelVersion),
                  _KvRow('File bundel', 'pichanter_bg_fp16.tflite (7,15 MB)'),
                  _KvRow('Parameter', '3.543.417 (encoder 3,00 jt · decoder 547 rb)'),
                  _KvRow('Input → Output', 'RGB float32 [1,384,384,3] → Mask [1,384,384,1]'),
                  _KvRow('Training', 'Dice loss · Adam 1e-4 · Epoch terbaik 56/66'),
                  _KvRow('Dataset', 'Kaggle Person Segmentation (5.678 gambar, 80/10/10)'),
                  _KvRow('Acuan ilmiah', 'Shahi & Li (2023), IJNDI 2(2):100004'),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Status Runtime & Akselerator di HP ini
            _SectionCard(
              title: 'Status Runtime LiteRT di Perangkat Ini',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KvRow('Engine', 'flutter_litert 4.2.0 (LiteRT 2.x)'),
                  _KvRow('Akselerator aktif', ctrl.modelReady ? ctrl.accelerator : 'Memuat…'),
                  _KvRow('Waktu muat model', '${ctrl.modelLoadMs.toStringAsFixed(1)} ms'),
                  _KvRow('Paritas Python (P1)', 'Dice 0,9979 (Target ≥ 0,99 — Lulus)'),
                  if (gpuProbe != null) ...[
                    _KvRow(
                      'Paritas GPU vs CPU (P2)',
                      'Dice ${gpuProbe.diceVsCpu.toStringAsFixed(5)} '
                      '(GPU ${gpuProbe.gpuInferenceMs.toStringAsFixed(1)} ms vs CPU ${gpuProbe.cpuInferenceMs.toStringAsFixed(1)} ms)',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      gpuProbe.decision,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Metrik Evaluasi Data Test (569 gambar)
            _SectionCard(
              title: 'Kinerja pada Data Test (569 Gambar)',
              child: Column(
                children: [
                  for (final m in _testMetrics)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 4,
                            child: Text(m.metrik, style: const TextStyle(fontSize: 13)),
                          ),
                          Expanded(
                            flex: 4,
                            child: Text(
                              m.mean,
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 5,
                            child: Text(
                              m.globalOrTarget,
                              textAlign: TextAlign.right,
                              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Uji Ketahanan
            _SectionCard(
              title: 'Uji Ketahanan terhadap Gangguan Gambar',
              child: Column(
                children: [
                  for (final r in _robustness)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text(r.kondisi, style: const TextStyle(fontSize: 13))),
                          Text(
                            'Dice ${r.dice}',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                          SizedBox(
                            width: 64,
                            child: Text(
                              r.drop,
                              textAlign: TextAlign.right,
                              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

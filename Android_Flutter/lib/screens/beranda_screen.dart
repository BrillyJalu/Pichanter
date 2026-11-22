import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/benchmark_service.dart';
import '../services/parity_service.dart';
import '../state/editor_controller.dart';
import '../state/history_controller.dart';
import 'proses_screen.dart';
import 'riwayat_screen.dart';
import 'tentang_screen.dart';

class BerandaScreen extends StatefulWidget {
  const BerandaScreen({
    super.key,
    this.parityService,
    this.benchmarkService,
  });

  final ParityService? parityService;
  final BenchmarkService? benchmarkService;

  @override
  State<BerandaScreen> createState() => _BerandaScreenState();
}

class _BerandaScreenState extends State<BerandaScreen> {
  bool _runningParity = false;
  String? _parityStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initApp());
  }

  Future<void> _initApp() async {
    final ctrl = context.read<EditorController>();
    final hist = context.read<HistoryController>();
    await Future.wait([
      ctrl.ensureModelLoaded(),
      hist.load(),
    ]);
    if (!mounted) return;
    final parity = widget.parityService;
    if (parity != null && await parity.hasAutoRunMarker()) {
      await _runParity();
      return;
    }
    final bench = widget.benchmarkService;
    if (bench != null && await bench.hasAutoRunMarker()) {
      await _runBenchmark();
    }
  }

  Future<void> _runBenchmark() async {
    final bench = widget.benchmarkService;
    final ctrl = context.read<EditorController>();
    if (bench == null || _runningParity) return;
    if (!ctrl.modelReady) await ctrl.ensureModelLoaded();
    if (!mounted || !ctrl.modelReady) return;

    setState(() {
      _runningParity = true;
      _parityStatus = 'Menjalankan uji kinerja Tahap 4 (P2, L1, M1)...';
    });
    try {
      final rep = await bench.runAll(
        onStatus: (s) {
          if (mounted) setState(() => _parityStatus = s);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'L1 avg: ${rep.l1AvgTotalMs.toStringAsFixed(0)} ms · '
            'M1 peak: ${rep.m1PeakRssMb.toStringAsFixed(0)} MB · '
            'P2: ${rep.p2GpuParity.passedP2 ? "GPU Lulus" : "Pakai CPU"}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uji kinerja gagal: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _runningParity = false;
          _parityStatus = null;
        });
      }
    }
  }

  Future<void> _runParity() async {
    final parity = widget.parityService;
    final ctrl = context.read<EditorController>();
    if (parity == null || _runningParity) return;
    if (!ctrl.modelReady) await ctrl.ensureModelLoaded();
    if (!mounted || !ctrl.modelReady) return;

    setState(() {
      _runningParity = true;
      _parityStatus = 'Menjalankan uji paritas P1...';
    });
    try {
      final reports = await parity.runBatch(
        onProgress: (cur, tot, name) {
          if (mounted) {
            setState(() => _parityStatus = 'Uji paritas ($cur/$tot): $name');
          }
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uji paritas selesai (${reports.length} foto).')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uji paritas gagal: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _runningParity = false;
          _parityStatus = null;
        });
      }
    }
  }

  Future<void> _pick(ImageSource source) async {
    final ctrl = context.read<EditorController>();
    final ok = await ctrl.pickPhoto(source);
    if (!ok || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProsesScreen()),
    );
  }

  Future<void> _useBundledSample() async {
    final ctrl = context.read<EditorController>();
    final bytes = await BenchmarkService.loadOrCreate12MpSampleBytes();
    ctrl.setSelectedPhoto(bytes, 'foto_uji_12mp.jpg');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProsesScreen()),
    );
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RiwayatScreen()),
    );
  }

  Future<void> _openAbout() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TentangScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<EditorController>();
    final hist = context.watch<HistoryController>();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF7C5CFF), Color(0xFF432DC4)],
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.person, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('Pichanter', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Riwayat',
            onPressed: _openHistory,
            icon: hist.count > 0
                ? Badge(
                    label: Text('${hist.count}'),
                    child: const Icon(Icons.history),
                  )
                : const Icon(Icons.history),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'about') _openAbout();
              if (v == 'history') _openHistory();
              if (v == 'sample') _useBundledSample();
              if (v == 'parity') _runParity();
              if (v == 'bench') _runBenchmark();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'about', child: Text('Tentang model')),
              PopupMenuItem(value: 'history', child: Text('Riwayat hasil')),
              PopupMenuItem(value: 'sample', child: Text('Coba foto contoh')),
              PopupMenuItem(value: 'parity', child: Text('Jalankan uji paritas (P1)')),
              PopupMenuItem(value: 'bench', child: Text('Uji kinerja & GPU (P2, L1, M1)')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Badge privasi offline (PRD)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.verified_user_outlined, size: 20, color: cs.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '100% offline — foto tidak keluar dari HP',
                                style: TextStyle(
                                  color: cs.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Banner hero
                      Container(
                        height: 176,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF6F53F7), Color(0xFF432DC4)],
                          ),
                        ),
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'Hapus background\ntanpa internet',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      height: 1.2,
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Untuk pas foto, foto profil, dan katalog. Simpan PNG transparan atau ganti warna latar.',
                                    style: TextStyle(
                                      color: Color(0xFFE9E4FF),
                                      fontSize: 13,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Icon(
                                Icons.auto_fix_high,
                                color: Colors.white,
                                size: 36,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Status model
                      Row(
                        children: [
                          Icon(
                            ctrl.modelError != null
                                ? Icons.error_outline
                                : ctrl.modelReady
                                    ? Icons.check_circle
                                    : Icons.downloading,
                            size: 17,
                            color: ctrl.modelError != null
                                ? cs.error
                                : ctrl.modelReady
                                    ? const Color(0xFF067647)
                                    : cs.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ctrl.modelError ??
                                  (ctrl.modelReady
                                      ? 'Model AI siap · ${ctrl.accelerator} (${ctrl.modelLoadMs.toStringAsFixed(0)} ms)'
                                      : 'Menyiapkan model AI di perangkat…'),
                              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                            ),
                          ),
                        ],
                      ),

                      if (_runningParity && _parityStatus != null) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 6),
                        Text(_parityStatus!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                      ],

                      if (ctrl.error != null) ...[
                        const SizedBox(height: 12),
                        Card(
                          color: cs.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    ctrl.error!,
                                    style: TextStyle(color: cs.onErrorContainer),
                                  ),
                                ),
                                IconButton(
                                  onPressed: ctrl.clearError,
                                  icon: Icon(Icons.close, color: cs.onErrorContainer, size: 18),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),

                      // Tombol utama (PRD F1)
                      FilledButton.icon(
                        onPressed: _runningParity ? null : () => _pick(ImageSource.camera),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Ambil Foto'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _runningParity ? null : () => _pick(ImageSource.gallery),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Pilih dari Galeri'),
                      ),
                      const SizedBox(height: 12),

                      // Pintasan ke Riwayat & Tentang Model (PRD Rancangan Layar)
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _runningParity ? null : _openHistory,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(46),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              icon: const Icon(Icons.history, size: 19),
                              label: Text(
                                hist.count > 0 ? 'Riwayat (${hist.count})' : 'Riwayat',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _runningParity ? null : _openAbout,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(46),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              icon: const Icon(Icons.info_outline, size: 19),
                              label: const Text('Tentang Model'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Text(
                      'Tips: gunakan foto dengan subjek orang cukup besar dan pencahayaan terang '
                      'untuk hasil tepi rambut yang paling rapi.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

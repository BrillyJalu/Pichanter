import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'image_service.dart';
import 'model_service.dart';

/// Hasil lengkap pengujian Tahap 4:
/// - P2: Paritas akselerator (CompiledModel GPU vs Interpreter CPU)
/// - L1: Latensi 10x foto 12 MP (pra-proses, inferensi, pasca-proses, total)
/// - M1: Memori 5x foto 12 MP berturut-turut (RSS puncak <= 400 MB, tidak crash)
class Stage4BenchmarkReport {
  const Stage4BenchmarkReport({
    required this.buildMode,
    required this.modelVersion,
    required this.activeAccelerator,
    required this.p2GpuParity,
    required this.l1Runs,
    required this.l1AvgPreprocessMs,
    required this.l1AvgInferenceMs,
    required this.l1AvgPostprocessMs,
    required this.l1AvgTotalMs,
    required this.m1Runs,
    required this.m1StartRssMb,
    required this.m1PeakRssMb,
    required this.m1EndRssMb,
    required this.m1Passed,
  });

  final String buildMode;
  final String modelVersion;
  final String activeAccelerator;
  final GpuParityProbeReport p2GpuParity;

  final int l1Runs;
  final double l1AvgPreprocessMs;
  final double l1AvgInferenceMs;
  final double l1AvgPostprocessMs;
  final double l1AvgTotalMs;

  final int m1Runs;
  final double m1StartRssMb;
  final double m1PeakRssMb;
  final double m1EndRssMb;
  final bool m1Passed;

  Map<String, Object?> toJson() => {
        'build_mode': buildMode,
        'model_version': modelVersion,
        'active_accelerator': activeAccelerator,
        'p2_gpu_parity': p2GpuParity.toJson(),
        'l1_latency_12mp': {
          'runs': l1Runs,
          'avg_preprocess_ms': double.parse(l1AvgPreprocessMs.toStringAsFixed(1)),
          'avg_inference_ms': double.parse(l1AvgInferenceMs.toStringAsFixed(1)),
          'avg_postprocess_ms': double.parse(l1AvgPostprocessMs.toStringAsFixed(1)),
          'avg_total_ms': double.parse(l1AvgTotalMs.toStringAsFixed(1)),
          'target_le_2000ms': l1AvgTotalMs <= 2000.0,
        },
        'm1_memory_12mp': {
          'runs': m1Runs,
          'start_rss_mb': double.parse(m1StartRssMb.toStringAsFixed(1)),
          'peak_rss_mb': double.parse(m1PeakRssMb.toStringAsFixed(1)),
          'end_rss_mb': double.parse(m1EndRssMb.toStringAsFixed(1)),
          'target_le_400mb': m1Passed,
        },
      };
}

class BenchmarkService {
  const BenchmarkService({
    required this.modelService,
    required this.imageService,
  });

  final ModelService modelService;
  final ImageService imageService;

  Future<bool> hasAutoRunMarker() async {
    final base = await getExternalStorageDirectory();
    if (base == null) return false;
    return File(p.join(base.path, 'parity_in', '.autorun_bench')).exists();
  }

  /// Ambil foto uji 12 MP dari `<extFiles>/parity_in/01_office_12mp.jpg` bila tersedia,
  /// atau buat foto JPEG 12 MP (4032x3024) sintetis di memori untuk benchmark.
  static Future<Uint8List> loadOrCreate12MpSampleBytes() async {
    final base = await getExternalStorageDirectory();
    if (base != null) {
      final f = File(p.join(base.path, 'parity_in', '01_office_12mp.jpg'));
      if (await f.exists()) {
        return f.readAsBytes();
      }
    }
    final canvas = img.Image(width: 4032, height: 3024);
    img.fill(canvas, color: img.ColorRgb8(45, 175, 70));
    img.fillCircle(canvas, x: 2016, y: 1512, radius: 900, color: img.ColorRgb8(210, 165, 140));
    return Uint8List.fromList(img.encodeJpg(canvas, quality: 90));
  }

  static double _currentMemoryMb() {
    try {
      final rollup = File('/proc/self/smaps_rollup');
      if (rollup.existsSync()) {
        for (final line in rollup.readAsLinesSync()) {
          if (line.startsWith('Pss:')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final kb = int.tryParse(parts[1]);
              if (kb != null && kb > 0) return kb / 1024.0;
            }
          }
        }
      }
    } catch (_) {}
    return ProcessInfo.currentRss / (1024.0 * 1024.0);
  }

  /// Menjalankan P2 (GPU vs CPU), L1 (10x foto 12 MP), dan M1 (5x foto 12 MP + pantau memori).
  Future<Stage4BenchmarkReport> runAll({
    int l1Iterations = 10,
    int m1Iterations = 5,
    void Function(String status)? onStatus,
  }) async {
    final base = await getExternalStorageDirectory();
    if (base != null) {
      final marker = File(p.join(base.path, 'parity_in', '.autorun_bench'));
      try {
        if (await marker.exists()) {
          await marker.delete();
        }
      } catch (_) {}
    }

    if (!modelService.isLoaded) {
      await modelService.load();
    }

    // Ambil foto 12 MP (4032x3024) dari parity_in/01_office_12mp.jpg (atau sintetis 12 MP bila belum di-push)
    onStatus?.call('Menyiapkan foto 12 MP untuk uji P2, L1, dan M1...');
    final photo12MpBytes = await loadOrCreate12MpSampleBytes();

    // 1. Uji P2: Paritas akselerator GPU CompiledModel vs CPU Interpreter
    onStatus?.call('Uji P2: Memeriksa paritas CompiledModel (GPU) vs Interpreter (CPU)...');
    final samplePrep = await imageService.preprocess(photo12MpBytes, modelService.inputSize);
    final p2Report = await modelService.probeGpuParity(
      sampleInputs: [samplePrep.modelInput],
      targetDice: 0.99,
    );
    debugPrint(
      '[PICHANTER_BENCH] P2 GPU probe: compiled=${p2Report.gpuCompiled} '
      'fallback=${p2Report.didFallbackToCpu} fullyAccel=${p2Report.isFullyAccelerated} '
      'accels=${p2Report.effectiveAccelerators} dice=${p2Report.diceVsCpu.toStringAsFixed(5)} '
      'mad=${p2Report.madVsCpu.toStringAsFixed(5)} gpuMs=${p2Report.gpuInferenceMs.toStringAsFixed(1)} '
      'cpuMs=${p2Report.cpuInferenceMs.toStringAsFixed(1)} passed=${p2Report.passedP2} | ${p2Report.decision}',
    );

    // 2. Uji M1 (5x foto 12 MP berturut-turut + pantau PSS/RSS memori) & L1 (10x foto 12 MP)
    final startRss = _currentMemoryMb();
    double peakRss = startRss;

    double sumPre = 0.0;
    double sumInf = 0.0;
    double sumPost = 0.0;
    double sumTot = 0.0;

    final totalRuns = math.max(l1Iterations, m1Iterations);
    for (int i = 1; i <= totalRuns; i++) {
      onStatus?.call('Uji L1/M1 ($i/$totalRuns): Memproses foto 12 MP (4032×3024)...');
      final swTot = Stopwatch()..start();
      final prep = await imageService.preprocess(photo12MpBytes, modelService.inputSize);
      final infer = await modelService.predictMask(prep.modelInput);
      final maskRes = await imageService.buildFullResAlpha(
        maskProbabilities: infer.maskProbabilities,
        maskSize: infer.maskSize,
        width: prep.width,
        height: prep.height,
        feather: 1.5,
        previewRgbBytes: i <= m1Iterations ? prep.previewRgbBytes : null,
        previewWidth: i <= m1Iterations ? prep.previewWidth : null,
        previewHeight: i <= m1Iterations ? prep.previewHeight : null,
      );
      swTot.stop();
      final totMs = swTot.elapsedMicroseconds / 1000.0;

      final curRss = _currentMemoryMb();
      if (curRss > peakRss) peakRss = curRss;

      if (i <= l1Iterations) {
        sumPre += prep.preprocessMs;
        sumInf += infer.inferenceMs;
        sumPost += maskRes.postprocessMs;
        sumTot += totMs;
      }

      debugPrint(
        '[PICHANTER_BENCH] Run $i/$totalRuns (4032x3024) | '
        'pre=${prep.preprocessMs.toStringAsFixed(1)}ms '
        'inf=${infer.inferenceMs.toStringAsFixed(1)}ms '
        'post=${maskRes.postprocessMs.toStringAsFixed(1)}ms '
        'total=${totMs.toStringAsFixed(1)}ms | '
        'rss=${curRss.toStringAsFixed(1)}MB (peak=${peakRss.toStringAsFixed(1)}MB)',
      );
    }

    final endRss = _currentMemoryMb();
    final avgPre = sumPre / l1Iterations;
    final avgInf = sumInf / l1Iterations;
    final avgPost = sumPost / l1Iterations;
    final avgTot = sumTot / l1Iterations;

    final report = Stage4BenchmarkReport(
      buildMode: kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      modelVersion: modelService.modelVersion,
      activeAccelerator: modelService.accelerator,
      p2GpuParity: p2Report,
      l1Runs: l1Iterations,
      l1AvgPreprocessMs: avgPre,
      l1AvgInferenceMs: avgInf,
      l1AvgPostprocessMs: avgPost,
      l1AvgTotalMs: avgTot,
      m1Runs: m1Iterations,
      m1StartRssMb: startRss,
      m1PeakRssMb: peakRss,
      m1EndRssMb: endRss,
      m1Passed: peakRss <= 400.0,
    );

    if (base != null) {
      final outDir = Directory(p.join(base.path, 'parity_out'));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      await File(p.join(outDir.path, 'benchmark_stage4.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    }

    debugPrint(
      '[PICHANTER_BENCH] COMPLETE | L1 avgTotal=${avgTot.toStringAsFixed(1)}ms '
      '(pre=${avgPre.toStringAsFixed(1)}, inf=${avgInf.toStringAsFixed(1)}, post=${avgPost.toStringAsFixed(1)}) | '
      'M1 peakRss=${peakRss.toStringAsFixed(1)}MB (end=${endRss.toStringAsFixed(1)}MB) | '
      'P2 passed=${p2Report.passedP2} dice=${p2Report.diceVsCpu.toStringAsFixed(5)}',
    );
    return report;
  }
}

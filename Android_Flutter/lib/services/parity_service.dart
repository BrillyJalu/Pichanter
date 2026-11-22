import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'image_service.dart';
import 'model_service.dart';

/// Hasil satu foto pada uji paritas P1/P2 di perangkat.
class ParityPhotoReport {
  const ParityPhotoReport({
    required this.fileName,
    required this.width,
    required this.height,
    required this.preprocessMs,
    required this.inferenceMs,
    required this.postprocessMs,
    required this.totalPipelineMs,
  });

  final String fileName;
  final int width;
  final int height;
  final double preprocessMs;
  final double inferenceMs;
  final double postprocessMs;
  final double totalPipelineMs;

  Map<String, Object> toJson() => {
        'file': fileName,
        'width': width,
        'height': height,
        'preprocess_ms': double.parse(preprocessMs.toStringAsFixed(2)),
        'inference_ms': double.parse(inferenceMs.toStringAsFixed(2)),
        'postprocess_ms': double.parse(postprocessMs.toStringAsFixed(2)),
        'total_pipeline_ms': double.parse(totalPipelineMs.toStringAsFixed(2)),
      };
}

/// Menjalankan pipeline produksi pada semua foto di `<extFiles>/parity_in/`
/// dan menyimpan mask (`_mask384.png`, `_mask_full.png`, `_alpha.png`) + `timings.json`
/// ke `<extFiles>/parity_out/` untuk dibandingkan oleh `tools/compare_parity.py`.
class ParityService {
  const ParityService({
    required this.modelService,
    required this.imageService,
  });

  final ModelService modelService;
  final ImageService imageService;

  static const Set<String> _allowedExts = {'.jpg', '.jpeg', '.png', '.webp'};

  Future<Directory?> _externalBase() async {
    return getExternalStorageDirectory();
  }

  Future<bool> hasAutoRunMarker() async {
    final base = await _externalBase();
    if (base == null) return false;
    return File(p.join(base.path, 'parity_in', '.autorun')).exists();
  }

  Future<List<ParityPhotoReport>> runBatch({
    void Function(int current, int total, String fileName)? onProgress,
  }) async {
    final base = await _externalBase();
    if (base == null) {
      throw StateError('External storage directory tidak tersedia.');
    }

    final inDir = Directory(p.join(base.path, 'parity_in'));
    final outDir = Directory(p.join(base.path, 'parity_out'));
    if (!await inDir.exists()) {
      await inDir.create(recursive: true);
    }
    if (await outDir.exists()) {
      await outDir.delete(recursive: true);
    }
    await outDir.create(recursive: true);

    final marker = File(p.join(inDir.path, '.autorun'));
    try {
      if (await marker.exists()) {
        await marker.delete();
      }
    } catch (_) {}

    final files = inDir
        .listSync()
        .whereType<File>()
        .where((f) => _allowedExts.contains(p.extension(f.path).toLowerCase()))
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    if (files.isEmpty) {
      throw StateError('Tidak ada foto di ${inDir.path}');
    }

    final reports = <ParityPhotoReport>[];
    for (int i = 0; i < files.length; i++) {
      final f = files[i];
      final name = p.basename(f.path);
      final stem = p.basenameWithoutExtension(f.path);
      onProgress?.call(i + 1, files.length, name);

      final bytes = await f.readAsBytes();
      final totalSw = Stopwatch()..start();
      final prep = await imageService.preprocess(bytes, modelService.inputSize);
      final infer = await modelService.predictMask(prep.modelInput);
      final maskRes = await imageService.buildFullResAlpha(
        maskProbabilities: infer.maskProbabilities,
        maskSize: infer.maskSize,
        width: prep.width,
        height: prep.height,
        feather: 1.5,
      );
      totalSw.stop();

      // Simpan ketiga mask referensi untuk perbandingan P1/P2.
      final png384 = await imageService.encodeGrayscalePng(
        maskRes.maskSmallU8,
        maskRes.maskSize,
        maskRes.maskSize,
      );
      final pngFull = await imageService.encodeGrayscalePng(
        maskRes.maskFullRes,
        maskRes.width,
        maskRes.height,
      );
      final pngAlpha = await imageService.encodeGrayscalePng(
        maskRes.alphaFullRes,
        maskRes.width,
        maskRes.height,
      );

      await File(p.join(outDir.path, '${stem}_mask384.png')).writeAsBytes(png384, flush: true);
      await File(p.join(outDir.path, '${stem}_mask_full.png')).writeAsBytes(pngFull, flush: true);
      await File(p.join(outDir.path, '${stem}_alpha.png')).writeAsBytes(pngAlpha, flush: true);

      final report = ParityPhotoReport(
        fileName: name,
        width: prep.width,
        height: prep.height,
        preprocessMs: prep.preprocessMs,
        inferenceMs: infer.inferenceMs,
        postprocessMs: maskRes.postprocessMs,
        totalPipelineMs: totalSw.elapsedMicroseconds / 1000.0,
      );
      reports.add(report);
      debugPrint(
        '[PICHANTER_PARITY] ${i + 1}/${files.length} $name (${prep.width}x${prep.height}) | '
        'pre=${prep.preprocessMs.toStringAsFixed(1)}ms | '
        'infer=${infer.inferenceMs.toStringAsFixed(1)}ms | '
        'post=${maskRes.postprocessMs.toStringAsFixed(1)}ms | '
        'total=${report.totalPipelineMs.toStringAsFixed(1)}ms',
      );
    }

    final avgPre = reports.map((r) => r.preprocessMs).reduce((a, b) => a + b) / reports.length;
    final avgInf = reports.map((r) => r.inferenceMs).reduce((a, b) => a + b) / reports.length;
    final avgPost = reports.map((r) => r.postprocessMs).reduce((a, b) => a + b) / reports.length;
    final avgTot = reports.map((r) => r.totalPipelineMs).reduce((a, b) => a + b) / reports.length;

    final payload = {
      'model_version': modelService.modelVersion,
      'accelerator': modelService.accelerator,
      'build_mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'count': reports.length,
      'summary': {
        'avg_preprocess_ms': double.parse(avgPre.toStringAsFixed(1)),
        'avg_inference_ms': double.parse(avgInf.toStringAsFixed(1)),
        'avg_postprocess_ms': double.parse(avgPost.toStringAsFixed(1)),
        'avg_total_pipeline_ms': double.parse(avgTot.toStringAsFixed(1)),
      },
      'items': reports.map((r) => r.toJson()).toList(),
    };
    await File(p.join(outDir.path, 'timings.json'))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(payload), flush: true);

    debugPrint(
      '[PICHANTER_PARITY] COMPLETE count=${reports.length} mode=${payload['build_mode']} '
      'avgPre=${avgPre.toStringAsFixed(1)}ms avgInf=${avgInf.toStringAsFixed(1)}ms '
      'avgPost=${avgPost.toStringAsFixed(1)}ms avgTotal=${avgTot.toStringAsFixed(1)}ms',
    );
    return reports;
  }
}

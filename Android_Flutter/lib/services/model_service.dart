import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_litert/flutter_litert.dart';

/// Hasil mentah inferensi model (peta probabilitas float32 0..1 berukuran [inputSize * inputSize]).
class ModelInferenceResult {
  const ModelInferenceResult({
    required this.maskProbabilities,
    required this.maskSize,
    required this.inferenceMs,
    required this.accelerator,
    required this.modelVersion,
  });

  final Float32List maskProbabilities;
  final int maskSize;
  final double inferenceMs;
  final String accelerator;
  final String modelVersion;
}

/// Laporan uji paritas akselerator P2 (`CompiledModel` GPU vs `Interpreter` CPU).
class GpuParityProbeReport {
  const GpuParityProbeReport({
    required this.gpuCompiled,
    required this.didFallbackToCpu,
    required this.isFullyAccelerated,
    required this.effectiveAccelerators,
    required this.diceVsCpu,
    required this.madVsCpu,
    required this.maxAbsDiff,
    required this.gpuInferenceMs,
    required this.cpuInferenceMs,
    required this.passedP2,
    required this.decision,
    this.error,
  });

  final bool gpuCompiled;
  final bool didFallbackToCpu;
  final bool isFullyAccelerated;
  final List<String> effectiveAccelerators;
  final double diceVsCpu;
  final double madVsCpu;
  final double maxAbsDiff;
  final double gpuInferenceMs;
  final double cpuInferenceMs;
  final bool passedP2;
  final String decision;
  final String? error;

  Map<String, Object?> toJson() => {
        'gpu_compiled': gpuCompiled,
        'did_fallback_to_cpu': didFallbackToCpu,
        'is_fully_accelerated': isFullyAccelerated,
        'effective_accelerators': effectiveAccelerators,
        'dice_vs_cpu': double.parse(diceVsCpu.toStringAsFixed(5)),
        'mad_vs_cpu': double.parse(madVsCpu.toStringAsFixed(5)),
        'max_abs_diff': double.parse(maxAbsDiff.toStringAsFixed(5)),
        'gpu_inference_ms': double.parse(gpuInferenceMs.toStringAsFixed(2)),
        'cpu_inference_ms': double.parse(cpuInferenceMs.toStringAsFixed(2)),
        'passed_p2': passedP2,
        'decision': decision,
        'error': error,
      };
}

/// Layanan inferensi on-device memakai `flutter_litert` di dalam satu worker isolate khusus.
///
/// Sesuai PRD:
/// - Menjalankan seluruh kompilasi & inferensi di isolate terpisah (thread-safe untuk driver GPU Android).
/// - Saat inisialisasi, menguji `CompiledModel` (GPU) terhadap `Interpreter` (CPU/XNNPACK) (uji P2).
/// - Bila GPU lulus paritas (Dice >= 0,99) dan lebih cepat dari CPU, aplikasi memakai GPU dan menutup
///   interpreter CPU agar hemat memori; bila tidak, otomatis memakai CPU (`Interpreter` XNNPACK).
class ModelService {
  static const String defaultAssetPath = 'assets/models/pichanter_bg_fp16.tflite';
  static const String defaultModelVersion = 'unet-mnv3l-384-fp16-v2';

  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  Future<void> _serialQueue = Future<void>.value();

  int _inputSize = 384;
  List<int> _inputShape = const [];
  List<int> _outputShape = const [];
  double _loadMs = 0;
  String _accelerator = 'CPU (XNNPACK)';
  String _modelVersion = defaultModelVersion;
  GpuParityProbeReport? _lastGpuProbe;

  bool get isLoaded => _workerSendPort != null;
  int get inputSize => _inputSize;
  List<int> get inputShape => _inputShape;
  List<int> get outputShape => _outputShape;
  double get loadMs => _loadMs;
  String get accelerator => _accelerator;
  String get modelVersion => _modelVersion;
  GpuParityProbeReport? get lastGpuProbe => _lastGpuProbe;

  Future<void> load({
    String assetPath = defaultAssetPath,
    String modelVersion = defaultModelVersion,
    int? threads,
    bool preferGpu = true,
  }) async {
    if (isLoaded) return;

    final sw = Stopwatch()..start();
    final cpuThreads = threads ?? math.max(2, math.min(4, Platform.numberOfProcessors));
    final bd = await rootBundle.load(assetPath);
    final modelBytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);

    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerEntry,
      [
        initPort.sendPort,
        TransferableTypedData.fromList([modelBytes]),
        cpuThreads,
        preferGpu,
      ],
      debugName: 'PichanterModelWorker',
    );

    final initReply = await initPort.first as Map<String, Object?>;
    initPort.close();
    sw.stop();

    if (initReply['error'] != null) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError(initReply['error'] as String);
    }

    _workerIsolate = isolate;
    _workerSendPort = initReply['sendPort'] as SendPort;
    _inputSize = initReply['inputSize'] as int;
    _inputShape = List<int>.unmodifiable(initReply['inputShape'] as List<int>);
    _outputShape = List<int>.unmodifiable(initReply['outputShape'] as List<int>);
    _accelerator = initReply['accelerator'] as String;
    _lastGpuProbe = _decodeProbeMap(initReply['gpuProbe'] as Map<String, Object?>);
    _loadMs = sw.elapsedMicroseconds / 1000.0;
    _modelVersion = modelVersion;
  }

  /// Menjalankan inferensi pada input RGB float32 datar berukuran `inputSize * inputSize * 3`.
  Future<ModelInferenceResult> predictMask(Float32List inputRgb) {
    final expectedLen = _inputSize * _inputSize * 3;
    if (inputRgb.length != expectedLen) {
      throw ArgumentError('Panjang input ${inputRgb.length} != $expectedLen');
    }
    final fut = _serialQueue.then((_) => _predictSerialized(inputRgb));
    _serialQueue = fut.then((_) {}, onError: (_) {});
    return fut;
  }

  Future<ModelInferenceResult> _predictSerialized(Float32List inputRgb) async {
    final port = _workerSendPort;
    if (port == null) {
      throw StateError('Model belum dimuat. Panggil load() terlebih dahulu.');
    }

    final replyPort = ReceivePort();
    port.send([
      'predict',
      replyPort.sendPort,
      TransferableTypedData.fromList([inputRgb.buffer.asUint8List(inputRgb.offsetInBytes, inputRgb.lengthInBytes)]),
    ]);

    final reply = await replyPort.first as Map<String, Object?>;
    replyPort.close();

    if (reply['error'] != null) {
      throw StateError(reply['error'] as String);
    }

    final ttd = reply['output'] as TransferableTypedData;
    final outBytes = ttd.materialize().asUint8List();
    final outFloats = Float32List.view(outBytes.buffer, outBytes.offsetInBytes, _inputSize * _inputSize);

    return ModelInferenceResult(
      maskProbabilities: outFloats,
      maskSize: _inputSize,
      inferenceMs: reply['inferenceMs'] as double,
      accelerator: reply['accelerator'] as String,
      modelVersion: _modelVersion,
    );
  }

  /// Uji paritas P2 (`CompiledModel` GPU vs `Interpreter` CPU) pada input foto nyata di dalam worker isolate.
  /// Tidak membuka environment kedua sehingga memori tetap rendah.
  Future<GpuParityProbeReport> probeGpuParity({
    required List<Float32List> sampleInputs,
    double targetDice = 0.99,
  }) {
    final fut = _serialQueue.then((_) => _probeSerialized(sampleInputs, targetDice));
    _serialQueue = fut.then((_) {}, onError: (_) {});
    return fut;
  }

  Future<GpuParityProbeReport> _probeSerialized(
    List<Float32List> sampleInputs,
    double targetDice,
  ) async {
    final port = _workerSendPort;
    if (port == null) {
      throw StateError('Model belum dimuat.');
    }
    final first = sampleInputs.isNotEmpty
        ? sampleInputs.first
        : _makeSyntheticInput(_inputSize);
    final replyPort = ReceivePort();
    port.send([
      'probe_p2',
      replyPort.sendPort,
      TransferableTypedData.fromList([first.buffer.asUint8List(first.offsetInBytes, first.lengthInBytes)]),
      targetDice,
    ]);
    final reply = await replyPort.first as Map<String, Object?>;
    replyPort.close();
    final report = _decodeProbeMap(reply);
    _lastGpuProbe = report;
    if (reply['activeAccelerator'] is String) {
      _accelerator = reply['activeAccelerator'] as String;
    }
    return report;
  }

  static GpuParityProbeReport _decodeProbeMap(Map<String, Object?> m) {
    return GpuParityProbeReport(
      gpuCompiled: m['gpuCompiled'] as bool,
      didFallbackToCpu: m['didFallbackToCpu'] as bool,
      isFullyAccelerated: m['isFullyAccelerated'] as bool,
      effectiveAccelerators: (m['effectiveAccelerators'] as List<Object?>).cast<String>(),
      diceVsCpu: m['diceVsCpu'] as double,
      madVsCpu: m['madVsCpu'] as double,
      maxAbsDiff: m['maxAbsDiff'] as double,
      gpuInferenceMs: m['gpuInferenceMs'] as double,
      cpuInferenceMs: m['cpuInferenceMs'] as double,
      passedP2: m['passedP2'] as bool,
      decision: m['decision'] as String,
      error: m['error'] as String?,
    );
  }

  // ---------------------------------------------------------------- worker isolate

  static void _workerEntry(List<Object?> initArgs) {
    final mainSendPort = initArgs[0] as SendPort;
    final modelTtd = initArgs[1] as TransferableTypedData;
    final cpuThreads = initArgs[2] as int;
    final preferGpu = initArgs[3] as bool;

    final modelBytes = modelTtd.materialize().asUint8List();
    Interpreter? cpuItp;
    CompiledModel? gpuModel;
    int inputSize = 384;
    String activeAccel = 'CPU ($cpuThreads thread)';
    bool useGpu = false;

    try {
      final opts = InterpreterOptions()..threads = cpuThreads;
      cpuItp = Interpreter.fromBuffer(modelBytes, options: opts);
      final inShape = cpuItp.getInputTensor(0).shape;
      final outShape = cpuItp.getOutputTensor(0).shape;
      if (inShape.length != 4 || inShape[1] != inShape[2] || inShape[3] != 3) {
        cpuItp.close();
        mainSendPort.send({'error': 'Bentuk input tidak sesuai: $inShape'});
        return;
      }
      if (outShape.length != 4 || outShape[1] != inShape[1] || outShape[2] != inShape[2] || outShape[3] != 1) {
        cpuItp.close();
        mainSendPort.send({'error': 'Bentuk output tidak sesuai: $outShape'});
        return;
      }
      inputSize = inShape[1];

      Map<String, Object?> probeMap;
      if (preferGpu) {
        final synth = _makeSyntheticInput(inputSize);
        final res = _evaluateGpuVsCpu(
          modelBytes: modelBytes,
          cpuItp: cpuItp,
          sampleInput: synth,
          inputSize: inputSize,
          targetDice: 0.99,
          existingGpu: null,
        );
        probeMap = res.probeMap;
        if (res.passed && res.gpuModel != null) {
          gpuModel = res.gpuModel;
          useGpu = true;
          activeAccel = 'GPU (LiteRT)';
        } else {
          res.gpuModel?.close();
        }
      } else {
        probeMap = {
          'gpuCompiled': false,
          'didFallbackToCpu': true,
          'isFullyAccelerated': false,
          'effectiveAccelerators': <String>['cpu'],
          'diceVsCpu': 1.0,
          'madVsCpu': 0.0,
          'maxAbsDiff': 0.0,
          'gpuInferenceMs': 0.0,
          'cpuInferenceMs': 0.0,
          'passedP2': false,
          'decision': 'Mode CPU dipilih.',
          'error': null,
        };
      }

      final cmdPort = ReceivePort();
      mainSendPort.send({
        'sendPort': cmdPort.sendPort,
        'inputSize': inputSize,
        'inputShape': inShape,
        'outputShape': outShape,
        'accelerator': activeAccel,
        'gpuProbe': probeMap,
      });

      final cpuOutBuf = Float32List(inputSize * inputSize);

      cmdPort.listen((msg) {
        final args = msg as List<Object?>;
        final cmd = args[0] as String;

        if (cmd == 'predict') {
          final replyPort = args[1] as SendPort;
          final inTtd = args[2] as TransferableTypedData;
          try {
            final inBytes = inTtd.materialize().asUint8List();
            final inFloats = Float32List.view(inBytes.buffer, inBytes.offsetInBytes, inputSize * inputSize * 3);

            final sw = Stopwatch()..start();
            late final Float32List outFloats;
            if (useGpu && gpuModel != null) {
              outFloats = gpuModel!.run([inFloats]).first;
            } else {
              cpuItp!.run(inBytes, cpuOutBuf);
              outFloats = cpuOutBuf;
            }
            sw.stop();

            replyPort.send({
              'output': TransferableTypedData.fromList([
                outFloats.buffer.asUint8List(outFloats.offsetInBytes, outFloats.lengthInBytes),
              ]),
              'inferenceMs': sw.elapsedMicroseconds / 1000.0,
              'accelerator': activeAccel,
            });
          } catch (e) {
            replyPort.send({'error': e.toString()});
          }
        } else if (cmd == 'probe_p2') {
          final replyPort = args[1] as SendPort;
          final inTtd = args[2] as TransferableTypedData;
          final targetDice = args[3] as double;
          final inBytes = inTtd.materialize().asUint8List();
          final inFloats = Float32List.view(inBytes.buffer, inBytes.offsetInBytes, inputSize * inputSize * 3);

          final res = _evaluateGpuVsCpu(
            modelBytes: modelBytes,
            cpuItp: cpuItp!,
            sampleInput: inFloats,
            inputSize: inputSize,
            targetDice: targetDice,
            existingGpu: gpuModel,
          );
          if (res.passed && res.gpuModel != null) {
            gpuModel = res.gpuModel;
            useGpu = true;
            activeAccel = 'GPU (LiteRT)';
          } else {
            if (res.gpuModel != null && res.gpuModel != gpuModel) {
              res.gpuModel!.close();
            }
            gpuModel?.close();
            gpuModel = null;
            useGpu = false;
            activeAccel = 'CPU ($cpuThreads thread)';
          }
          final map = Map<String, Object?>.of(res.probeMap);
          map['activeAccelerator'] = activeAccel;
          replyPort.send(map);
        } else if (cmd == 'close') {
          final replyPort = args[1] as SendPort;
          gpuModel?.close();
          cpuItp?.close();
          cmdPort.close();
          replyPort.send(true);
        }
      });
    } catch (e) {
      gpuModel?.close();
      cpuItp?.close();
      mainSendPort.send({'error': 'Gagal inisialisasi model: $e'});
    }
  }

  static ({
    Map<String, Object?> probeMap,
    CompiledModel? gpuModel,
    bool passed,
  }) _evaluateGpuVsCpu({
    required Uint8List modelBytes,
    required Interpreter cpuItp,
    required Float32List sampleInput,
    required int inputSize,
    required double targetDice,
    required CompiledModel? existingGpu,
  }) {
    CompiledModel? gm = existingGpu;
    String? fallbackError;
    try {
      gm ??= CompiledModel.fromBufferWithConfig(
        modelBytes,
        config: const CompiledModelConfig.gpuWithCpuFallback(
          precision: Precision.fp32,
        ),
        onFallback: (err) => fallbackError = err.toString(),
      );

      final didFallback = gm.didFallback;
      final accels = gm.accelerators.map((a) => a.name).toList();
      final fullyAccel = gm.isFullyAccelerated;
      final hasGpu = gm.accelerators.contains(Accelerator.gpu) && !didFallback;

      final cpuOut = Float32List(inputSize * inputSize);
      // Warmup
      cpuItp.run(sampleInput.buffer.asUint8List(sampleInput.offsetInBytes, sampleInput.lengthInBytes), cpuOut);
      gm.run([sampleInput]);

      final swCpu = Stopwatch()..start();
      cpuItp.run(sampleInput.buffer.asUint8List(sampleInput.offsetInBytes, sampleInput.lengthInBytes), cpuOut);
      swCpu.stop();
      final cpuMs = swCpu.elapsedMicroseconds / 1000.0;

      final swGpu = Stopwatch()..start();
      final gpuOut = gm.run([sampleInput]).first;
      swGpu.stop();
      final gpuMs = swGpu.elapsedMicroseconds / 1000.0;

      int inter = 0;
      int sumCpu = 0;
      int sumGpu = 0;
      double diffSum = 0.0;
      double maxDiff = 0.0;

      for (int i = 0; i < cpuOut.length; i++) {
        final c = cpuOut[i].clamp(0.0, 1.0);
        final g = gpuOut[i].clamp(0.0, 1.0);
        if (g.isNaN) {
          maxDiff = double.infinity;
          break;
        }
        final d = (c - g).abs();
        diffSum += d;
        if (d > maxDiff) maxDiff = d;

        final cb = (c * 255.0).toInt() >= 128;
        final gb = (g * 255.0).toInt() >= 128;
        if (cb) sumCpu++;
        if (gb) sumGpu++;
        if (cb && gb) inter++;
      }

      final dice = (sumCpu == 0 && sumGpu == 0) ? 1.0 : (2.0 * inter) / (sumCpu + sumGpu);
      final mad = diffSum / cpuOut.length;
      final silentCpu = maxDiff == 0.0 && !fullyAccel;
      final passed = hasGpu && !silentCpu && dice >= targetDice && maxDiff.isFinite && gpuMs <= cpuMs;

      final String decision;
      if (!hasGpu) {
        decision = 'GPU tidak tersedia (${fallbackError ?? 'fallback CPU'}); memakai CPU.';
      } else if (silentCpu) {
        decision = 'Delegasi GPU jatuh ke CPU; memakai Interpreter CPU.';
      } else if (dice < targetDice || !maxDiff.isFinite) {
        decision = 'Paritas GPU di bawah target (Dice=${dice.toStringAsFixed(4)} < $targetDice); GPU dimatikan.';
      } else if (gpuMs > cpuMs) {
        decision = 'Paritas GPU lulus (Dice=${dice.toStringAsFixed(5)}), tetapi CPU lebih cepat; memakai CPU.';
      } else {
        decision = 'GPU LULUS paritas P2 (Dice=${dice.toStringAsFixed(5)}, ${gpuMs.toStringAsFixed(1)} ms vs CPU ${cpuMs.toStringAsFixed(1)} ms).';
      }

      return (
        probeMap: {
          'gpuCompiled': hasGpu,
          'didFallbackToCpu': didFallback || silentCpu,
          'isFullyAccelerated': fullyAccel,
          'effectiveAccelerators': accels,
          'diceVsCpu': dice,
          'madVsCpu': mad,
          'maxAbsDiff': maxDiff,
          'gpuInferenceMs': gpuMs,
          'cpuInferenceMs': cpuMs,
          'passedP2': passed,
          'decision': decision,
          'error': fallbackError,
        },
        gpuModel: gm,
        passed: passed,
      );
    } catch (e) {
      if (gm != existingGpu) gm?.close();
      return (
        probeMap: {
          'gpuCompiled': false,
          'didFallbackToCpu': true,
          'isFullyAccelerated': false,
          'effectiveAccelerators': <String>['cpu'],
          'diceVsCpu': 0.0,
          'madVsCpu': 1.0,
          'maxAbsDiff': 1.0,
          'gpuInferenceMs': 0.0,
          'cpuInferenceMs': 0.0,
          'passedP2': false,
          'decision': 'Kompilasi GPU gagal ($e); memakai CPU.',
          'error': e.toString(),
        },
        gpuModel: null,
        passed: false,
      );
    }
  }

  static Float32List _makeSyntheticInput(int size) {
    final out = Float32List(size * size * 3);
    for (int i = 0; i < out.length; i++) {
      out[i] = ((i * 37) % 256).toDouble();
    }
    return out;
  }

  Future<void> dispose() async {
    final port = _workerSendPort;
    final isolate = _workerIsolate;
    _workerSendPort = null;
    _workerIsolate = null;
    if (port != null) {
      final reply = ReceivePort();
      port.send(['close', reply.sendPort]);
      await reply.first.timeout(const Duration(seconds: 2), onTimeout: () => true);
      reply.close();
    }
    isolate?.kill(priority: Isolate.immediate);
  }
}

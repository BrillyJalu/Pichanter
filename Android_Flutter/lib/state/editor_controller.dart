import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../services/image_service.dart';
import '../services/model_service.dart';
import '../services/share_service.dart';
import '../services/storage_service.dart';
import 'history_controller.dart';

enum ProcessStage { idle, preprocessing, inferring, postprocessing }

/// Preset warna latar pas foto & katalog (PRD F4).
class BgPreset {
  const BgPreset({required this.id, required this.label, required this.rgb});

  final String id;
  final String label;

  /// Nilai RGB 24-bit (`0xRRGGBB`), atau `null` untuk latar transparan.
  final int? rgb;

  static const List<BgPreset> defaults = [
    BgPreset(id: 'none', label: 'Transparan', rgb: null),
    BgPreset(id: 'red', label: 'Merah', rgb: 0xD0021B),
    BgPreset(id: 'blue', label: 'Biru', rgb: 0x0A4DA2),
    BgPreset(id: 'white', label: 'Putih', rgb: 0xFFFFFF),
  ];
}

/// Hasil satu sesi hapus background yang disimpan di memori selama layar Hasil terbuka.
class EditorResult {
  const EditorResult({
    this.historyId,
    required this.sourceName,
    required this.originalBytes,
    required this.rgbBytes,
    required this.previewRgbBytes,
    required this.previewWidth,
    required this.previewHeight,
    required this.maskFullRes,
    required this.alphaFullRes,
    required this.previewCutoutPng,
    required this.width,
    required this.height,
    required this.preprocessMs,
    required this.inferenceMs,
    required this.postprocessMs,
    required this.previewMs,
    required this.totalMs,
    required this.accelerator,
    required this.modelVersion,
    required this.feather,
    this.hardThreshold,
  });

  final String? historyId;
  final String sourceName;
  final Uint8List originalBytes;
  final Uint8List rgbBytes;
  final Uint8List previewRgbBytes;
  final int previewWidth;
  final int previewHeight;
  final Uint8List maskFullRes;
  final Uint8List alphaFullRes;
  final Uint8List previewCutoutPng;
  final int width;
  final int height;
  final double preprocessMs;
  final double inferenceMs;
  final double postprocessMs;
  final double previewMs;
  final double totalMs;
  final String accelerator;
  final String modelVersion;
  final double feather;
  final double? hardThreshold;

  EditorResult copyWith({
    String? historyId,
    Uint8List? alphaFullRes,
    Uint8List? previewCutoutPng,
    double? feather,
    double? hardThreshold,
    bool clearThreshold = false,
  }) {
    return EditorResult(
      historyId: historyId ?? this.historyId,
      sourceName: sourceName,
      originalBytes: originalBytes,
      rgbBytes: rgbBytes,
      previewRgbBytes: previewRgbBytes,
      previewWidth: previewWidth,
      previewHeight: previewHeight,
      maskFullRes: maskFullRes,
      alphaFullRes: alphaFullRes ?? this.alphaFullRes,
      previewCutoutPng: previewCutoutPng ?? this.previewCutoutPng,
      width: width,
      height: height,
      preprocessMs: preprocessMs,
      inferenceMs: inferenceMs,
      postprocessMs: postprocessMs,
      previewMs: previewMs,
      totalMs: totalMs,
      accelerator: accelerator,
      modelVersion: modelVersion,
      feather: feather ?? this.feather,
      hardThreshold: clearThreshold ? null : (hardThreshold ?? this.hardThreshold),
    );
  }
}

/// Controller utama alur editor (Beranda -> Proses -> Hasil -> Simpan/Bagikan/Riwayat).
class EditorController extends ChangeNotifier {
  EditorController({
    required this.modelService,
    required this.imageService,
    required this.storageService,
    required this.shareService,
    required this.historyController,
    ImagePicker? picker,
  }) : _picker = picker ?? ImagePicker();

  final ModelService modelService;
  final ImageService imageService;
  final StorageService storageService;
  final ShareService shareService;
  final HistoryController historyController;
  final ImagePicker _picker;

  bool _loadingModel = false;
  String? _modelError;

  // Foto terpilih (layar Proses)
  Uint8List? _selectedBytes;
  String? _selectedName;

  // Status proses & pembatalan
  ProcessStage _stage = ProcessStage.idle;
  int _activeRunToken = 0;
  String? _error;

  // Hasil (layar Hasil)
  EditorResult? _result;
  int? _bgColorRgb; // null = transparan
  int _customColorRgb = 0x2E7D32;
  bool _saving = false;
  bool _sharing = false;
  bool _refining = false;

  bool get loadingModel => _loadingModel;
  bool get modelReady => modelService.isLoaded;
  String? get modelError => _modelError;
  double get modelLoadMs => modelService.loadMs;
  String get modelVersion => modelService.modelVersion;
  String get accelerator => modelService.accelerator;
  GpuParityProbeReport? get lastGpuProbe => modelService.lastGpuProbe;

  Uint8List? get selectedBytes => _selectedBytes;
  String? get selectedName => _selectedName;
  bool get hasSelectedPhoto => _selectedBytes != null;

  ProcessStage get stage => _stage;
  bool get isProcessing => _stage != ProcessStage.idle;
  String? get error => _error;

  EditorResult? get result => _result;
  int? get bgColorRgb => _bgColorRgb;
  int get customColorRgb => _customColorRgb;
  bool get isCustomBg =>
      _bgColorRgb != null && !BgPreset.defaults.any((p) => p.rgb == _bgColorRgb);
  bool get isSaving => _saving;
  bool get isSharing => _sharing;
  bool get isRefining => _refining;
  bool get isBusyAction => _saving || _sharing || _refining;

  String get stageLabel => switch (_stage) {
        ProcessStage.idle => '',
        ProcessStage.preprocessing => 'Menyiapkan foto & koreksi orientasi…',
        ProcessStage.inferring => 'Menghapus background di perangkat…',
        ProcessStage.postprocessing => 'Menghaluskan tepi & menyiapkan pratinjau…',
      };

  /// Muat model sekali saat aplikasi dibuka.
  Future<void> ensureModelLoaded() async {
    if (modelService.isLoaded || _loadingModel) return;
    _loadingModel = true;
    _modelError = null;
    notifyListeners();
    try {
      await modelService.load();
      debugPrint(
        '[PICHANTER] Model loaded: ${modelService.modelVersion} | '
        'accel=${modelService.accelerator} | load=${modelService.loadMs.toStringAsFixed(1)}ms',
      );
    } catch (e) {
      _modelError = 'Gagal memuat model AI: $e';
    } finally {
      _loadingModel = false;
      notifyListeners();
    }
  }

  /// Pilih foto dari kamera atau galeri (PRD F1). Mengembalikan `true` jika foto dipilih.
  Future<bool> pickPhoto(ImageSource source) async {
    _error = null;
    try {
      final picked = await _picker.pickImage(source: source);
      if (picked == null) return false;
      final bytes = await picked.readAsBytes();
      setSelectedPhoto(bytes, picked.name);
      return true;
    } catch (e) {
      _error = 'Tidak bisa membuka foto: $e';
      notifyListeners();
      return false;
    }
  }

  void setSelectedPhoto(Uint8List bytes, String name) {
    _activeRunToken++;
    _selectedBytes = bytes;
    _selectedName = name;
    _result = null;
    _bgColorRgb = null;
    _error = null;
    _stage = ProcessStage.idle;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Batalkan proses yang sedang berjalan (PRD: tombol Batal di layar Proses).
  void cancelProcessing() {
    if (!isProcessing) return;
    _activeRunToken++;
    _stage = ProcessStage.idle;
    notifyListeners();
  }

  /// Jalankan pipeline hapus background on-device pada foto terpilih (PRD F2)
  /// dan simpan otomatis ke riwayat lokal SQLite (PRD F7).
  Future<bool> removeBackground({double feather = 1.5}) async {
    final bytes = _selectedBytes;
    if (bytes == null || isProcessing) return false;

    if (!modelService.isLoaded) {
      await ensureModelLoaded();
      if (!modelService.isLoaded) {
        _error = _modelError ?? 'Model AI belum siap.';
        notifyListeners();
        return false;
      }
    }

    final token = ++_activeRunToken;
    _result = null;
    _error = null;
    _stage = ProcessStage.preprocessing;
    notifyListeners();

    final totalSw = Stopwatch()..start();
    try {
      final prep = await imageService.preprocess(bytes, modelService.inputSize);
      if (token != _activeRunToken) return false;

      _stage = ProcessStage.inferring;
      notifyListeners();

      final infer = await modelService.predictMask(prep.modelInput);
      if (token != _activeRunToken) return false;

      _stage = ProcessStage.postprocessing;
      notifyListeners();

      final maskRes = await imageService.buildFullResAlpha(
        maskProbabilities: infer.maskProbabilities,
        maskSize: infer.maskSize,
        width: prep.width,
        height: prep.height,
        feather: feather,
        previewRgbBytes: prep.previewRgbBytes,
        previewWidth: prep.previewWidth,
        previewHeight: prep.previewHeight,
      );
      if (token != _activeRunToken) return false;

      final previewPng = maskRes.previewCutoutPng!;
      totalSw.stop();
      if (token != _activeRunToken) return false;

      final totalMs = totalSw.elapsedMicroseconds / 1000.0;
      final srcName = _selectedName ?? 'foto';

      // Simpan ke riwayat lokal SQLite (PRD F7)
      String? historyId;
      try {
        final entry = await storageService.saveHistoryItem(
          sourceName: srcName,
          originalBytes: bytes,
          maskSmallU8: maskRes.maskSmallU8,
          previewCutoutPng: previewPng,
          maskSize: maskRes.maskSize,
          width: prep.width,
          height: prep.height,
          preprocessMs: prep.preprocessMs,
          inferenceMs: infer.inferenceMs,
          postprocessMs: maskRes.postprocessMs,
          totalMs: totalMs,
          modelVersion: infer.modelVersion,
          accelerator: infer.accelerator,
          feather: feather,
        );
        historyId = entry.id;
        historyController.prepend(entry);
      } catch (e) {
        debugPrint('[PICHANTER] Gagal menyimpan riwayat lokal: $e');
      }

      debugPrint(
        '[PICHANTER] Processed "$srcName" (${prep.width}x${prep.height}) | '
        'pre=${prep.preprocessMs.toStringAsFixed(1)}ms | '
        'inf=${infer.inferenceMs.toStringAsFixed(1)}ms | '
        'post=${maskRes.postprocessMs.toStringAsFixed(1)}ms | '
        'total=${totalMs.toStringAsFixed(1)}ms | accel=${infer.accelerator}',
      );

      _result = EditorResult(
        historyId: historyId,
        sourceName: srcName,
        originalBytes: bytes,
        rgbBytes: prep.rgbBytes,
        previewRgbBytes: prep.previewRgbBytes,
        previewWidth: prep.previewWidth,
        previewHeight: prep.previewHeight,
        maskFullRes: maskRes.maskFullRes,
        alphaFullRes: maskRes.alphaFullRes,
        previewCutoutPng: previewPng,
        width: prep.width,
        height: prep.height,
        preprocessMs: prep.preprocessMs,
        inferenceMs: infer.inferenceMs,
        postprocessMs: maskRes.postprocessMs,
        previewMs: 0.0,
        totalMs: totalMs,
        accelerator: infer.accelerator,
        modelVersion: infer.modelVersion,
        feather: feather,
      );
      _bgColorRgb = null;
      _stage = ProcessStage.idle;
      notifyListeners();
      return true;
    } catch (e) {
      if (token != _activeRunToken) return false;
      _stage = ProcessStage.idle;
      _error = 'Gagal memproses foto: $e';
      notifyListeners();
      return false;
    }
  }

  /// Buka kembali item dari riwayat lokal tanpa inferensi AI ulang (PRD F7).
  Future<bool> openFromHistory(HistoryEntry entry) async {
    if (isProcessing) return false;
    final token = ++_activeRunToken;
    _result = null;
    _error = null;
    _stage = ProcessStage.postprocessing;
    notifyListeners();

    try {
      final origBytes = await File(entry.originalPath).readAsBytes();
      final maskSmallBytes = await File(entry.maskSmallPath).readAsBytes();
      if (token != _activeRunToken) return false;

      final rebuilt = await imageService.rebuildFromSmallMask(
        encodedBytes: origBytes,
        maskSmallU8: maskSmallBytes,
        maskSize: entry.maskSize,
        feather: entry.feather,
        hardThreshold: entry.hardThreshold,
      );
      if (token != _activeRunToken) return false;

      _selectedBytes = origBytes;
      _selectedName = entry.sourceName;
      _bgColorRgb = entry.bgColorRgb;
      if (entry.bgColorRgb != null &&
          !BgPreset.defaults.any((p) => p.rgb == entry.bgColorRgb)) {
        _customColorRgb = entry.bgColorRgb!;
      }

      _result = EditorResult(
        historyId: entry.id,
        sourceName: entry.sourceName,
        originalBytes: origBytes,
        rgbBytes: rebuilt.prepared.rgbBytes,
        previewRgbBytes: rebuilt.prepared.previewRgbBytes,
        previewWidth: rebuilt.prepared.previewWidth,
        previewHeight: rebuilt.prepared.previewHeight,
        maskFullRes: rebuilt.maskResult.maskFullRes,
        alphaFullRes: rebuilt.maskResult.alphaFullRes,
        previewCutoutPng: rebuilt.maskResult.previewCutoutPng!,
        width: rebuilt.prepared.width,
        height: rebuilt.prepared.height,
        preprocessMs: entry.preprocessMs,
        inferenceMs: entry.inferenceMs,
        postprocessMs: entry.postprocessMs,
        previewMs: 0.0,
        totalMs: entry.totalMs,
        accelerator: entry.accelerator,
        modelVersion: entry.modelVersion,
        feather: entry.feather,
        hardThreshold: entry.hardThreshold,
      );
      _stage = ProcessStage.idle;
      notifyListeners();
      return true;
    } catch (e) {
      if (token != _activeRunToken) return false;
      _stage = ProcessStage.idle;
      _error = 'Gagal membuka riwayat: $e';
      notifyListeners();
      return false;
    }
  }

  /// Ubah kehalusan tepi (`feather`) dan ambang mask (`hardThreshold`) tanpa inferensi ulang (PRD F8).
  Future<void> updateEdgeSettings({
    required double feather,
    required double? hardThreshold,
  }) async {
    final res = _result;
    if (res == null || _refining) return;
    if (res.feather == feather && res.hardThreshold == hardThreshold) return;

    _refining = true;
    _error = null;
    notifyListeners();

    try {
      final refined = await imageService.refineAlphaAndPreview(
        maskFullRes: res.maskFullRes,
        width: res.width,
        height: res.height,
        previewRgbBytes: res.previewRgbBytes,
        previewWidth: res.previewWidth,
        previewHeight: res.previewHeight,
        feather: feather,
        hardThreshold: hardThreshold,
      );

      _result = res.copyWith(
        alphaFullRes: refined.alphaFullRes,
        previewCutoutPng: refined.previewCutoutPng,
        feather: feather,
        hardThreshold: hardThreshold,
        clearThreshold: hardThreshold == null,
      );

      if (res.historyId != null) {
        await storageService.updateHistorySettings(
          id: res.historyId!,
          feather: feather,
          hardThreshold: hardThreshold,
          bgColorRgb: _bgColorRgb,
          updatedThumbPng: refined.previewCutoutPng,
        );
        await historyController.load();
      }
    } catch (e) {
      _error = 'Gagal memperbarui tepi mask: $e';
    } finally {
      _refining = false;
      notifyListeners();
    }
  }

  void selectBackground(int? rgb) {
    if (_bgColorRgb == rgb) return;
    _bgColorRgb = rgb;
    notifyListeners();
    _syncHistoryBg();
  }

  void selectCustomColor(int rgb) {
    _customColorRgb = rgb & 0xFFFFFF;
    _bgColorRgb = _customColorRgb;
    notifyListeners();
    _syncHistoryBg();
  }

  void _syncHistoryBg() {
    final res = _result;
    if (res != null && res.historyId != null) {
      storageService.updateHistorySettings(
        id: res.historyId!,
        feather: res.feather,
        hardThreshold: res.hardThreshold,
        bgColorRgb: _bgColorRgb,
      );
    }
  }

  /// Simpan hasil ukuran asli ke Galeri sebagai PNG atau JPG (PRD F5).
  Future<SavedGalleryFile?> saveResult({required ExportFormat format}) async {
    final res = _result;
    if (res == null || isBusyAction) return null;

    if (format == ExportFormat.jpg && _bgColorRgb == null) {
      _error = 'Format JPG butuh warna latar. Pilih warna latar atau simpan sebagai PNG transparan.';
      notifyListeners();
      return null;
    }

    _saving = true;
    _error = null;
    notifyListeners();

    try {
      final exported = await imageService.exportFullRes(
        rgbBytes: res.rgbBytes,
        alphaFullRes: res.alphaFullRes,
        width: res.width,
        height: res.height,
        format: format,
        bgColorRgb: _bgColorRgb,
      );
      final saved = await storageService.saveToGallery(
        exported: exported,
        bgColorRgb: _bgColorRgb,
      );
      return saved;
    } catch (e) {
      _error = 'Gagal menyimpan ke galeri: $e';
      return null;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// Bagikan hasil ukuran asli ke aplikasi lain (WhatsApp, Drive, dll.) (PRD F6).
  Future<ShareResult?> shareResult({ExportFormat? preferredFormat}) async {
    final res = _result;
    if (res == null || isBusyAction) return null;

    final fmt = preferredFormat ??
        (_bgColorRgb == null ? ExportFormat.png : ExportFormat.jpg);

    _sharing = true;
    _error = null;
    notifyListeners();

    try {
      final exported = await imageService.exportFullRes(
        rgbBytes: res.rgbBytes,
        alphaFullRes: res.alphaFullRes,
        width: res.width,
        height: res.height,
        format: fmt,
        bgColorRgb: _bgColorRgb,
      );
      return await shareService.shareExportedImage(
        exported: exported,
        bgColorRgb: _bgColorRgb,
      );
    } catch (e) {
      _error = 'Gagal membagikan hasil: $e';
      return null;
    } finally {
      _sharing = false;
      notifyListeners();
    }
  }

  void resetSession() {
    _activeRunToken++;
    _selectedBytes = null;
    _selectedName = null;
    _result = null;
    _bgColorRgb = null;
    _stage = ProcessStage.idle;
    _error = null;
    notifyListeners();
  }
}

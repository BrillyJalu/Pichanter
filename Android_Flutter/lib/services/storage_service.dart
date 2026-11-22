import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'image_service.dart';

/// Hasil penyimpanan ke galeri perangkat (PRD F5).
class SavedGalleryFile {
  const SavedGalleryFile({
    required this.fileName,
    required this.album,
    required this.byteSize,
    required this.width,
    required this.height,
    required this.format,
    required this.encodeMs,
  });

  final String fileName;
  final String album;
  final int byteSize;
  final int width;
  final int height;
  final ExportFormat format;
  final double encodeMs;
}

/// Satu entri riwayat lokal di SQLite (PRD F7 & Keterlacakan).
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.createdAt,
    required this.sourceName,
    required this.originalPath,
    required this.maskSmallPath,
    required this.thumbPath,
    required this.maskSize,
    required this.width,
    required this.height,
    required this.preprocessMs,
    required this.inferenceMs,
    required this.postprocessMs,
    required this.totalMs,
    required this.modelVersion,
    required this.accelerator,
    required this.feather,
    this.hardThreshold,
    this.bgColorRgb,
  });

  final String id;
  final DateTime createdAt;
  final String sourceName;
  final String originalPath;
  final String maskSmallPath;
  final String thumbPath;
  final int maskSize;
  final int width;
  final int height;
  final double preprocessMs;
  final double inferenceMs;
  final double postprocessMs;
  final double totalMs;
  final String modelVersion;
  final String accelerator;
  final double feather;
  final double? hardThreshold;
  final int? bgColorRgb;

  Map<String, Object?> toMap() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        'source_name': sourceName,
        'original_path': originalPath,
        'mask_small_path': maskSmallPath,
        'thumb_path': thumbPath,
        'mask_size': maskSize,
        'width': width,
        'height': height,
        'preprocess_ms': preprocessMs,
        'inference_ms': inferenceMs,
        'postprocess_ms': postprocessMs,
        'total_ms': totalMs,
        'model_version': modelVersion,
        'accelerator': accelerator,
        'feather': feather,
        'hard_threshold': hardThreshold,
        'bg_color_rgb': bgColorRgb,
      };

  factory HistoryEntry.fromMap(Map<String, Object?> m) {
    return HistoryEntry(
      id: m['id'] as String,
      createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
      sourceName: m['source_name'] as String? ?? 'Foto',
      originalPath: m['original_path'] as String,
      maskSmallPath: m['mask_small_path'] as String,
      thumbPath: m['thumb_path'] as String,
      maskSize: (m['mask_size'] as num?)?.toInt() ?? 384,
      width: (m['width'] as num).toInt(),
      height: (m['height'] as num).toInt(),
      preprocessMs: (m['preprocess_ms'] as num?)?.toDouble() ?? 0.0,
      inferenceMs: (m['inference_ms'] as num).toDouble(),
      postprocessMs: (m['postprocess_ms'] as num?)?.toDouble() ?? 0.0,
      totalMs: (m['total_ms'] as num).toDouble(),
      modelVersion: m['model_version'] as String? ?? 'unet-mnv3l-384-fp16-v2',
      accelerator: m['accelerator'] as String? ?? 'CPU',
      feather: (m['feather'] as num?)?.toDouble() ?? 1.5,
      hardThreshold: (m['hard_threshold'] as num?)?.toDouble(),
      bgColorRgb: (m['bg_color_rgb'] as num?)?.toInt(),
    );
  }
}

/// Layanan penyimpanan:
/// 1. Simpan ke Galeri perangkat di album `Pichanter` (PRD F5).
/// 2. Simpan & kelola riwayat lokal dengan SQLite + folder aplikasi (PRD F7).
class StorageService {
  StorageService();

  static const String albumName = 'Pichanter';
  Database? _db;

  Future<Database> _getDb() async {
    if (_db != null) return _db!;
    final dbDir = await getDatabasesPath();
    final path = p.join(dbDir, 'pichanter_history.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE history (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            source_name TEXT NOT NULL,
            original_path TEXT NOT NULL,
            mask_small_path TEXT NOT NULL,
            thumb_path TEXT NOT NULL,
            mask_size INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            preprocess_ms REAL NOT NULL,
            inference_ms REAL NOT NULL,
            postprocess_ms REAL NOT NULL,
            total_ms REAL NOT NULL,
            model_version TEXT NOT NULL,
            accelerator TEXT NOT NULL,
            feather REAL NOT NULL,
            hard_threshold REAL,
            bg_color_rgb INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_history_created ON history(created_at DESC)');
      },
    );
    return _db!;
  }

  /// Simpan byte PNG/JPG ke Galeri perangkat di album `Pichanter`.
  Future<SavedGalleryFile> saveToGallery({
    required ExportedImage exported,
    int? bgColorRgb,
  }) async {
    final hasAccess = await Gal.hasPermission(toAlbum: true);
    if (!hasAccess) {
      await Gal.requestPermission(toAlbum: true);
    }

    final now = DateTime.now();
    final ts = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final bgTag = bgColorRgb == null
        ? ''
        : '_${bgColorRgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final baseName = 'pichanter_$ts$bgTag';
    final ext = exported.format == ExportFormat.jpg ? 'jpg' : 'png';

    await Gal.putImageBytes(
      exported.bytes,
      album: albumName,
      name: baseName,
    );

    return SavedGalleryFile(
      fileName: '$baseName.$ext',
      album: albumName,
      byteSize: exported.bytes.length,
      width: exported.width,
      height: exported.height,
      format: exported.format,
      encodeMs: exported.encodeMs,
    );
  }

  /// Simpan satu hasil proses ke riwayat lokal (SQLite + file aplikasi).
  Future<HistoryEntry> saveHistoryItem({
    required String sourceName,
    required Uint8List originalBytes,
    required Uint8List maskSmallU8,
    required Uint8List previewCutoutPng,
    required int maskSize,
    required int width,
    required int height,
    required double preprocessMs,
    required double inferenceMs,
    required double postprocessMs,
    required double totalMs,
    required String modelVersion,
    required String accelerator,
    required double feather,
    double? hardThreshold,
    int? bgColorRgb,
  }) async {
    final now = DateTime.now();
    final id = '${now.millisecondsSinceEpoch}_${now.microsecond}';
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(docs.path, 'history', id));
    await folder.create(recursive: true);

    final origPath = p.join(folder.path, 'original.bin');
    final maskPath = p.join(folder.path, 'mask_small.bin');
    final thumbPath = p.join(folder.path, 'thumb.png');

    await File(origPath).writeAsBytes(originalBytes, flush: true);
    await File(maskPath).writeAsBytes(maskSmallU8, flush: true);
    await File(thumbPath).writeAsBytes(previewCutoutPng, flush: true);

    final entry = HistoryEntry(
      id: id,
      createdAt: now,
      sourceName: sourceName,
      originalPath: origPath,
      maskSmallPath: maskPath,
      thumbPath: thumbPath,
      maskSize: maskSize,
      width: width,
      height: height,
      preprocessMs: preprocessMs,
      inferenceMs: inferenceMs,
      postprocessMs: postprocessMs,
      totalMs: totalMs,
      modelVersion: modelVersion,
      accelerator: accelerator,
      feather: feather,
      hardThreshold: hardThreshold,
      bgColorRgb: bgColorRgb,
    );

    final db = await _getDb();
    await db.insert('history', entry.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    return entry;
  }

  /// Perbarui pengaturan warna latar / feather / threshold + thumbnail untuk item riwayat yang sedang diedit.
  Future<void> updateHistorySettings({
    required String id,
    required double feather,
    required double? hardThreshold,
    required int? bgColorRgb,
    Uint8List? updatedThumbPng,
  }) async {
    final db = await _getDb();
    final rows = await db.query('history', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;

    if (updatedThumbPng != null) {
      final thumbPath = rows.first['thumb_path'] as String?;
      if (thumbPath != null) {
        await File(thumbPath).writeAsBytes(updatedThumbPng, flush: true);
      }
    }

    await db.update(
      'history',
      {
        'feather': feather,
        'hard_threshold': hardThreshold,
        'bg_color_rgb': bgColorRgb,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Ambil daftar riwayat terbaru dari SQLite.
  Future<List<HistoryEntry>> listHistory({int limit = 100}) async {
    final db = await _getDb();
    final rows = await db.query('history', orderBy: 'created_at DESC', limit: limit);
    final entries = <HistoryEntry>[];
    for (final r in rows) {
      final entry = HistoryEntry.fromMap(r);
      if (File(entry.thumbPath).existsSync() &&
          File(entry.originalPath).existsSync() &&
          File(entry.maskSmallPath).existsSync()) {
        entries.add(entry);
      } else {
        await db.delete('history', where: 'id = ?', whereArgs: [entry.id]);
      }
    }
    return entries;
  }

  /// Hapus satu entri riwayat dari SQLite dan hapus folder file-nya.
  Future<void> deleteHistoryItem(HistoryEntry entry) async {
    final db = await _getDb();
    await db.delete('history', where: 'id = ?', whereArgs: [entry.id]);
    final folder = File(entry.thumbPath).parent;
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }

  /// Hapus seluruh riwayat.
  Future<void> clearAllHistory() async {
    final db = await _getDb();
    await db.delete('history');
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'history'));
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'image_service.dart';

/// Layanan untuk membagikan gambar hasil ke aplikasi lain (WhatsApp, Drive, dll.) (PRD F6).
class ShareService {
  const ShareService();

  Future<ShareResult> shareExportedImage({
    required ExportedImage exported,
    int? bgColorRgb,
  }) async {
    final tmpDir = await getTemporaryDirectory();
    final shareDir = Directory(p.join(tmpDir.path, 'share'));
    if (!await shareDir.exists()) {
      await shareDir.create(recursive: true);
    }

    // Bersihkan file share sementara yang lebih lama dari 1 jam agar cache tetap ramping.
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in shareDir.list()) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
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
    final isJpg = exported.format == ExportFormat.jpg;
    final ext = isJpg ? 'jpg' : 'png';
    final mime = isJpg ? 'image/jpeg' : 'image/png';
    final fileName = 'pichanter_$ts$bgTag.$ext';
    final filePath = p.join(shareDir.path, fileName);

    final file = File(filePath);
    await file.writeAsBytes(exported.bytes, flush: true);

    return SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime, name: fileName)],
        title: 'Hasil Pichanter',
      ),
    );
  }
}

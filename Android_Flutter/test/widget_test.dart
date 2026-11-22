import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pichanter_mobile/services/image_service.dart';

void main() {
  test('ImageService preprocess, alpha refinement, and full-res PNG/JPG export', () async {
    final src = img.Image(width: 160, height: 120);
    img.fill(src, color: img.ColorRgb8(40, 180, 60));
    final jpgBytes = img.encodeJpg(src);

    const svc = ImageService();
    final prep = await svc.preprocess(jpgBytes, 384);
    expect(prep.width, 160);
    expect(prep.height, 120);
    expect(prep.modelInput.length, 384 * 384 * 3);
    expect(prep.modelInput[0], closeTo(40.0, 6.0));

    final fakeMask = Float32List(384 * 384);
    for (int y = 96; y < 288; y++) {
      for (int x = 96; x < 288; x++) {
        fakeMask[y * 384 + x] = 1.0;
      }
    }

    final maskRes = await svc.buildFullResAlpha(
      maskProbabilities: fakeMask,
      maskSize: 384,
      width: prep.width,
      height: prep.height,
      feather: 1.5,
    );

    // 1. PNG transparan
    final pngTrans = await svc.exportFullRes(
      rgbBytes: prep.rgbBytes,
      alphaFullRes: maskRes.alphaFullRes,
      width: prep.width,
      height: prep.height,
      format: ExportFormat.png,
      bgColorRgb: null,
    );
    final decPng = img.decodePng(pngTrans.bytes)!;
    expect(decPng.width, 160);
    expect(decPng.height, 120);
    expect(decPng.numChannels, 4);
    expect(decPng.getPixel(2, 2).a, lessThan(20));
    expect(decPng.getPixel(80, 60).a, greaterThan(235));

    // 2. JPG berlatar merah (#FF0000)
    final jpgRed = await svc.exportFullRes(
      rgbBytes: prep.rgbBytes,
      alphaFullRes: maskRes.alphaFullRes,
      width: prep.width,
      height: prep.height,
      format: ExportFormat.jpg,
      bgColorRgb: 0xFF0000,
    );
    final decJpg = img.decodeJpg(jpgRed.bytes)!;
    expect(decJpg.width, 160);
    expect(decJpg.height, 120);
    final corner = decJpg.getPixel(2, 2);
    expect(corner.r, greaterThan(220));
    expect(corner.g, lessThan(30));
    expect(corner.b, lessThan(30));

    // 3. JPG tanpa warna latar harus ditolak
    await expectLater(
      svc.exportFullRes(
        rgbBytes: prep.rgbBytes,
        alphaFullRes: maskRes.alphaFullRes,
        width: prep.width,
        height: prep.height,
        format: ExportFormat.jpg,
        bgColorRgb: null,
      ),
      throwsArgumentError,
    );
    // 4. refineAlphaAndPreview (PRD F8) & rebuildFromSmallMask (PRD F7)
    final refined = await svc.refineAlphaAndPreview(
      maskFullRes: maskRes.maskFullRes,
      width: prep.width,
      height: prep.height,
      previewRgbBytes: prep.previewRgbBytes,
      previewWidth: prep.previewWidth,
      previewHeight: prep.previewHeight,
      feather: 2.5,
      hardThreshold: 0.5,
    );
    expect(refined.alphaFullRes.length, 160 * 120);
    expect(img.decodePng(refined.previewCutoutPng), isNotNull);

    final rebuilt = await svc.rebuildFromSmallMask(
      encodedBytes: jpgBytes,
      maskSmallU8: maskRes.maskSmallU8,
      maskSize: 384,
      feather: 1.5,
    );
    expect(rebuilt.prepared.width, 160);
    expect(rebuilt.maskResult.previewCutoutPng, isNotNull);
  });
}

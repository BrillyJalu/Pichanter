import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

enum ExportFormat { png, jpg }

/// Hasil pra-proses: foto RGB sudah dibetulkan orientasi EXIF + tensor input `[1, S, S, 3]`.
class PreparedPhoto {
  const PreparedPhoto({
    required this.rgbBytes,
    required this.width,
    required this.height,
    required this.previewRgbBytes,
    required this.previewWidth,
    required this.previewHeight,
    required this.modelInput,
    required this.inputSize,
    required this.preprocessMs,
  });

  /// Piksel RGB padat 3 byte/piksel (`width * height * 3`), sudah EXIF-transposed.
  final Uint8List rgbBytes;
  final int width;
  final int height;

  /// Piksel RGB pratinjau (maks. sisi terpanjang 1080 px, hanya ~2,6 MB) agar komposit pratinjau
  /// tidak perlu menyalin buffer 36 MB lintas isolate.
  final Uint8List previewRgbBytes;
  final int previewWidth;
  final int previewHeight;

  /// Float32List RGB 0..255 datar (`inputSize * inputSize * 3`), tanpa normalisasi.
  final Float32List modelInput;
  final int inputSize;
  final double preprocessMs;
}

/// Hasil pasca-proses mask pada resolusi asli (disimpan di memori agar ganti latar/slider cepat).
class FullResMaskResult {
  const FullResMaskResult({
    required this.maskSmallU8,
    required this.maskSize,
    required this.maskFullRes,
    required this.alphaFullRes,
    required this.width,
    required this.height,
    required this.postprocessMs,
    this.previewCutoutPng,
  });

  /// Mask 0..255 pada resolusi model (`maskSize * maskSize`), sebelum upscale.
  final Uint8List maskSmallU8;
  final int maskSize;

  /// Mask 0..255 ukuran asli, sebelum threshold/feather.
  final Uint8List maskFullRes;

  /// Kanal alpha 0..255 ukuran asli, setelah threshold opsional & Gaussian blur (`feather`).
  final Uint8List alphaFullRes;
  final int width;
  final int height;
  final double postprocessMs;

  /// PNG transparan ukuran pratinjau (bila `previewRgbBytes` diberikan).
  final Uint8List? previewCutoutPng;
}

/// Hasil ekspor PNG/JPG ukuran asli.
class ExportedImage {
  const ExportedImage({
    required this.bytes,
    required this.format,
    required this.width,
    required this.height,
    required this.encodeMs,
  });

  final Uint8List bytes;
  final ExportFormat format;
  final int width;
  final int height;
  final double encodeMs;
}

/// Hasil gabungan cutout PNG transparan (untuk kemudahan spike/uji).
class ComposedCutout {
  const ComposedCutout({
    required this.maskSmallU8,
    required this.maskFullRes,
    required this.alphaFullRes,
    required this.cutoutPngBytes,
    required this.width,
    required this.height,
    required this.postprocessMs,
    required this.encodeMs,
  });

  final Uint8List maskSmallU8;
  final Uint8List maskFullRes;
  final Uint8List alphaFullRes;
  final Uint8List cutoutPngBytes;
  final int width;
  final int height;
  final double postprocessMs;
  final double encodeMs;
}

/// Layanan olah gambar yang meniru persis pipeline `pichanter_bg.py` (Pillow)
/// dan dijalankan di isolate terpisah agar UI tidak membeku.
///
/// Dioptimasi dengan aritmetika fixed-point integer & buffer `Uint8List`
/// untuk mencapai latensi <= 2 detik dan memori puncak <= 400 MB pada foto 12 MP.
class ImageService {
  const ImageService();

  /// Decode gambar, betulkan EXIF, resize bilinear anti-aliased (identik `PIL.Image.BILINEAR`)
  /// ke `inputSize x inputSize` sebagai `Float32List` RGB 0..255.
  Future<PreparedPhoto> preprocess(Uint8List encodedBytes, int inputSize) {
    return Isolate.run(() => _preprocessSync(encodedBytes, inputSize));
  }

  /// Buat mask resolusi asli + kanal alpha (dengan threshold opsional & Gaussian blur `feather`).
  /// Bila [previewRgbBytes] disertakan, PNG pratinjau langsung dibuat di isolate yang sama
  /// tanpa menyalin buffer RGB 12 MP lintas isolate.
  Future<FullResMaskResult> buildFullResAlpha({
    required Float32List maskProbabilities,
    required int maskSize,
    required int width,
    required int height,
    double feather = 1.5,
    double? hardThreshold,
    Uint8List? previewRgbBytes,
    int? previewWidth,
    int? previewHeight,
  }) {
    return Isolate.run(
      () => _buildFullResAlphaSync(
        maskProbabilities: maskProbabilities,
        maskSize: maskSize,
        width: width,
        height: height,
        feather: feather,
        hardThreshold: hardThreshold,
        previewRgbBytes: previewRgbBytes,
        previewWidth: previewWidth,
        previewHeight: previewHeight,
      ),
    );
  }

  /// Terapkan ulang threshold & feather dari `maskFullRes` yang sudah ada (tanpa inferensi ulang),
  /// sekaligus perbarui PNG pratinjau ukuran layar (PRD F8).
  Future<({Uint8List alphaFullRes, Uint8List previewCutoutPng})> refineAlphaAndPreview({
    required Uint8List maskFullRes,
    required int width,
    required int height,
    required Uint8List previewRgbBytes,
    required int previewWidth,
    required int previewHeight,
    double feather = 1.5,
    double? hardThreshold,
  }) {
    return Isolate.run(() {
      final alpha = _refineAlphaSync(
        maskFullRes: maskFullRes,
        width: width,
        height: height,
        feather: feather,
        hardThreshold: hardThreshold,
      );
      final pAlpha = (previewWidth == width && previewHeight == height)
          ? alpha
          : _resizeGrayNearestFast(alpha, width, height, previewWidth, previewHeight);
      final previewPng = _exportFullResSync(
        rgbBytes: previewRgbBytes,
        alphaFullRes: pAlpha,
        width: previewWidth,
        height: previewHeight,
        format: ExportFormat.png,
        bgColorRgb: null,
        jpegQuality: 90,
        pngCompressionLevel: 1,
      ).bytes;
      return (alphaFullRes: alpha, previewCutoutPng: previewPng);
    });
  }

  /// Rekonstruksi data editor penuh dari foto asli + `maskSmallU8` (384x384) yang tersimpan di riwayat lokal
  /// tanpa menjalankan ulang inferensi AI (PRD F7).
  Future<({PreparedPhoto prepared, FullResMaskResult maskResult})> rebuildFromSmallMask({
    required Uint8List encodedBytes,
    required Uint8List maskSmallU8,
    required int maskSize,
    double feather = 1.5,
    double? hardThreshold,
  }) {
    return Isolate.run(() {
      final prep = _preprocessSync(encodedBytes, maskSize);
      final sw = Stopwatch()..start();
      final maskFull = _resizeGrayPillowBilinear(
        maskSmallU8,
        maskSize,
        maskSize,
        prep.width,
        prep.height,
      );
      final alpha = _refineAlphaSync(
        maskFullRes: maskFull,
        width: prep.width,
        height: prep.height,
        feather: feather,
        hardThreshold: hardThreshold,
      );
      final pAlpha = (prep.previewWidth == prep.width && prep.previewHeight == prep.height)
          ? alpha
          : _resizeGrayNearestFast(alpha, prep.width, prep.height, prep.previewWidth, prep.previewHeight);
      final previewPng = _exportFullResSync(
        rgbBytes: prep.previewRgbBytes,
        alphaFullRes: pAlpha,
        width: prep.previewWidth,
        height: prep.previewHeight,
        format: ExportFormat.png,
        bgColorRgb: null,
        jpegQuality: 90,
        pngCompressionLevel: 1,
      ).bytes;
      sw.stop();

      final maskRes = FullResMaskResult(
        maskSmallU8: maskSmallU8,
        maskSize: maskSize,
        maskFullRes: maskFull,
        alphaFullRes: alpha,
        width: prep.width,
        height: prep.height,
        postprocessMs: sw.elapsedMicroseconds / 1000.0,
        previewCutoutPng: previewPng,
      );
      return (prepared: prep, maskResult: maskRes);
    });
  }

  /// Terapkan ulang threshold & feather dari `maskFullRes` yang sudah ada (tanpa inferensi ulang).
  Future<Uint8List> refineAlpha({
    required Uint8List maskFullRes,
    required int width,
    required int height,
    double feather = 1.5,
    double? hardThreshold,
  }) {
    return Isolate.run(
      () => _refineAlphaSync(
        maskFullRes: maskFullRes,
        width: width,
        height: height,
        feather: feather,
        hardThreshold: hardThreshold,
      ),
    );
  }

  /// Ekspor ukuran asli ke PNG transparan, PNG berlatar warna, atau JPG berlatar warna.
  ///
  /// [bgColorRgb] adalah warna `0xRRGGBB` (null = transparan, hanya untuk PNG).
  Future<ExportedImage> exportFullRes({
    required Uint8List rgbBytes,
    required Uint8List alphaFullRes,
    required int width,
    required int height,
    required ExportFormat format,
    int? bgColorRgb,
    int jpegQuality = 92,
    int pngCompressionLevel = 3,
  }) {
    return Isolate.run(
      () => _exportFullResSync(
        rgbBytes: rgbBytes,
        alphaFullRes: alphaFullRes,
        width: width,
        height: height,
        format: format,
        bgColorRgb: bgColorRgb,
        jpegQuality: jpegQuality,
        pngCompressionLevel: pngCompressionLevel,
      ),
    );
  }

  /// Buat PNG pratinjau ukuran layar (maks. sisi terpanjang `maxSide`, default 1080 px)
  /// agar pratinjau cepat tampil meski foto asli 12 MP.
  Future<Uint8List> buildPreviewPng({
    required Uint8List rgbBytes,
    required Uint8List alphaFullRes,
    required int width,
    required int height,
    int maxSide = 1080,
    int? bgColorRgb,
  }) {
    return Isolate.run(
      () => _buildPreviewPngSync(
        rgbBytes: rgbBytes,
        alphaFullRes: alphaFullRes,
        width: width,
        height: height,
        maxSide: maxSide,
        bgColorRgb: bgColorRgb,
      ),
    );
  }

  /// Pipeline satu langkah: buat alpha full-res + encode PNG transparan ukuran asli.
  Future<ComposedCutout> composeTransparentPng({
    required Uint8List rgbBytes,
    required int width,
    required int height,
    required Float32List maskProbabilities,
    required int maskSize,
    double feather = 1.5,
    double? hardThreshold,
    int pngCompressionLevel = 3,
  }) {
    return Isolate.run(() {
      final maskRes = _buildFullResAlphaSync(
        maskProbabilities: maskProbabilities,
        maskSize: maskSize,
        width: width,
        height: height,
        feather: feather,
        hardThreshold: hardThreshold,
      );
      final exp = _exportFullResSync(
        rgbBytes: rgbBytes,
        alphaFullRes: maskRes.alphaFullRes,
        width: width,
        height: height,
        format: ExportFormat.png,
        bgColorRgb: null,
        jpegQuality: 92,
        pngCompressionLevel: pngCompressionLevel,
      );
      return ComposedCutout(
        maskSmallU8: maskRes.maskSmallU8,
        maskFullRes: maskRes.maskFullRes,
        alphaFullRes: maskRes.alphaFullRes,
        cutoutPngBytes: exp.bytes,
        width: width,
        height: height,
        postprocessMs: maskRes.postprocessMs,
        encodeMs: exp.encodeMs,
      );
    });
  }

  /// Encode buffer grayscale 1-channel (`w * h`) menjadi PNG (untuk uji paritas P1/P2).
  Future<Uint8List> encodeGrayscalePng(Uint8List gray, int width, int height) {
    return Isolate.run(() {
      final im = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: gray.buffer,
        bytesOffset: gray.offsetInBytes,
        numChannels: 1,
        format: img.Format.uint8,
      );
      return img.encodePng(im, level: 3);
    });
  }

  // ---------------------------------------------------------------- internals

  static const int _kFixedShift = 14;
  static const int _kFixedOne = 1 << _kFixedShift; // 16384
  static const int _kFixedHalf = 1 << (_kFixedShift - 1); // 8192

  static PreparedPhoto _preprocessSync(Uint8List encodedBytes, int inputSize) {
    final sw = Stopwatch()..start();

    // Jalur cepat decode JPEG langsung bila magic bytes cocok (FF D8).
    img.Image? decoded;
    if (encodedBytes.length >= 3 &&
        encodedBytes[0] == 0xFF &&
        encodedBytes[1] == 0xD8 &&
        encodedBytes[2] == 0xFF) {
      decoded = img.decodeJpg(encodedBytes);
    } else {
      decoded = img.decodeImage(encodedBytes);
    }
    if (decoded == null) {
      throw const FormatException('Foto tidak bisa dibaca atau format tidak didukung.');
    }

    // Hindari duplikasi buffer 36 MB di bakeOrientation bila orientasi EXIF normal (1 / tidak ada).
    final hasNonIdentityExif = decoded.exif.imageIfd.hasOrientation &&
        decoded.exif.imageIfd.orientation != null &&
        decoded.exif.imageIfd.orientation != 1;
    final oriented = hasNonIdentityExif ? img.bakeOrientation(decoded) : decoded;

    final w = oriented.width;
    final h = oriented.height;
    final rgb = _extractDenseRgb(oriented);

    // Siapkan juga RGB pratinjau (maks 1080 px, ~2,6 MB) di isolate yang sama.
    const maxPreviewSide = 1080;
    final longest = math.max(w, h);
    final pScale = longest > maxPreviewSide ? maxPreviewSide / longest : 1.0;
    final pw = math.max(1, (w * pScale).round());
    final ph = math.max(1, (h * pScale).round());
    final previewRgb = (pw == w && ph == h)
        ? rgb
        : _resizeRgbNearestFast(rgb, w, h, pw, ph);

    // Resize bilinear anti-aliased (tent/triangle filter seperti PIL.Image.BILINEAR).
    final input = _resizeRgbPillowBilinearToFloat32(rgb, w, h, inputSize, inputSize);
    sw.stop();

    return PreparedPhoto(
      rgbBytes: rgb,
      width: w,
      height: h,
      previewRgbBytes: previewRgb,
      previewWidth: pw,
      previewHeight: ph,
      modelInput: input,
      inputSize: inputSize,
      preprocessMs: sw.elapsedMicroseconds / 1000.0,
    );
  }

  /// Ekstrak byte RGB padat (3 byte/piksel) tanpa overhead `getPixel()` per piksel.
  static Uint8List _extractDenseRgb(img.Image image) {
    final w = image.width;
    final h = image.height;
    final rgbImage = (image.format == img.Format.uint8 && image.numChannels == 3)
        ? image
        : image.convert(format: img.Format.uint8, numChannels: 3);
    final raw = rgbImage.toUint8List();
    final expected = w * h * 3;
    if (raw.length == expected) {
      return raw;
    }
    return Uint8List.fromList(raw.sublist(0, expected));
  }

  static FullResMaskResult _buildFullResAlphaSync({
    required Float32List maskProbabilities,
    required int maskSize,
    required int width,
    required int height,
    required double feather,
    required double? hardThreshold,
    Uint8List? previewRgbBytes,
    int? previewWidth,
    int? previewHeight,
  }) {
    final sw = Stopwatch()..start();

    // Sama persis dengan pichanter_bg.py: quantize ke uint8 (0..255) pada resolusi model, lalu resize bilinear.
    final maskSmall = Uint8List(maskSize * maskSize);
    for (int i = 0; i < maskSmall.length; i++) {
      final v = maskProbabilities[i];
      if (v <= 0.0) {
        maskSmall[i] = 0;
      } else if (v >= 1.0) {
        maskSmall[i] = 255;
      } else {
        maskSmall[i] = (v * 255.0).toInt();
      }
    }

    final maskFull = _resizeGrayPillowBilinear(maskSmall, maskSize, maskSize, width, height);
    final alpha = _refineAlphaSync(
      maskFullRes: maskFull,
      width: width,
      height: height,
      feather: feather,
      hardThreshold: hardThreshold,
    );

    Uint8List? previewPng;
    if (previewRgbBytes != null && previewWidth != null && previewHeight != null) {
      final pAlpha = (previewWidth == width && previewHeight == height)
          ? alpha
          : _resizeGrayNearestFast(alpha, width, height, previewWidth, previewHeight);
      previewPng = _exportFullResSync(
        rgbBytes: previewRgbBytes,
        alphaFullRes: pAlpha,
        width: previewWidth,
        height: previewHeight,
        format: ExportFormat.png,
        bgColorRgb: null,
        jpegQuality: 90,
        pngCompressionLevel: 1,
      ).bytes;
    }
    sw.stop();

    return FullResMaskResult(
      maskSmallU8: maskSmall,
      maskSize: maskSize,
      maskFullRes: maskFull,
      alphaFullRes: alpha,
      width: width,
      height: height,
      postprocessMs: sw.elapsedMicroseconds / 1000.0,
      previewCutoutPng: previewPng,
    );
  }

  static Uint8List _refineAlphaSync({
    required Uint8List maskFullRes,
    required int width,
    required int height,
    required double feather,
    required double? hardThreshold,
  }) {
    Uint8List alpha = maskFullRes;
    if (hardThreshold != null) {
      final thr = (hardThreshold.clamp(0.0, 1.0) * 255.0).round();
      final hard = Uint8List(maskFullRes.length);
      for (int i = 0; i < maskFullRes.length; i++) {
        hard[i] = maskFullRes[i] >= thr ? 255 : 0;
      }
      alpha = hard;
    }
    if (feather > 0.0) {
      alpha = _gaussianBlurGray(alpha, width, height, feather);
    }
    return alpha;
  }

  static ExportedImage _exportFullResSync({
    required Uint8List rgbBytes,
    required Uint8List alphaFullRes,
    required int width,
    required int height,
    required ExportFormat format,
    required int? bgColorRgb,
    required int jpegQuality,
    required int pngCompressionLevel,
  }) {
    if (format == ExportFormat.jpg && bgColorRgb == null) {
      throw ArgumentError('Format JPG tidak mendukung latar transparan; pilih warna latar.');
    }

    final sw = Stopwatch()..start();
    final totalPixels = width * height;
    late final Uint8List outBytes;

    if (bgColorRgb == null) {
      final rgba = Uint8List(totalPixels * 4);
      int src = 0;
      int dst = 0;
      for (int i = 0; i < totalPixels; i++) {
        rgba[dst++] = rgbBytes[src++];
        rgba[dst++] = rgbBytes[src++];
        rgba[dst++] = rgbBytes[src++];
        rgba[dst++] = alphaFullRes[i];
      }
      final im = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      outBytes = img.encodePng(im, level: pngCompressionLevel);
    } else {
      final bgR = (bgColorRgb >> 16) & 0xFF;
      final bgG = (bgColorRgb >> 8) & 0xFF;
      final bgB = bgColorRgb & 0xFF;
      final composed = Uint8List(totalPixels * 3);
      int src = 0;
      int dst = 0;
      for (int i = 0; i < totalPixels; i++) {
        final a = alphaFullRes[i];
        final r = rgbBytes[src++];
        final g = rgbBytes[src++];
        final b = rgbBytes[src++];
        if (a == 255) {
          composed[dst++] = r;
          composed[dst++] = g;
          composed[dst++] = b;
        } else if (a == 0) {
          composed[dst++] = bgR;
          composed[dst++] = bgG;
          composed[dst++] = bgB;
        } else {
          final inv = 255 - a;
          composed[dst++] = (r * a + bgR * inv + 127) ~/ 255;
          composed[dst++] = (g * a + bgG * inv + 127) ~/ 255;
          composed[dst++] = (b * a + bgB * inv + 127) ~/ 255;
        }
      }
      final im = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: composed.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
      outBytes = format == ExportFormat.jpg
          ? img.encodeJpg(im, quality: jpegQuality)
          : img.encodePng(im, level: pngCompressionLevel);
    }
    sw.stop();

    return ExportedImage(
      bytes: outBytes,
      format: format,
      width: width,
      height: height,
      encodeMs: sw.elapsedMicroseconds / 1000.0,
    );
  }

  static Uint8List _buildPreviewPngSync({
    required Uint8List rgbBytes,
    required Uint8List alphaFullRes,
    required int width,
    required int height,
    required int maxSide,
    required int? bgColorRgb,
  }) {
    final longest = math.max(width, height);
    final scale = longest > maxSide ? maxSide / longest : 1.0;
    final pw = math.max(1, (width * scale).round());
    final ph = math.max(1, (height * scale).round());

    Uint8List pRgb = rgbBytes;
    Uint8List pAlpha = alphaFullRes;
    if (pw != width || ph != height) {
      pRgb = _resizeRgbNearestFast(rgbBytes, width, height, pw, ph);
      pAlpha = _resizeGrayNearestFast(alphaFullRes, width, height, pw, ph);
    }
    return _exportFullResSync(
      rgbBytes: pRgb,
      alphaFullRes: pAlpha,
      width: pw,
      height: ph,
      format: ExportFormat.png,
      bgColorRgb: bgColorRgb,
      jpegQuality: 90,
      pngCompressionLevel: 1,
    ).bytes;
  }

  static Uint8List _resizeRgbNearestFast(Uint8List src, int sw, int sh, int dw, int dh) {
    final out = Uint8List(dw * dh * 3);
    final sxMap = Int32List(dw);
    for (int x = 0; x < dw; x++) {
      sxMap[x] = ((x * sw) ~/ dw) * 3;
    }
    int dst = 0;
    for (int y = 0; y < dh; y++) {
      final row = ((y * sh) ~/ dh) * sw * 3;
      for (int x = 0; x < dw; x++) {
        final i = row + sxMap[x];
        out[dst++] = src[i];
        out[dst++] = src[i + 1];
        out[dst++] = src[i + 2];
      }
    }
    return out;
  }

  static Uint8List _resizeGrayNearestFast(Uint8List src, int sw, int sh, int dw, int dh) {
    final out = Uint8List(dw * dh);
    final sxMap = Int32List(dw);
    for (int x = 0; x < dw; x++) {
      sxMap[x] = (x * sw) ~/ dw;
    }
    int dst = 0;
    for (int y = 0; y < dh; y++) {
      final row = ((y * sh) ~/ dh) * sw;
      for (int x = 0; x < dw; x++) {
        out[dst++] = src[row + sxMap[x]];
      }
    }
    return out;
  }

  /// Tabel bobot filter tent/triangle fixed-point (identik `PIL.Image.Resampling.BILINEAR`).
  static _ResampleTable _buildPillowBilinearTable(int srcSize, int dstSize) {
    final scale = srcSize / dstSize;
    final filterScale = scale > 1.0 ? scale : 1.0;
    final support = filterScale;
    final maxK = (support * 2).ceil() + 2;

    final starts = Int32List(dstSize);
    final counts = Int32List(dstSize);
    final weightsFixed = Int32List(dstSize * maxK);

    final tempW = Float64List(maxK);
    for (int i = 0; i < dstSize; i++) {
      final center = (i + 0.5) * scale;
      int xmin = (center - support + 0.5).floor();
      if (xmin < 0) xmin = 0;
      int xmax = (center + support + 0.5).floor();
      if (xmax > srcSize) xmax = srcSize;
      final count = xmax - xmin;

      starts[i] = xmin;
      counts[i] = count;

      double sum = 0.0;
      for (int k = 0; k < count; k++) {
        final u = ((xmin + k + 0.5) - center) / filterScale;
        final w = u < 0 ? 1.0 + u : 1.0 - u;
        final clamped = w > 0.0 ? w : 0.0;
        tempW[k] = clamped;
        sum += clamped;
      }

      final base = i * maxK;
      if (sum > 0.0) {
        final inv = _kFixedOne / sum;
        int fixedSum = 0;
        int maxIdx = 0;
        int maxVal = -1;
        for (int k = 0; k < count; k++) {
          final fw = (tempW[k] * inv).round();
          weightsFixed[base + k] = fw;
          fixedSum += fw;
          if (fw > maxVal) {
            maxVal = fw;
            maxIdx = k;
          }
        }
        // Koreksi pembulatan agar jumlah bobot persis _kFixedOne (16384).
        weightsFixed[base + maxIdx] += (_kFixedOne - fixedSum);
      }
    }
    return _ResampleTable(
      starts: starts,
      counts: counts,
      weightsFixed: weightsFixed,
      stride: maxK,
    );
  }

  /// Resize RGB padat (3 byte/piksel) dengan filter separable fixed-point identik `PIL.Image.BILINEAR`.
  /// Memakai buffer perantara `Uint8List` (hemat 10 MB RAM dibanding `Float32List`).
  static Float32List _resizeRgbPillowBilinearToFloat32(
    Uint8List src,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
  ) {
    if (srcW == dstW && srcH == dstH) {
      final out = Float32List(src.length);
      for (int i = 0; i < src.length; i++) {
        out[i] = src[i].toDouble();
      }
      return out;
    }

    final tx = _buildPillowBilinearTable(srcW, dstW);
    final ty = _buildPillowBilinearTable(srcH, dstH);

    // Pass 1: horizontal (srcW x srcH -> dstW x srcH, disimpan sebagai Uint8List seperti Pillow C)
    final tmp = Uint8List(dstW * srcH * 3);
    final xStarts = tx.starts;
    final xCounts = tx.counts;
    final xWeights = tx.weightsFixed;
    final xStride = tx.stride;

    for (int y = 0; y < srcH; y++) {
      final srcRow = y * srcW * 3;
      final dstRow = y * dstW * 3;
      for (int x = 0; x < dstW; x++) {
        final start = xStarts[x];
        final count = xCounts[x];
        final wBase = x * xStride;
        int r = _kFixedHalf;
        int g = _kFixedHalf;
        int b = _kFixedHalf;
        int sIdx = srcRow + start * 3;
        for (int k = 0; k < count; k++) {
          final w = xWeights[wBase + k];
          r += src[sIdx] * w;
          g += src[sIdx + 1] * w;
          b += src[sIdx + 2] * w;
          sIdx += 3;
        }
        int rv = r >> _kFixedShift;
        int gv = g >> _kFixedShift;
        int bv = b >> _kFixedShift;
        if (rv < 0) rv = 0;
        if (rv > 255) rv = 255;
        if (gv < 0) gv = 0;
        if (gv > 255) gv = 255;
        if (bv < 0) bv = 0;
        if (bv > 255) bv = 255;
        final dIdx = dstRow + x * 3;
        tmp[dIdx] = rv;
        tmp[dIdx + 1] = gv;
        tmp[dIdx + 2] = bv;
      }
    }

    // Pass 2: vertikal (dstW x srcH -> dstW x dstH)
    final out = Float32List(dstW * dstH * 3);
    final yStarts = ty.starts;
    final yCounts = ty.counts;
    final yWeights = ty.weightsFixed;
    final yStride = ty.stride;
    final rowElems = dstW * 3;
    final accRow = Int32List(rowElems);

    for (int y = 0; y < dstH; y++) {
      final start = yStarts[y];
      final count = yCounts[y];
      final wBase = y * yStride;
      final outRow = y * rowElems;

      accRow.fillRange(0, rowElems, _kFixedHalf);
      for (int k = 0; k < count; k++) {
        final w = yWeights[wBase + k];
        final tmpRow = (start + k) * rowElems;
        for (int i = 0; i < rowElems; i++) {
          accRow[i] += tmp[tmpRow + i] * w;
        }
      }
      for (int i = 0; i < rowElems; i++) {
        int v = accRow[i] >> _kFixedShift;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out[outRow + i] = v.toDouble();
      }
    }
    return out;
  }

  /// Resize grayscale (1 byte/piksel) separable fixed-point identik `PIL.Image.BILINEAR`.
  static Uint8List _resizeGrayPillowBilinear(
    Uint8List src,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
  ) {
    if (srcW == dstW && srcH == dstH) return Uint8List.fromList(src);

    final tx = _buildPillowBilinearTable(srcW, dstW);
    final ty = _buildPillowBilinearTable(srcH, dstH);

    // Pass 1: horizontal (srcW x srcH -> dstW x srcH)
    final tmp = Uint8List(dstW * srcH);
    final xStarts = tx.starts;
    final xCounts = tx.counts;
    final xWeights = tx.weightsFixed;
    final xStride = tx.stride;

    for (int y = 0; y < srcH; y++) {
      final srcRow = y * srcW;
      final dstRow = y * dstW;
      for (int x = 0; x < dstW; x++) {
        final start = xStarts[x];
        final count = xCounts[x];
        final wBase = x * xStride;
        if (count == 2) {
          final s0 = srcRow + start;
          int v = (src[s0] * xWeights[wBase] + src[s0 + 1] * xWeights[wBase + 1] + _kFixedHalf) >>
              _kFixedShift;
          if (v > 255) v = 255;
          tmp[dstRow + x] = v;
        } else if (count == 1) {
          tmp[dstRow + x] = src[srcRow + start];
        } else {
          int acc = _kFixedHalf;
          for (int k = 0; k < count; k++) {
            acc += src[srcRow + start + k] * xWeights[wBase + k];
          }
          int v = acc >> _kFixedShift;
          if (v < 0) v = 0;
          if (v > 255) v = 255;
          tmp[dstRow + x] = v;
        }
      }
    }

    // Pass 2: vertikal (dstW x srcH -> dstW x dstH)
    final out = Uint8List(dstW * dstH);
    final yStarts = ty.starts;
    final yCounts = ty.counts;
    final yWeights = ty.weightsFixed;
    final yStride = ty.stride;

    for (int y = 0; y < dstH; y++) {
      final start = yStarts[y];
      final count = yCounts[y];
      final wBase = y * yStride;
      final outRow = y * dstW;

      if (count == 2) {
        final w0 = yWeights[wBase];
        final w1 = yWeights[wBase + 1];
        final r0 = start * dstW;
        final r1 = (start + 1) * dstW;
        for (int x = 0; x < dstW; x++) {
          int v = (tmp[r0 + x] * w0 + tmp[r1 + x] * w1 + _kFixedHalf) >> _kFixedShift;
          if (v > 255) v = 255;
          out[outRow + x] = v;
        }
      } else if (count == 1) {
        final r0 = start * dstW;
        out.setRange(outRow, outRow + dstW, tmp, r0);
      } else {
        for (int x = 0; x < dstW; x++) {
          int acc = _kFixedHalf;
          for (int k = 0; k < count; k++) {
            acc += tmp[(start + k) * dstW + x] * yWeights[wBase + k];
          }
          int v = acc >> _kFixedShift;
          if (v < 0) v = 0;
          if (v > 255) v = 255;
          out[outRow + x] = v;
        }
      }
    }
    return out;
  }

  /// Separable Gaussian blur 1-channel fixed-point cepat dengan buffer perantara `Uint8List`
  /// (hemat 36,5 MB RAM dibanding `Float32List` pada foto 12 MP).
  static Uint8List _gaussianBlurGray(Uint8List src, int w, int h, double sigma) {
    if (sigma <= 0.0) return src;
    final radius = (sigma * 3.0).ceil();
    if (radius <= 0) return src;

    // Kernel simetris fixed-point: k[0] = tengah, k[1..radius] = offset kanan/kiri.
    final kHalf = Int32List(radius + 1);
    final kFloat = Float64List(radius + 1);
    final denom = 2.0 * sigma * sigma;
    double sum = 1.0;
    kFloat[0] = 1.0;
    for (int i = 1; i <= radius; i++) {
      final v = math.exp(-(i * i) / denom);
      kFloat[i] = v;
      sum += 2.0 * v;
    }
    int fixedSum = 0;
    for (int i = 1; i <= radius; i++) {
      final fw = ((kFloat[i] / sum) * _kFixedOne).round();
      kHalf[i] = fw;
      fixedSum += 2 * fw;
    }
    kHalf[0] = _kFixedOne - fixedSum;
    final k0 = kHalf[0];

    // Pass 1: horizontal -> Uint8List(w * h)
    final temp = Uint8List(w * h);
    final maxX = w - 1;
    final innerStart = radius < w ? radius : w;
    final innerEnd = w - radius > innerStart ? w - radius : innerStart;

    for (int y = 0; y < h; y++) {
      final row = y * w;
      for (int x = 0; x < innerStart; x++) {
        int acc = src[row + x] * k0 + _kFixedHalf;
        for (int d = 1; d <= radius; d++) {
          final lx = x - d < 0 ? 0 : x - d;
          final rx = x + d > maxX ? maxX : x + d;
          acc += (src[row + lx] + src[row + rx]) * kHalf[d];
        }
        int v = acc >> _kFixedShift;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        temp[row + x] = v;
      }
      for (int x = innerStart; x < innerEnd; x++) {
        final c = row + x;
        int acc = src[c] * k0 + _kFixedHalf;
        for (int d = 1; d <= radius; d++) {
          acc += (src[c - d] + src[c + d]) * kHalf[d];
        }
        temp[c] = acc >> _kFixedShift;
      }
      for (int x = innerEnd; x < w; x++) {
        int acc = src[row + x] * k0 + _kFixedHalf;
        for (int d = 1; d <= radius; d++) {
          final lx = x - d < 0 ? 0 : x - d;
          final rx = x + d > maxX ? maxX : x + d;
          acc += (src[row + lx] + src[row + rx]) * kHalf[d];
        }
        int v = acc >> _kFixedShift;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        temp[row + x] = v;
      }
    }

    // Pass 2: vertikal -> Uint8List(w * h)
    final out = Uint8List(w * h);
    final maxY = h - 1;
    final yInnerStart = radius < h ? radius : h;
    final yInnerEnd = h - radius > yInnerStart ? h - radius : yInnerStart;

    for (int y = 0; y < h; y++) {
      final outRow = y * w;
      if (y >= yInnerStart && y < yInnerEnd) {
        for (int x = 0; x < w; x++) {
          final c = outRow + x;
          int acc = temp[c] * k0 + _kFixedHalf;
          for (int d = 1; d <= radius; d++) {
            final off = d * w;
            acc += (temp[c - off] + temp[c + off]) * kHalf[d];
          }
          out[c] = acc >> _kFixedShift;
        }
      } else {
        for (int x = 0; x < w; x++) {
          int acc = temp[outRow + x] * k0 + _kFixedHalf;
          for (int d = 1; d <= radius; d++) {
            final uy = y - d < 0 ? 0 : y - d;
            final dy = y + d > maxY ? maxY : y + d;
            acc += (temp[uy * w + x] + temp[dy * w + x]) * kHalf[d];
          }
          int v = acc >> _kFixedShift;
          if (v < 0) v = 0;
          if (v > 255) v = 255;
          out[outRow + x] = v;
        }
      }
    }
    return out;
  }
}

class _ResampleTable {
  const _ResampleTable({
    required this.starts,
    required this.counts,
    required this.weightsFixed,
    required this.stride,
  });

  final Int32List starts;
  final Int32List counts;
  final Int32List weightsFixed;
  final int stride;
}

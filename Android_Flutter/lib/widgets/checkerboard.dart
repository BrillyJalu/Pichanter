import 'package:material_ui/material_ui.dart';

/// Latar kotak-kotak untuk menampilkan transparansi PNG (PRD F3).
class CheckerboardBackground extends StatelessWidget {
  const CheckerboardBackground({
    super.key,
    required this.child,
    this.tileSize = 14.0,
  });

  final Widget child;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _CheckerboardPainter(
        tileSize: tileSize,
        colorA: dark ? const Color(0xFF2B2840) : const Color(0xFFE8E6F1),
        colorB: dark ? const Color(0xFF36324D) : const Color(0xFFFFFFFF),
      ),
      child: child,
    );
  }
}

class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter({
    required this.tileSize,
    required this.colorA,
    required this.colorB,
  });

  final double tileSize;
  final Color colorA;
  final Color colorB;

  @override
  void paint(Canvas canvas, Size size) {
    final pA = Paint()..color = colorA;
    final pB = Paint()..color = colorB;
    canvas.drawRect(Offset.zero & size, pB);
    for (double y = 0; y < size.height; y += tileSize) {
      final row = (y ~/ tileSize);
      for (double x = (row.isEven ? 0 : tileSize); x < size.width; x += tileSize * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, tileSize, tileSize), pA);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardPainter oldDelegate) =>
      oldDelegate.tileSize != tileSize ||
      oldDelegate.colorA != colorA ||
      oldDelegate.colorB != colorB;
}

/// Dialog pemilih warna bebas (HSV slider + preset + kode hex) tanpa paket pihak ketiga.
Future<int?> showCustomColorDialog(BuildContext context, int initialRgb) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => _CustomColorDialog(initialRgb: initialRgb),
  );
}

class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initialRgb});
  final int initialRgb;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;

  static const List<int> _quickColors = [
    0xD0021B, // Merah pas foto
    0x0A4DA2, // Biru pas foto
    0xFFFFFF, // Putih
    0x111111, // Hitam
    0x2E7D32, // Hijau
    0xF59E0B, // Kuning emas
    0x7C3AED, // Ungu
    0xEC4899, // Merah muda
    0x0EA5E9, // Biru langit
    0xE5E7EB, // Abu terang
  ];

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(0xFF000000 | (widget.initialRgb & 0xFFFFFF)));
    _hexCtrl = TextEditingController(text: _toHex(_currentRgb));
  }

  int get _currentRgb => _hsv.toColor().toARGB32() & 0xFFFFFF;

  String _toHex(int rgb) => rgb.toRadixString(16).padLeft(6, '0').toUpperCase();

  void _updateHsv(HSVColor next) {
    setState(() {
      _hsv = next;
      _hexCtrl.text = _toHex(_currentRgb);
    });
  }

  void _onHexChanged(String raw) {
    final cleaned = raw.trim().replaceFirst('#', '');
    if (cleaned.length == 6) {
      final parsed = int.tryParse(cleaned, radix: 16);
      if (parsed != null) {
        setState(() {
          _hsv = HSVColor.fromColor(Color(0xFF000000 | parsed));
        });
      }
    }
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('Pilih Warna Latar'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              alignment: Alignment.center,
              child: Text(
                '#${_toHex(_currentRgb)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _quickColors)
                  InkWell(
                    onTap: () => _updateHsv(HSVColor.fromColor(Color(0xFF000000 | c))),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(0xFF000000 | c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _currentRgb == c
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                          width: _currentRgb == c ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _SliderLabel('Warna (Hue)', _hsv.hue / 360, (v) => _updateHsv(_hsv.withHue(v * 360))),
            _SliderLabel('Kepekatan', _hsv.saturation, (v) => _updateHsv(_hsv.withSaturation(v))),
            _SliderLabel('Kecerahan', _hsv.value, (v) => _updateHsv(_hsv.withValue(v))),
            const SizedBox(height: 8),
            TextField(
              controller: _hexCtrl,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Kode Hex (6 digit)',
                prefixText: '#',
                counterText: '',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _onHexChanged,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_currentRgb),
          child: const Text('Pakai Warna'),
        ),
      ],
    );
  }
}

class _SliderLabel extends StatelessWidget {
  const _SliderLabel(this.label, this.value, this.onChanged);
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label, style: const TextStyle(fontSize: 12.5))),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

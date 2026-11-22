import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'screens/beranda_screen.dart';
import 'services/benchmark_service.dart';
import 'services/image_service.dart';
import 'services/model_service.dart';
import 'services/parity_service.dart';
import 'services/share_service.dart';
import 'services/storage_service.dart';
import 'state/editor_controller.dart';
import 'state/history_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PichanterApp());
}

class PichanterApp extends StatefulWidget {
  const PichanterApp({super.key});

  @override
  State<PichanterApp> createState() => _PichanterAppState();
}

class _PichanterAppState extends State<PichanterApp> {
  final ModelService _modelService = ModelService();
  final ImageService _imageService = const ImageService();
  final StorageService _storageService = StorageService();
  final ShareService _shareService = const ShareService();
  late final ParityService _parityService = ParityService(
    modelService: _modelService,
    imageService: _imageService,
  );
  late final BenchmarkService _benchmarkService = BenchmarkService(
    modelService: _modelService,
    imageService: _imageService,
  );
  late final HistoryController _historyController = HistoryController(
    storageService: _storageService,
  );
  late final EditorController _editorController = EditorController(
    modelService: _modelService,
    imageService: _imageService,
    storageService: _storageService,
    shareService: _shareService,
    historyController: _historyController,
  );

  @override
  void dispose() {
    _editorController.dispose();
    _historyController.dispose();
    _modelService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B3FE6);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<HistoryController>.value(value: _historyController),
        ChangeNotifierProvider<EditorController>.value(value: _editorController),
      ],
      child: MaterialApp(
        title: 'Pichanter',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xFFF6F5FB),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF110F1B),
          useMaterial3: true,
        ),
        home: BerandaScreen(
          parityService: _parityService,
          benchmarkService: _benchmarkService,
        ),
      ),
    );
  }
}

import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// Controller daftar riwayat lokal (PRD F7).
class HistoryController extends ChangeNotifier {
  HistoryController({required this.storageService});

  final StorageService storageService;

  List<HistoryEntry> _items = const [];
  bool _loading = false;

  List<HistoryEntry> get items => _items;
  bool get loading => _loading;
  int get count => _items.length;

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      _items = await storageService.listHistory();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void prepend(HistoryEntry entry) {
    _items = [entry, ..._items.where((e) => e.id != entry.id)];
    notifyListeners();
  }

  Future<void> deleteItem(HistoryEntry entry) async {
    await storageService.deleteHistoryItem(entry);
    _items = _items.where((e) => e.id != entry.id).toList();
    notifyListeners();
  }

  Future<void> clearAll() async {
    await storageService.clearAllHistory();
    _items = const [];
    notifyListeners();
  }
}

import 'package:flutter/services.dart';

class DuckClipboardService {
  Future<String?> readText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

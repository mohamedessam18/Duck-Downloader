import 'package:hive/hive.dart';

class LicenseStore {
  LicenseStore(this._box);

  final Box _box;

  bool get isActive => _box.get('licenseActive', defaultValue: false) as bool;

  String? get licenseKey {
    final value = _box.get('licenseKey') as String?;
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<void> save({required String licenseKey, required bool active}) async {
    await _box.put('licenseKey', licenseKey.trim());
    await _box.put('licenseActive', active);
  }

  Future<void> clear() async {
    await _box.delete('licenseKey');
    await _box.put('licenseActive', false);
  }
}

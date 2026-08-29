import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

/// The status line, kept as a translation key until something displays it.
///
/// It used to be a plain `String` assigned in 93 places, every one of them
/// English written straight into the field. The app is translated, so an
/// Arabic user read an Arabic interface with `Download complete` and
/// `Tap the duck` sitting in the middle of it.
///
/// A key cannot be resolved where it is set — the controller has no
/// `BuildContext` and no business having one — so it travels as a key and is
/// resolved by the widget that shows it. That also means a language change
/// re-renders the message that is already on screen, instead of leaving the
/// last one stranded in the previous language.
class DuckStatus {
  const DuckStatus.key(String key, {Map<String, String> args = const {}})
    : _key = key,
      _args = args,
      _literal = null;

  /// Text that is already final and cannot be translated here.
  ///
  /// Backend errors, mostly: the server sends one sentence in English and the
  /// alternative is showing the user nothing at all.
  const DuckStatus.literal(String text)
    : _literal = text,
      _key = null,
      _args = const {};

  final String? _key;
  final String? _literal;
  final Map<String, String> _args;

  String resolve(AppLocalizations l10n) {
    final literal = _literal;
    if (literal != null) return literal;
    var text = l10n.translate(_key!);
    _args.forEach((name, value) {
      text = text.replaceAll('{$name}', value);
    });
    return text;
  }

  /// Whether this is a specific key, for code that needs to react to one
  /// particular message without matching on its text.
  bool isKey(String key) => _key == key;

  /// The English form, for code that has no localizations to hand.
  ///
  /// Tests read this, and so does the one place that still has to recognise a
  /// specific message.
  String get english => resolve(AppLocalizations(const Locale('en')));

  @override
  String toString() => english;
}

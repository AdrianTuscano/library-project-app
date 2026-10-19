import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TextSizeOption {
  small(0.88, 'Small'),
  normal(1.0, 'Normal'),
  large(1.15, 'Large'),
  largest(1.3, 'Largest');

  final double factor;
  final String label;
  const TextSizeOption(this.factor, this.label);
}

enum ReadingFont {
  // Lexend: widened letterforms shown to improve reading speed for struggling readers.
  easy('Lexend', 'Lexend', 'Literata'),
  // Atkinson Hyperlegible: Braille Institute font that keeps similar letters distinct.
  clear('Atkinson Hyperlegible', 'Atkinson Hyperlegible', 'Literata'),
  // The app's original look.
  classic('Lora', 'Lora', 'Cormorant Garamond');

  final String label;
  final String bodyFamily;
  final String headingFamily;
  const ReadingFont(this.label, this.bodyFamily, this.headingFamily);
}

/// A library whose catalog ShelfScan can check — all on Biblionix's Apollo
/// platform, reachable at z3950.biblionix.com:210/<database>, no credentials.
/// Confirmed live (see tool/probe_z3950.dart): same protocol, same
/// real-time-status trick (element set "C"), different database name per
/// library — adding one here is the whole integration.
enum CatalogLibrary {
  georgetown('georgetown', 'Georgetown Public Library'),
  libertyHill('libertyhill', 'Liberty Hill Public Library'),
  taylor('taylor', 'Taylor Public Library'),
  hutto('hutto', 'Hutto Public Library'),
  pflugerville('pflugerville', 'Pflugerville Public Library'),
  wellsBranch('wellsbranch', 'Wells Branch Community Library');

  /// The Z39.50 database name — e.g. z3950.biblionix.com:210/georgetown.
  final String database;
  final String label;
  const CatalogLibrary(this.database, this.label);
}

class AppSettings extends ChangeNotifier {
  SharedPreferences? _prefs;

  TextSizeOption textSize = TextSizeOption.normal;
  ReadingFont font = ReadingFont.easy;
  CatalogLibrary library = CatalogLibrary.georgetown;
  bool useFlash = true;
  bool showTips = true;
  bool haptics = true;
  /// Whether shelf photos may be sent to Claude (App Store 5.1.2(i)).
  /// Defaults on; the one-time disclosure sheet (gated by
  /// [aiDisclosureShown], not this) is what makes that compliant — it
  /// still runs before the very first photo ever goes out, and can turn
  /// this off right there. Neither is touched by [reset].
  bool aiConsent = true;
  bool aiDisclosureShown = false;

  Future<void> load() async {
    try {
      final p = _prefs = await SharedPreferences.getInstance();
      textSize = TextSizeOption.values.asNameMap()[p.getString('textSize')] ?? textSize;
      font = ReadingFont.values.asNameMap()[p.getString('font')] ?? font;
      library = CatalogLibrary.values.asNameMap()[p.getString('library')] ?? library;
      useFlash = p.getBool('useFlash') ?? useFlash;
      showTips = p.getBool('showTips') ?? showTips;
      haptics = p.getBool('haptics') ?? haptics;
      aiConsent = p.getBool('aiConsent') ?? aiConsent;
      aiDisclosureShown = p.getBool('aiDisclosureShown') ?? aiDisclosureShown;
    } catch (e) {
      debugPrint('[Settings] load failed, using defaults: $e');
    }
  }

  void update({
    TextSizeOption? textSize,
    ReadingFont? font,
    CatalogLibrary? library,
    bool? useFlash,
    bool? showTips,
    bool? haptics,
    bool? aiConsent,
    bool? aiDisclosureShown,
  }) {
    this.textSize = textSize ?? this.textSize;
    this.font = font ?? this.font;
    this.library = library ?? this.library;
    this.useFlash = useFlash ?? this.useFlash;
    this.showTips = showTips ?? this.showTips;
    this.haptics = haptics ?? this.haptics;
    this.aiConsent = aiConsent ?? this.aiConsent;
    this.aiDisclosureShown = aiDisclosureShown ?? this.aiDisclosureShown;
    _save();
    notifyListeners();
  }

  void reset() {
    textSize = TextSizeOption.normal;
    font = ReadingFont.easy;
    library = CatalogLibrary.georgetown;
    useFlash = true;
    showTips = true;
    haptics = true;
    _save();
    notifyListeners();
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setString('textSize', textSize.name);
    p.setString('font', font.name);
    p.setString('library', library.name);
    p.setBool('useFlash', useFlash);
    p.setBool('showTips', showTips);
    p.setBool('haptics', haptics);
    p.setBool('aiConsent', aiConsent);
    p.setBool('aiDisclosureShown', aiDisclosureShown);
  }
}

final appSettings = AppSettings();

void tapFeedback({bool strong = false}) {
  if (!appSettings.haptics) return;
  strong ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick();
}

/// Drops taps that land within [gap] of the last accepted one, so mashing a
/// button can't fire the same action or navigation twice.
class TapCooldown {
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static bool allow([Duration gap = const Duration(milliseconds: 450)]) {
    final now = DateTime.now();
    if (now.difference(_last) < gap) return false;
    _last = now;
    return true;
  }
}

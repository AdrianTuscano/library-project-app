import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'settings.dart';

const kBgDark    = Color(0xFF100F0E);
const kBgDarkRaised = Color(0xFF1C1B19);
const kBgScreen  = Color(0xFFF3F2F2);
const kBgPanel   = Color(0xFFEAE9E9);
const kDivider   = Color(0x2E201F1D);
const kText      = Color(0xFF201F1D);
// Muted text colors are kept at ≥ 4.5:1 contrast on kBgScreen/kBgPanel.
const kTextMut   = Color(0xFF4A4745);
const kTextFaint = Color(0xFF5E5A57);
const kGold      = Color(0xFFB68235);
const kGoldText  = Color(0xFF7D5411);
const kGoldLight = Color(0xFFE2C08A);
const kRust      = Color(0xFF8C3A2B);
const kGreen     = Color(0xFF3F6E4D);

// Text on dark backgrounds.
const kOnDark      = Color(0xFFEFE9E0);
const kOnDarkMut   = Color(0xFFC4BBAE);

/// Apple HIG minimum hit target is 44×44 pt; we use 48 for primary controls.
const double kMinTap = 48;

const List<Color> kSpines = [
  Color(0xFF5C5348), Color(0xFF7D5411), Color(0xFF3F4A52), Color(0xFF8C3A2B),
  Color(0xFF2D2B2B), Color(0xFF6B6350), Color(0xFF9B7232), Color(0xFF4A4740),
  Color(0xFF7A6A55), Color(0xFF605D5D),
];

Color spineColor(int position) => kSpines[(position - 1) % kSpines.length];

TextStyle kHeading(double size, {Color color = kText}) => GoogleFonts.getFont(
      appSettings.font.headingFamily,
      fontSize: size,
      fontWeight: FontWeight.w600,
      color: color,
      height: 1.15,
    );

TextStyle kBody(double size,
        {Color color = kText, FontStyle style = FontStyle.normal, FontWeight weight = FontWeight.w400}) =>
    GoogleFonts.getFont(
      appSettings.font.bodyFamily,
      fontSize: size,
      color: color,
      height: 1.45,
      fontStyle: style,
      fontWeight: weight,
    );

TextStyle kLabel(double size,
        {Color color = kTextFaint,
        double tracking = 0,
        FontStyle style = FontStyle.normal,
        FontWeight weight = FontWeight.w500}) =>
    GoogleFonts.getFont(
      appSettings.font.bodyFamily,
      fontSize: size,
      color: color,
      letterSpacing: tracking,
      fontStyle: style,
      fontWeight: weight,
      height: 1.3,
    );

/// Call numbers mix look-alike characters (0/O, 1/l/I), so they always use the
/// Braille Institute's Atkinson Hyperlegible regardless of the reading font.
TextStyle kCallNumber(double size, {Color color = kText}) => GoogleFonts.getFont(
      'Atkinson Hyperlegible',
      fontSize: size,
      color: color,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
    );

int spineWidth(String title) {
  final hash = title.codeUnits.fold(0, (a, c) => a ^ c);
  return 32 + (hash.abs() % 20);
}

int spineHeight(String title, String author) {
  final hash = (author + title).codeUnits.fold(0, (a, c) => a ^ c);
  return 130 + (hash.abs() % 70);
}

bool isLandscape(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width > size.height;
}

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Palette ──────────────────────────────────────────────────────────────────

const kBgDark   = Color(0xFF100F0E);
const kBgScreen = Color(0xFFF3F2F2);
const kBgPanel  = Color(0xFFEAE9E9);
const kDivider  = Color(0x23201F1D);
const kText     = Color(0xFF201F1D);
const kTextMut  = Color(0xFF605D5D);
const kTextFaint = Color(0xFF7D7979);
const kGold     = Color(0xFFB68235);
const kGoldText = Color(0xFF7D5411);
const kRust     = Color(0xFF8C3A2B);

// ── Spine palette (earth tones; cycle by position) ───────────────────────────

const List<Color> kSpines = [
  Color(0xFF5C5348), Color(0xFF7D5411), Color(0xFF3F4A52), Color(0xFF8C3A2B),
  Color(0xFF2D2B2B), Color(0xFF6B6350), Color(0xFF9B7232), Color(0xFF4A4740),
  Color(0xFF7A6A55), Color(0xFF605D5D),
];

Color spineColor(int position) => kSpines[(position - 1) % kSpines.length];

// ── Typography ────────────────────────────────────────────────────────────────

TextStyle kHeading(double size, {Color color = kText}) =>
    GoogleFonts.cormorantGaramond(
      fontSize: size, fontWeight: FontWeight.w600, color: color, height: 1.08,
    );

TextStyle kBody(double size, {Color color = kText, FontStyle style = FontStyle.normal}) =>
    GoogleFonts.lora(fontSize: size, color: color, height: 1.4, fontStyle: style);

TextStyle kLabel(double size, {Color color = kTextFaint, double tracking = 0}) =>
    GoogleFonts.lora(fontSize: size, color: color, letterSpacing: tracking);

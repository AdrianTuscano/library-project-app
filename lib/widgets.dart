import 'package:flutter/material.dart';
import 'design.dart';
import 'library_status_service.dart';
import 'settings.dart';

enum AppButtonKind { primary, secondary }

/// Icon + word button. Every action pairs a picture with a plain label so it
/// can be recognised without reading, and is at least [kMinTap] tall.
class AppButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final AppButtonKind kind;
  final bool onDark;
  final bool expand;

  const AppButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.kind = AppButtonKind.primary,
    this.onDark = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final primary = kind == AppButtonKind.primary;
    var (bg, fg, border) = switch ((primary, onDark)) {
      (true, false) => (kGoldText, Colors.white, kGoldText),
      (true, true) => (kGold, kOnGold, kGold),
      (false, false) => (Colors.transparent, kGoldText, kGoldText),
      (false, true) => (Colors.transparent, kGoldLight, kGold),
    };
    final disabled = onPressed == null;
    if (disabled) {
      bg = bg.withValues(alpha: bg.a * 0.4);
      fg = fg.withValues(alpha: 0.4);
      border = border.withValues(alpha: 0.4);
    }

    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 24, color: fg),
        const SizedBox(width: 10),
        Flexible(
          child: Text(label,
              textAlign: TextAlign.center,
              style: kLabel(17, color: fg, weight: FontWeight.w600)),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed == null
              ? null
              : () {
                  if (!TapCooldown.allow()) return;
                  tapFeedback();
                  onPressed!();
                },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Screen header: a labelled Back button, a title, optional subtitle and
/// trailing actions. Grows with the text size instead of clipping.
class AppTopBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final String backLabel;
  final List<Widget> trailing;
  final bool onDark;

  const AppTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.backLabel = 'Back',
    this.trailing = const [],
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = onDark ? kOnDark : kText;
    final mut = onDark ? kOnDarkMut : kTextMut;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      decoration: BoxDecoration(
        color: onDark ? kBgDarkRaised : kBgScreen,
        border: Border(bottom: BorderSide(color: onDark ? const Color(0xFF2A2927) : kDivider)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            _BackButton(label: backLabel, onTap: onBack!, onDark: onDark),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: kHeading(22, color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(subtitle!,
                      style: kLabel(15, color: mut),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool onDark;
  const _BackButton({required this.label, required this.onTap, required this.onDark});

  @override
  Widget build(BuildContext context) {
    final color = onDark ? kGoldLight : kGoldText;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          if (!TapCooldown.allow()) return;
          tapFeedback();
          onTap();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTap, minWidth: kMinTap),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_rounded, color: color, size: 26),
                const SizedBox(width: 4),
                Text(label, style: kLabel(17, color: color, weight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain-language description of a catalog status: an icon, a short word and
/// a sentence, so meaning never depends on color alone.
class StatusLook {
  final IconData icon;
  final String word;
  final String sentence;
  final Color color;
  const StatusLook(this.icon, this.word, this.sentence, this.color);
}

StatusLook statusLook(LibraryStatus? s) {
  if (s == null) {
    return const StatusLook(Icons.hourglass_top_rounded, 'Checking…',
        'Looking this book up at the library.', kTextMut);
  }
  return switch (s.status) {
    CircStatus.available => const StatusLook(Icons.check_circle_rounded, 'Available',
        'The library says this book is on the shelf.', kGreen),
    CircStatus.checkedOut => const StatusLook(Icons.schedule_rounded, 'Checked out',
        'The library says someone has borrowed this book.', kRust),
    CircStatus.unknown => const StatusLook(Icons.help_rounded, 'Not found',
        'We could not find this book at the library.', kTextMut),
  };
}

class StatusCard extends StatelessWidget {
  final LibraryStatus? status;
  final bool onDark;
  const StatusCard({super.key, required this.status, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final look = statusLook(status);
    final accent = onDark && look.color == kTextMut ? kOnDarkMut : look.color;
    final wordColor = onDark ? _lighten(accent) : accent;
    return Semantics(
      label: 'Library status: ${look.word}. ${look.sentence}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: onDark ? 0.16 : 0.09),
          border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            status == null
                ? Padding(
                    padding: const EdgeInsets.all(4),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: wordColor),
                    ),
                  )
                : Icon(look.icon, color: wordColor, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(look.word, style: kLabel(20, color: wordColor, weight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(look.sentence,
                      style: kBody(16, color: onDark ? kOnDarkMut : kTextMut)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _lighten(Color c) => Color.lerp(c, Colors.white, 0.45)!;
}

/// Shown when a book is physically on the shelf but the catalog says it's out.
class ReshelveCard extends StatelessWidget {
  final bool onDark;
  const ReshelveCard({super.key, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final color = onDark ? const Color(0xFFE59A8A) : kRust;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kRust.withValues(alpha: onDark ? 0.2 : 0.08),
        border: Border.all(color: kRust, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This book may be in the wrong place',
                    style: kLabel(18, color: color, weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'The library thinks it is checked out, but it is here on the shelf. '
                  'Put it on your cart and take it to circulation.',
                  style: kBody(16, color: onDark ? kOnDark : kText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small round status marker for book spines.
class StatusDot extends StatelessWidget {
  final LibraryStatus? status;
  const StatusDot({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final look = statusLook(status);
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: status == null ? const Color(0xFF8D857A) : look.color,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Icon(
        status == null ? Icons.more_horiz_rounded : look.icon,
        size: 15,
        color: Colors.white,
      ),
    );
  }
}

/// Key for the spine markers, so the colors and symbols are explained in words.
class StatusLegend extends StatelessWidget {
  const StatusLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(CircStatus s) {
      final look = statusLook(LibraryStatus(status: s));
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(status: LibraryStatus(status: s)),
          const SizedBox(width: 6),
          Text(look.word, style: kLabel(15, color: kTextMut)),
        ],
      );
    }

    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        item(CircStatus.available),
        item(CircStatus.checkedOut),
        item(CircStatus.unknown),
      ],
    );
  }
}

/// Labelled read-only field: small label above a larger value.
class InfoField extends StatelessWidget {
  final String label;
  final String value;
  final bool onDark;
  final bool callNumber;
  const InfoField({
    super.key,
    required this.label,
    required this.value,
    this.onDark = false,
    this.callNumber = false,
  });

  @override
  Widget build(BuildContext context) {
    final valueColor = onDark ? kOnDark : kText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: kLabel(15, color: onDark ? kOnDarkMut : kTextFaint)),
        const SizedBox(height: 2),
        Text(value,
            style: callNumber
                ? kCallNumber(19, color: valueColor)
                : kBody(18, color: valueColor)),
      ],
    );
  }
}

/// Asks before shelf photos are sent to Claude (App Store guideline 5.1.2(i):
/// name the AI provider, say what is sent and why, get explicit permission).
/// Returns null if dismissed without choosing.
Future<bool?> showAiConsentSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kBgScreen,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Use AI to read the book spines?', style: kHeading(26)),
                const SizedBox(height: 12),
                Text(
                  'The boxed part of the photo may be sent to Anthropic or Google '
                  'to read the titles. It\'s not kept.',
                  style: kBody(17),
                ),
                const SizedBox(height: 10),
                Text(
                  'Say no and your phone reads it instead — less accurate, '
                  'nothing leaves it. Change this anytime in Settings.',
                  style: kBody(16, color: kTextMut),
                ),
                const SizedBox(height: 22),
                AppButton(
                  label: 'Allow',
                  icon: Icons.check_rounded,
                  expand: true,
                  onPressed: () => Navigator.pop(context, true),
                ),
                const SizedBox(height: 10),
                AppButton(
                  label: "Don't allow",
                  icon: Icons.close_rounded,
                  kind: AppButtonKind.secondary,
                  expand: true,
                  onPressed: () => Navigator.pop(context, false),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

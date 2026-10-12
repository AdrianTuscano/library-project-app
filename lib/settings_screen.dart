import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'design.dart';
import 'ocr_config.dart';
import 'settings.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Scaffold(
        backgroundColor: kBgScreen,
        body: SafeArea(
          child: Column(
            children: [
              AppTopBar(title: 'Settings', onBack: () => Navigator.pop(context)),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      // Fonts are baked into styles at build time, so a font
                      // change remounts the list to restyle the const titles.
                      key: ValueKey(appSettings.font),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      // Values are passed down so each section rebuilds when
                      // they change (const sections would be skipped).
                      children: [
                        const _SectionTitle('Text size'),
                        _TextSizePicker(selected: appSettings.textSize),
                        const SizedBox(height: 28),
                        const _SectionTitle('Font'),
                        _FontPicker(selected: appSettings.font),
                        const SizedBox(height: 28),
                        const _SectionTitle('Library'),
                        _LibraryPicker(selected: appSettings.library),
                        const SizedBox(height: 28),
                        const _SectionTitle('Camera'),
                        _Toggles(
                          flash: appSettings.useFlash,
                          tips: appSettings.showTips,
                          vibrations: appSettings.haptics,
                          // Only offered when Claude is configured (never in
                          // release builds until the proxy exists).
                          claudeAi: kAnthropicApiKey.isEmpty ? null : appSettings.aiConsent == true,
                        ),
                        const SizedBox(height: 32),
                        const _ResetButton(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 4),
        child: Semantics(header: true, child: Text(title, style: kHeading(22))),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  // A Material (not a decorated Container) so list tiles and ink ripples
  // inside it paint on this surface.
  Widget build(BuildContext context) => Material(
        color: kBgPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: kDivider),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

class _TextSizePicker extends StatelessWidget {
  final TextSizeOption selected;
  const _TextSizePicker({required this.selected});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final opt in TextSizeOption.values) ...[
                  if (opt != TextSizeOption.values.first) const SizedBox(width: 8),
                  Expanded(child: _SizeChoice(option: opt, selected: opt == selected)),
                ],
              ],
            ),
            const SizedBox(height: 14),
            Text("Charlotte's Web, by E. B. White", style: kBody(18)),
          ],
        ),
      ),
    );
  }
}

class _SizeChoice extends StatelessWidget {
  final TextSizeOption option;
  final bool selected;
  const _SizeChoice({required this.option, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Text size ${option.label}',
      excludeSemantics: true,
      child: Material(
        color: selected ? kGoldText : kBgScreen,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? kGoldText : kDivider, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            tapFeedback();
            appSettings.update(textSize: option);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: MediaQuery.withNoTextScaling(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // The "A" grows with each option, so the choice is visible at a glance.
                  Text('A',
                      style: kHeading(15 + option.index * 6.0,
                          color: selected ? Colors.white : kText)),
                  Text(option.label,
                      style: kLabel(14, color: selected ? Colors.white : kTextMut)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FontPicker extends StatelessWidget {
  final ReadingFont selected;
  const _FontPicker({required this.selected});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        children: [
          for (final f in ReadingFont.values) ...[
            if (f != ReadingFont.values.first) const Divider(color: kDivider, height: 1),
            _FontChoice(font: f, selected: f == selected),
          ],
        ],
      ),
    );
  }
}

class _FontChoice extends StatelessWidget {
  final ReadingFont font;
  final bool selected;
  const _FontChoice({required this.font, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Font ${font.label}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () {
          tapFeedback();
          appSettings.update(font: font);
        },
        child: Container(
          color: selected ? kGold.withValues(alpha: 0.12) : null,
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: selected ? kGoldText : kTextFaint,
                size: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                // Each option is written in its own font.
                child: Text(font.label,
                    style: GoogleFonts.getFont(font.bodyFamily,
                        fontSize: 19, fontWeight: FontWeight.w500, color: kText)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryPicker extends StatelessWidget {
  final CatalogLibrary selected;
  const _LibraryPicker({required this.selected});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: 'Library: ${selected.label}',
              excludeSemantics: true,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<CatalogLibrary>(
                  value: selected,
                  isExpanded: true,
                  icon: const Icon(Icons.expand_more_rounded, color: kGoldText, size: 28),
                  borderRadius: BorderRadius.circular(12),
                  dropdownColor: kBgPanel,
                  items: [
                    for (final lib in CatalogLibrary.values)
                      DropdownMenuItem(
                        value: lib,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: kMinTap),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(lib.label, style: kBody(18, color: kText)),
                          ),
                        ),
                      ),
                  ],
                  onChanged: (lib) {
                    if (lib == null) return;
                    tapFeedback();
                    appSettings.update(library: lib);
                  },
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text('Which library\'s catalog to check for availability.',
                style: kLabel(14, color: kTextMut)),
          ],
        ),
      ),
    );
  }
}

class _Toggles extends StatelessWidget {
  final bool flash;
  final bool tips;
  final bool vibrations;
  final bool? claudeAi;
  const _Toggles({
    required this.flash,
    required this.tips,
    required this.vibrations,
    required this.claudeAi,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        children: [
          _ToggleRow(
            title: 'Flash',
            value: flash,
            onChanged: (v) => appSettings.update(useFlash: v),
          ),
          const Divider(color: kDivider, height: 1),
          _ToggleRow(
            title: 'Tips',
            value: tips,
            onChanged: (v) => appSettings.update(showTips: v),
          ),
          const Divider(color: kDivider, height: 1),
          _ToggleRow(
            title: 'Vibrations',
            value: vibrations,
            onChanged: (v) => appSettings.update(haptics: v),
          ),
          if (claudeAi != null) ...[
            const Divider(color: kDivider, height: 1),
            _ToggleRow(
              title: 'Claude AI',
              value: claudeAi!,
              onChanged: (v) => appSettings.update(aiConsent: v),
            ),
          ],
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({required this.title, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: (v) {
        onChanged(v);
        tapFeedback();
      },
      title: Text(title, style: kLabel(19, color: kText, weight: FontWeight.w600)),
      activeTrackColor: kGoldText,
      minTileHeight: 60,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton();

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: 'Reset settings',
      icon: Icons.restart_alt_rounded,
      kind: AppButtonKind.secondary,
      expand: true,
      onPressed: appSettings.reset,
    );
  }
}

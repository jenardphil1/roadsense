import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'app_design.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// WEB PLATFORM SETTINGS DIALOG
/// Premium Desktop & Web Console Settings Center
/// ─────────────────────────────────────────────────────────────────────────────
class WebSettingsDialog extends StatefulWidget {
  final VoidCallback? onSettingsChanged;
  const WebSettingsDialog({super.key, this.onSettingsChanged});

  @override
  State<WebSettingsDialog> createState() => _WebSettingsDialogState();
}

enum _WebSettingsTab {
  appearance,
  gis,
  devTools,
  system,
}

class _WebSettingsDialogState extends State<WebSettingsDialog> {
  final settings = AppSettings.instance;
  _WebSettingsTab _currentTab = _WebSettingsTab.appearance;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: settings.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        final isDark = currentThemeMode == ThemeMode.system
            ? (MediaQuery.platformBrightnessOf(context) == Brightness.dark)
            : (currentThemeMode == ThemeMode.dark);

        final Color modalBg = isDark ? const Color(0xFF0F172A) : Colors.white;
        final Color sidebarBg = isDark ? const Color(0xFF0B111E) : const Color(0xFFF8FAFC);
        final Color cardBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
        final Color itemHoverBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
        final Color borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
        final Color textColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
        final Color subtextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        final Color accentColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);

        final screenWidth = MediaQuery.of(context).size.width;
        final isCompact = screenWidth < 700;

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Container(
              width: 820,
              height: 600,
              decoration: BoxDecoration(
                color: modalBg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
                    blurRadius: 36,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  // ── TOP MODAL HEADER ───────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: modalBg,
                      border: Border(bottom: BorderSide(color: borderColor)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [accentColor, accentColor.withValues(alpha: 0.8)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: accentColor.withValues(alpha: 0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.tune_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Web Platform Settings',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: textColor,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              Text(
                                'Customize your visual theme, GIS canvas & developer simulation tools',
                                style: TextStyle(fontSize: 12, color: subtextColor),
                              ),
                            ],
                          ),
                        ),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(),
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(Icons.close_rounded, color: subtextColor, size: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── COMPACT TOP TAB BAR (Narrow Viewports) ─────────────────
                  if (isCompact)
                    Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: sidebarBg,
                        border: Border(bottom: BorderSide(color: borderColor)),
                      ),
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        children: [
                          _buildCompactTab(Icons.palette_rounded, 'Appearance', _WebSettingsTab.appearance, isDark, accentColor, textColor, subtextColor),
                          _buildCompactTab(Icons.map_rounded, 'GIS & Display', _WebSettingsTab.gis, isDark, accentColor, textColor, subtextColor),
                          _buildCompactTab(Icons.construction_rounded, 'Dev Tools', _WebSettingsTab.devTools, isDark, accentColor, textColor, subtextColor),
                          _buildCompactTab(Icons.info_outline_rounded, 'System', _WebSettingsTab.system, isDark, accentColor, textColor, subtextColor),
                        ],
                      ),
                    ),

                  // ── MAIN BODY (Desktop Split View or Full Content) ──────────
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left Sidebar (Desktop only)
                        if (!isCompact)
                          Container(
                            width: 220,
                            decoration: BoxDecoration(
                              color: sidebarBg,
                              border: Border(right: BorderSide(color: borderColor)),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(left: 10, bottom: 8),
                                  child: Text(
                                    'PREFERENCES',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: subtextColor,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                _buildSidebarItem(Icons.palette_rounded, 'Appearance', _WebSettingsTab.appearance, isDark, accentColor, textColor, subtextColor, itemHoverBg),
                                _buildSidebarItem(Icons.map_rounded, 'GIS & Display', _WebSettingsTab.gis, isDark, accentColor, textColor, subtextColor, itemHoverBg),
                                _buildSidebarItem(Icons.construction_rounded, 'Developer Tools', _WebSettingsTab.devTools, isDark, accentColor, textColor, subtextColor, itemHoverBg),
                                const SizedBox(height: 12),
                                Divider(color: borderColor, height: 1),
                                const SizedBox(height: 12),
                                Padding(
                                  padding: const EdgeInsets.only(left: 10, bottom: 8),
                                  child: Text(
                                    'PLATFORM',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: subtextColor,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                _buildSidebarItem(Icons.info_outline_rounded, 'System & About', _WebSettingsTab.system, isDark, accentColor, textColor, subtextColor, itemHoverBg),
                              ],
                            ),
                          ),

                        // Right Content Panel
                        Expanded(
                          child: Container(
                            color: modalBg,
                            padding: const EdgeInsets.all(24),
                            child: SingleChildScrollView(
                              child: _buildCurrentTabContent(
                                isDark: isDark,
                                cardBg: cardBg,
                                borderColor: borderColor,
                                textColor: textColor,
                                subtextColor: subtextColor,
                                accentColor: accentColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── BOTTOM MODAL ACTIONS FOOTER ───────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      color: sidebarBg,
                      border: Border(top: BorderSide(color: borderColor)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            settings.resetWebSettingsToDefaults();
                            widget.onSettingsChanged?.call();
                            setState(() {});
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Settings reset to default values.'),
                                backgroundColor: accentColor,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: Icon(Icons.restart_alt_rounded, size: 16, color: subtextColor),
                          label: Text(
                            'Reset to Defaults',
                            style: TextStyle(color: subtextColor, fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          child: const Text('Done & Apply', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebarItem(
    IconData icon,
    String title,
    _WebSettingsTab tab,
    bool isDark,
    Color accentColor,
    Color textColor,
    Color subtextColor,
    Color hoverColor,
  ) {
    final isSelected = _currentTab == tab;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: isSelected ? accentColor.withValues(alpha: isDark ? 0.18 : 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => setState(() => _currentTab = tab),
          borderRadius: BorderRadius.circular(10),
          hoverColor: hoverColor,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? accentColor.withValues(alpha: 0.3) : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isSelected ? accentColor : subtextColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? (isDark ? Colors.white : accentColor) : textColor,
                    ),
                  ),
                ),
                if (isSelected)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactTab(
    IconData icon,
    String title,
    _WebSettingsTab tab,
    bool isDark,
    Color accentColor,
    Color textColor,
    Color subtextColor,
  ) {
    final isSelected = _currentTab == tab;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        avatar: Icon(icon, size: 14, color: isSelected ? Colors.white : subtextColor),
        label: Text(title),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          color: isSelected ? Colors.white : textColor,
        ),
        selected: isSelected,
        selectedColor: accentColor,
        backgroundColor: Colors.transparent,
        showCheckmark: false,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onSelected: (_) => setState(() => _currentTab = tab),
      ),
    );
  }

  Widget _buildCurrentTabContent({
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textColor,
    required Color subtextColor,
    required Color accentColor,
  }) {
    switch (_currentTab) {
      case _WebSettingsTab.appearance:
        return _buildAppearanceSection(isDark, cardBg, borderColor, textColor, subtextColor, accentColor);
      case _WebSettingsTab.gis:
        return _buildGisSection(isDark, cardBg, borderColor, textColor, subtextColor, accentColor);
      case _WebSettingsTab.devTools:
        return _buildDevToolsSection(isDark, cardBg, borderColor, textColor, subtextColor, accentColor);
      case _WebSettingsTab.system:
        return _buildSystemSection(isDark, cardBg, borderColor, textColor, subtextColor, accentColor);
    }
  }

  // ── 1. APPEARANCE & THEME TAB ─────────────────────────────────────────────
  Widget _buildAppearanceSection(
    bool isDark,
    Color cardBg,
    Color borderColor,
    Color textColor,
    Color subtextColor,
    Color accentColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeaderTitle('Appearance & Visual Theme', 'Choose how the RoadSense web console and map render on your monitor.'),
        const SizedBox(height: 20),

        _buildSubhead('THEME MODE'),
        const SizedBox(height: 10),

        // Visual Theme Mode Selector Cards
        Row(
          children: [
            Expanded(
              child: _buildSelectableCard(
                icon: Icons.brightness_auto_rounded,
                title: 'System Auto',
                subtitle: 'Match OS preference',
                isSelected: settings.themeModeNotifier.value == ThemeMode.system,
                isDark: isDark,
                accentColor: accentColor,
                borderColor: borderColor,
                cardBg: cardBg,
                textColor: textColor,
                subtextColor: subtextColor,
                onTap: () {
                  settings.themeModeNotifier.value = ThemeMode.system;
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSelectableCard(
                icon: Icons.dark_mode_rounded,
                title: 'Midnight Dark',
                subtitle: 'Deep obsidian theme',
                isSelected: settings.themeModeNotifier.value == ThemeMode.dark,
                isDark: isDark,
                accentColor: accentColor,
                borderColor: borderColor,
                cardBg: cardBg,
                textColor: textColor,
                subtextColor: subtextColor,
                onTap: () {
                  settings.toggleTheme(true);
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSelectableCard(
                icon: Icons.light_mode_rounded,
                title: 'Daylight Light',
                subtitle: 'Crisp slate white',
                isSelected: settings.themeModeNotifier.value == ThemeMode.light,
                isDark: isDark,
                accentColor: accentColor,
                borderColor: borderColor,
                cardBg: cardBg,
                textColor: textColor,
                subtextColor: subtextColor,
                onTap: () {
                  settings.toggleTheme(false);
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Icon(Icons.contrast_rounded, size: 22, color: accentColor),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'High-Contrast Black & White Mode',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    Text(
                      'Monochrome high-contrast display for sunlight glare & accessibility',
                      style: TextStyle(fontSize: 12, color: subtextColor),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: settings.highContrastMonochromeNotifier,
                builder: (context, isBw, _) {
                  return Switch(
                    value: isBw,
                    activeTrackColor: accentColor,
                    onChanged: (val) {
                      settings.toggleHighContrastMonochrome(val);
                      widget.onSettingsChanged?.call();
                    },
                  );
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 26),
        _buildSubhead('GIS CARTOGRAPHY STYLE'),
        const SizedBox(height: 10),

        // Visual Map Style Selector Cards
        Row(
          children: [
            Expanded(
              child: _buildSelectableCard(
                icon: Icons.layers_rounded,
                title: 'Dark Canvas',
                subtitle: 'High contrast vector tiles',
                isSelected: settings.webMapStyle == 'Dark Canvas',
                isDark: isDark,
                accentColor: accentColor,
                borderColor: borderColor,
                cardBg: cardBg,
                textColor: textColor,
                subtextColor: subtextColor,
                onTap: () {
                  setState(() => settings.webMapStyle = 'Dark Canvas');
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSelectableCard(
                icon: Icons.map_rounded,
                title: 'Google Maps',
                subtitle: 'Standard roadmap tiles',
                isSelected: settings.webMapStyle == 'Google Maps',
                isDark: isDark,
                accentColor: accentColor,
                borderColor: borderColor,
                cardBg: cardBg,
                textColor: textColor,
                subtextColor: subtextColor,
                onTap: () {
                  setState(() => settings.webMapStyle = 'Google Maps');
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSelectableCard(
                icon: Icons.satellite_alt_rounded,
                title: 'Satellite',
                subtitle: 'High-res aerial imagery',
                isSelected: settings.webMapStyle == 'Satellite',
                isDark: isDark,
                accentColor: accentColor,
                borderColor: borderColor,
                cardBg: cardBg,
                textColor: textColor,
                subtextColor: subtextColor,
                onTap: () {
                  setState(() => settings.webMapStyle = 'Satellite');
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 2. GIS & CARTOGRAPHY TAB ──────────────────────────────────────────────
  Widget _buildGisSection(
    bool isDark,
    Color cardBg,
    Color borderColor,
    Color textColor,
    Color subtextColor,
    Color accentColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeaderTitle('GIS & Map Display', 'Configure map hazard overlays and surveyor markers.'),
        const SizedBox(height: 20),

        ValueListenableBuilder<bool>(
          valueListenable: settings.showPotholesNotifier,
          builder: (context, showPotholes, _) {
            return _buildToggleCard(
              icon: Icons.warning_amber_rounded,
              iconColor: const Color(0xFFEF4444),
              title: 'Hazard Pins Overlay',
              description: 'Display detected pothole markers and surveyor inspection points on the active map.',
              value: showPotholes,
              onChanged: (val) {
                settings.toggleShowPotholes(val);
                widget.onSettingsChanged?.call();
              },
              isDark: isDark,
              cardBg: cardBg,
              borderColor: borderColor,
              textColor: textColor,
              subtextColor: subtextColor,
              accentColor: accentColor,
            );
          },
        ),
      ],
    );
  }

  // ── 3. DEVELOPER TOOLS TAB ────────────────────────────────────────────────
  Widget _buildDevToolsSection(
    bool isDark,
    Color cardBg,
    Color borderColor,
    Color textColor,
    Color subtextColor,
    Color accentColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeaderTitle('Developer & Testing Tools', 'Simulate field inspections, place custom test hazards, and adjust GPS coordinates.'),
        const SizedBox(height: 20),

        // 1. Manual Pothole Placement Card with Action Button
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.add_location_alt_rounded, color: Color(0xFF10B981), size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Manual Pothole Placement', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textColor)),
                        const SizedBox(height: 2),
                        Text('Place custom GPS coordinate test markers anywhere on the map.', style: TextStyle(fontSize: 11.5, color: subtextColor)),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: settings.manualPotholePlacementNotifier,
                    builder: (context, enabled, _) {
                      return Switch(
                        value: enabled,
                        activeTrackColor: const Color(0xFF10B981),
                        onChanged: (val) {
                          settings.toggleManualPotholePlacement(val);
                          widget.onSettingsChanged?.call();
                        },
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: borderColor.withValues(alpha: 0.6), height: 1),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Directly launch placement mode on the live map canvas:',
                      style: TextStyle(fontSize: 11.5, color: subtextColor),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () {
                      settings.toggleManualPotholePlacement(true);
                      widget.onSettingsChanged?.call();
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Manual Pothole Placement active. Click anywhere on the map to place a pin.'),
                          backgroundColor: Color(0xFF10B981),
                          duration: Duration(seconds: 4),
                        ),
                      );
                    },
                    icon: const Icon(Icons.touch_app_rounded, size: 16, color: Colors.white),
                    label: const Text('Place Pin on Map', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // 2. Manual / Simulated GPS Location with Action Button
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.my_location_rounded, color: Color(0xFF6366F1), size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Manual GPS Location (Draggable Pin)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textColor)),
                        const SizedBox(height: 2),
                        Text('Override live GPS and drag current position pin for route testing.', style: TextStyle(fontSize: 11.5, color: subtextColor)),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: settings.devEditLocationNotifier,
                    builder: (context, enabled, _) {
                      return Switch(
                        value: enabled,
                        activeTrackColor: const Color(0xFF6366F1),
                        onChanged: (val) {
                          settings.toggleDevEditLocation(val);
                          widget.onSettingsChanged?.call();
                        },
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: borderColor.withValues(alpha: 0.6), height: 1),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Reposition your simulated vehicle / surveyor GPS:',
                      style: TextStyle(fontSize: 11.5, color: subtextColor),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () {
                      settings.toggleDevEditLocation(true);
                      widget.onSettingsChanged?.call();
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('GPS Location Editing active. Drag your location marker on the map.'),
                          backgroundColor: Color(0xFF6366F1),
                          duration: Duration(seconds: 4),
                        ),
                      );
                    },
                    icon: const Icon(Icons.edit_location_alt_rounded, size: 16, color: Colors.white),
                    label: const Text('Edit GPS Location', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // 3. Master Mock Mode Switch
        ValueListenableBuilder<bool>(
          valueListenable: settings.devMockModeNotifier,
          builder: (context, mockMode, _) {
            return _buildToggleCard(
              icon: Icons.biotech_rounded,
              iconColor: const Color(0xFFEC4899),
              title: 'Master Simulation & Mock Mode',
              description: 'Enable developer mock telemetry and simulation route events on the web dashboard.',
              value: mockMode,
              onChanged: (val) {
                settings.toggleDevMockMode(val);
                widget.onSettingsChanged?.call();
              },
              isDark: isDark,
              cardBg: cardBg,
              borderColor: borderColor,
              textColor: textColor,
              subtextColor: subtextColor,
              accentColor: accentColor,
            );
          },
        ),
      ],
    );
  }

  // ── 4. SYSTEM INFO & ABOUT TAB ────────────────────────────────────────────
  Widget _buildSystemSection(
    bool isDark,
    Color cardBg,
    Color borderColor,
    Color textColor,
    Color subtextColor,
    Color accentColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeaderTitle('System & Diagnostics', 'Platform telemetry and service connectivity.'),
        const SizedBox(height: 20),

        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            children: [
              _buildDiagnosticRow(Icons.layers_rounded, 'Platform Core', 'RoadSense AI Web Console v2.4.0 (Enterprise)', const Color(0xFF0284C7), textColor, subtextColor, borderColor),
              _buildDiagnosticRow(Icons.cloud_done_rounded, 'Database Backend', 'Google Cloud Firestore Real-Time (Connected)', const Color(0xFF10B981), textColor, subtextColor, borderColor),
              _buildDiagnosticRow(Icons.map_rounded, 'Cartography Engine', 'Geoapify & OpenStreetMap Vector Engine', const Color(0xFF10B981), textColor, subtextColor, borderColor),
              _buildDiagnosticRow(Icons.alt_route_rounded, 'Avoidance Routing', 'OpenRouteService Safety Dispatch (Active)', const Color(0xFF10B981), textColor, subtextColor, borderColor, isLast: true),
            ],
          ),
        ),

        const SizedBox(height: 20),

        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_rounded, color: Color(0xFF10B981), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Enterprise Security & Privacy Enforced', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor)),
                    Text('All geospatial coordinates and surveyor reports are encrypted in transit via TLS 1.3.', style: TextStyle(fontSize: 11.5, color: subtextColor)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── REUSABLE HELPER BUILDERS ──────────────────────────────────────────────
  Widget _buildHeaderTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B))),
      ],
    );
  }

  Widget _buildSubhead(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Color(0xFF94A3B8), letterSpacing: 0.8),
    );
  }

  Widget _buildSelectableCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isSelected,
    required bool isDark,
    required Color accentColor,
    required Color borderColor,
    required Color cardBg,
    required Color textColor,
    required Color subtextColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isSelected
          ? accentColor.withValues(alpha: isDark ? 0.18 : 0.08)
          : cardBg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? accentColor : borderColor,
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon, size: 22, color: isSelected ? accentColor : subtextColor),
                  if (isSelected)
                    Icon(Icons.check_circle_rounded, size: 16, color: accentColor),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? (isDark ? Colors.white : accentColor) : textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: subtextColor, height: 1.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggleCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required Color textColor,
    required Color subtextColor,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: textColor)),
                const SizedBox(height: 2),
                Text(description, style: TextStyle(fontSize: 11.5, color: subtextColor, height: 1.35)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            activeTrackColor: accentColor,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticRow(
    IconData icon,
    String label,
    String status,
    Color statusColor,
    Color textColor,
    Color subtextColor,
    Color borderColor, {
    bool isLast = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: subtextColor),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textColor)),
          const Spacer(),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: subtextColor),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// MOBILE PLATFORM SETTINGS SHEET
/// Tailored for Drivers, Road Inspectors & Mobile Navigation
/// ─────────────────────────────────────────────────────────────────────────────
class MobileSettingsSheet extends StatefulWidget {
  final VoidCallback? onSettingsChanged;
  const MobileSettingsSheet({super.key, this.onSettingsChanged});

  @override
  State<MobileSettingsSheet> createState() => _MobileSettingsSheetState();
}

class _MobileSettingsSheetState extends State<MobileSettingsSheet> {
  final settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: settings.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        final isDark = currentThemeMode == ThemeMode.system
            ? (MediaQuery.platformBrightnessOf(context) == Brightness.dark)
            : (currentThemeMode == ThemeMode.dark);
        final bgColor = AppDesign.bg(isDark);
        final cardColor = AppDesign.surface(isDark);
        final textColor = AppDesign.textPrimary(isDark);
        final subtextColor = AppDesign.textSecondary(isDark);
        final borderColor = AppDesign.border(isDark);
        final accentColor = AppDesign.accent(isDark);

        return Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: subtextColor.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.tune_rounded, color: accentColor, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RoadSense Settings',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textColor),
                        ),
                        Text(
                          'Appearance & Map Layers',
                          style: TextStyle(fontSize: 12, color: subtextColor),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: subtextColor, size: 22),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: borderColor, height: 1),
              const SizedBox(height: 14),

              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // SECTION 1: THEME & DISPLAY
                      _buildSectionHeader('APPEARANCE & DISPLAY', Icons.dark_mode_rounded, accentColor),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: borderColor),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(
                                  isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                                  color: isDark ? AppDesign.accent(isDark) : AppDesign.warning,
                                  size: 22,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Theme Mode', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor)),
                                      Text(isDark ? 'Dark Theme (Midnight mode)' : 'Light Theme (Daylight mode)', style: TextStyle(fontSize: 12, color: subtextColor)),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: isDark,
                                  activeTrackColor: accentColor,
                                  onChanged: (val) {
                                    settings.toggleTheme(val);
                                  },
                                ),
                              ],
                            ),
                            Divider(color: borderColor, height: 20),
                            Row(
                              children: [
                                Icon(
                                  Icons.contrast_rounded,
                                  color: accentColor,
                                  size: 22,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'High-Contrast Black & White',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: textColor,
                                        ),
                                      ),
                                      Text(
                                        'Monochrome display for sunlight visibility & anti-glare',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: subtextColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ValueListenableBuilder<bool>(
                                  valueListenable:
                                      settings.highContrastMonochromeNotifier,
                                  builder: (context, isBw, _) {
                                    return Switch(
                                      value: isBw,
                                      activeTrackColor: accentColor,
                                      onChanged: (val) {
                                        settings.toggleHighContrastMonochrome(val);
                                        widget.onSettingsChanged?.call();
                                      },
                                    );
                                  },
                                ),
                              ],
                            ),
                            Divider(color: borderColor, height: 20),
                            Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 22),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Pothole Markers Layer', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor)),
                                      Text('Show or hide pothole markers on map view', style: TextStyle(fontSize: 12, color: subtextColor)),
                                    ],
                                  ),
                                ),
                                ValueListenableBuilder<bool>(
                                  valueListenable: settings.showPotholesNotifier,
                                  builder: (context, showPotholes, _) {
                                    return Switch(
                                      value: showPotholes,
                                      activeTrackColor: accentColor,
                                      onChanged: (val) {
                                        settings.toggleShowPotholes(val);
                                        widget.onSettingsChanged?.call();
                                      },
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // SECTION 2: DEVELOPER & SIMULATION TOOLS
                      _buildSectionHeader('DEVELOPER & SIMULATION TOOLS', Icons.science_rounded, accentColor),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: accentColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(Icons.developer_mode_rounded, color: accentColor, size: 22),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Developer Mock Mode', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor)),
                                  const SizedBox(height: 2),
                                  Text('Show right-side map buttons for custom GPS location & custom marker placement', style: TextStyle(fontSize: 12, color: subtextColor)),
                                ],
                              ),
                            ),
                            ValueListenableBuilder<bool>(
                              valueListenable: settings.devMockModeNotifier,
                              builder: (context, isDevMock, _) {
                                return Switch(
                                  value: isDevMock,
                                  activeTrackColor: accentColor,
                                  onChanged: (val) {
                                    settings.toggleDevMockMode(val);
                                    widget.onSettingsChanged?.call();
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Done', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color accentColor) {
    return Row(
      children: [
        Icon(icon, size: 15, color: accentColor),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.7,
            color: accentColor,
          ),
        ),
      ],
    );
  }
}

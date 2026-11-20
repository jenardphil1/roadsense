/// Shared widgets for the RoadSense web UI.
///
/// Web-only (see CLAUDE.md section 1). Every widget here draws its colours and
/// metrics from [WebDesign], so a token change lands everywhere at once instead
/// of needing 400-odd hex literals edited by hand.
library;

import 'road_sense_brand.dart';

import 'package:flutter/material.dart';

import 'dpwh_standards.dart';
import 'web_design.dart';
import 'web_report_query.dart';

/// Constrains page content to a readable measure and centres it.
///
/// Without this the dashboard grids stretch edge-to-edge on a wide monitor,
/// which is the single loudest "unfinished" tell in an admin console.
class CenteredMaxWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const CenteredMaxWidth({
    super.key,
    required this.child,
    this.maxWidth = WebDesign.contentMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Scrollable page body with responsive gutters and a max content width.
class PageBody extends StatelessWidget {
  final List<Widget> children;
  final double maxWidth;
  final EdgeInsets? padding;

  const PageBody({
    super.key,
    required this.children,
    this.maxWidth = WebDesign.contentMaxWidth,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SingleChildScrollView(
      padding: padding ?? WebDesign.pageInsets(width),
      child: CenteredMaxWidth(
        maxWidth: maxWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

/// Surface panel. One radius, one border, one shadow — the whole app.
class WebCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final double radius;
  final bool elevated;
  final Color? accentBorder;
  final VoidCallback? onTap;

  const WebCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = WebDesign.radiusLg,
    this.elevated = true,
    this.accentBorder,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final decorated = Container(
      padding: padding ?? const EdgeInsets.all(WebDesign.space5),
      decoration: WebDesign.cardDecoration(
        isDark,
        radius: radius,
        elevated: elevated,
        accentBorder: accentBorder,
      ),
      child: child,
    );

    if (onTap == null) return decorated;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          hoverColor: WebDesign.brand(isDark).withValues(alpha: 0.05),
          child: decorated,
        ),
      ),
    );
  }
}

/// Uppercase micro-label used for sidebar groups and metric captions.
///
/// The only place 11px text is allowed, and only because it is tracked-out and
/// uppercase. It reads at `textMuted`, which clears 4.5:1 in both themes —
/// unlike the `white @ 25% alpha` it replaces.
class Eyebrow extends StatelessWidget {
  final String text;
  final Color? color;

  const Eyebrow(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    );
  }
}

/// Section title with optional supporting line and trailing action.
class SectionHeading extends StatelessWidget {
  final String title;
  final String? eyebrow;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  const SectionHeading({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: WebDesign.iconMd,
            color: WebDesign.brandOnSurface(isDark),
          ),
          const SizedBox(width: WebDesign.space2),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null) ...[
                Eyebrow(eyebrow!),
                const SizedBox(height: 4),
              ],
              Text(title, style: theme.textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: WebDesign.space3),
          trailing!,
        ],
      ],
    );
  }
}

/// The one place a submission status is rendered.
///
/// Always icon + word, never colour alone, and identical on every screen — the
/// same "approved" report used to render green in the admin list, blue in the
/// dark-mode profile and grey in the light-mode profile.
class StatusChip extends StatelessWidget {
  final StatusTone tone;
  final String? label;
  final bool dense;

  const StatusChip({
    super.key,
    required this.tone,
    this.label,
    this.dense = false,
  });

  /// Builds straight from a Firestore `status` string.
  factory StatusChip.fromStatus(String? status, {bool dense = false}) =>
      StatusChip(tone: WebDesign.toneOf(status), dense: dense);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final style = WebDesign.statusStyle(tone, isDark);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? WebDesign.space2 : WebDesign.space2 + 2,
        vertical: dense ? 3 : WebDesign.space1,
      ),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: style.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            style.icon,
            size: dense ? WebDesign.icon2xs : WebDesign.iconXs,
            color: style.fg,
          ),
          const SizedBox(width: WebDesign.space1 + 2),
          Text(
            label ?? style.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: style.fg,
              fontWeight: FontWeight.w700,
              fontSize: dense ? 11 : 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashboard stat tile: caption, figure, optional supporting line.
///
/// Deliberately has no trend arrow. The old card stamped a rising arrow on all
/// four tiles including "Pending Review", where rising is bad and the arrow was
/// not computed from anything.
class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color accent;
  final String? hint;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return WebCard(
      padding: const EdgeInsets.all(WebDesign.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(WebDesign.space2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.18 : 0.11),
                  borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                ),
                child: Icon(icon, color: accent, size: WebDesign.iconSm),
              ),
              const SizedBox(width: WebDesign.space2),
              Expanded(child: Eyebrow(label)),
            ],
          ),
          const SizedBox(height: WebDesign.space3),
          Text(
            value,
            style: WebDesign.tabular(
              theme.textTheme.headlineMedium ?? const TextStyle(),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint!,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Empty state with an explanation and an optional next step.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool boxed;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.boxed = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(WebDesign.space3),
          decoration: BoxDecoration(
            color: WebDesign.sunken(isDark),
            shape: BoxShape.circle,
            border: Border.all(color: WebDesign.border(isDark)),
          ),
          child: Icon(
            icon,
            size: WebDesign.iconLg,
            color: WebDesign.textMuted(isDark),
          ),
        ),
        const SizedBox(height: WebDesign.space3),
        Text(
          title,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: WebDesign.space1),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            message,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
        if (action != null) ...[
          const SizedBox(height: WebDesign.space4),
          action!,
        ],
      ],
    );

    if (!boxed) return Center(child: content);

    return WebCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WebDesign.space6,
        vertical: WebDesign.space10,
      ),
      child: Center(child: content),
    );
  }
}

/// Read-only coordinate readout. Monospaced figures so columns line up, and an
/// affordance when it is tappable.
class CoordinatePill extends StatelessWidget {
  final double latitude;
  final double longitude;
  final VoidCallback? onTap;
  final int precision;

  const CoordinatePill({
    super.key,
    required this.latitude,
    required this.longitude,
    this.onTap,
    this.precision = 5,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final body = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WebDesign.space2,
        vertical: WebDesign.space1 + 1,
      ),
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.place_outlined,
            size: WebDesign.iconXs,
            color: WebDesign.textSecondary(isDark),
          ),
          const SizedBox(width: WebDesign.space1 + 2),
          Text(
            '${latitude.toStringAsFixed(precision)}, '
            '${longitude.toStringAsFixed(precision)}',
            style: WebDesign.tabular(
              theme.textTheme.labelMedium?.copyWith(
                    color: WebDesign.textPrimary(isDark),
                  ) ??
                  const TextStyle(),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: WebDesign.space1 + 2),
            Icon(
              Icons.north_east_rounded,
              size: WebDesign.icon2xs,
              color: WebDesign.brandOnSurface(isDark),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return body;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(WebDesign.radiusSm),
          child: body,
        ),
      ),
    );
  }
}

/// Equal-height responsive grid for [MetricTile] strips without fixed aspect
/// ratios that clip under large text or narrow viewports.
class MetricGrid extends StatelessWidget {
  final List<Widget> children;
  final int desktopColumns;
  final double spacing;

  const MetricGrid({
    super.key,
    required this.children,
    this.desktopColumns = 4,
    this.spacing = WebDesign.space4,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 900
            ? desktopColumns.clamp(1, children.length)
            : (constraints.maxWidth >= 540 ? 2 : 1);
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += cols) {
          final slice = children.skip(i).take(cols).toList();
          if (i > 0) rows.add(SizedBox(height: spacing));
          rows.add(
            cols == 1
                ? slice.first
                : IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var c = 0; c < cols; c++) ...[
                          if (c > 0) SizedBox(width: spacing),
                          Expanded(
                            child: c < slice.length
                                ? slice[c]
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      },
    );
  }
}

/// Segmented Map / Profile switcher plus optional status pill & settings button.
///
/// One implementation for both surfaces.
class WebViewSwitcher extends StatelessWidget {
  final bool isMapActive;
  final VoidCallback? onSelectMap;
  final VoidCallback? onSelectProfile;
  final VoidCallback onOpenSettings;
  final bool showLiveIndicator;

  const WebViewSwitcher({
    super.key,
    required this.isMapActive,
    required this.onOpenSettings,
    this.onSelectMap,
    this.onSelectProfile,
    this.showLiveIndicator = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(WebDesign.space1),
      decoration: BoxDecoration(
        color: WebDesign.surface(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: WebDesign.border(isDark)),
        boxShadow: WebDesign.shadowMd(isDark),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Segment(
            icon: Icons.map_rounded,
            label: 'Map',
            selected: isMapActive,
            onTap: isMapActive ? null : onSelectMap,
          ),
          if (onSelectProfile != null || !isMapActive)
            _Segment(
              icon: Icons.person_rounded,
              label: 'Profile',
              selected: !isMapActive,
              onTap: isMapActive ? onSelectProfile : null,
            ),
          if (showLiveIndicator) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WebDesign.space2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: WebDesign.statusStyle(
                        StatusTone.approved,
                        isDark,
                      ).fg,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: WebDesign.space1 + 1),
                  Text(
                    'Live',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: WebDesign.textSecondary(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Container(
            width: 1,
            height: WebDesign.iconMd,
            margin: const EdgeInsets.symmetric(horizontal: WebDesign.space1),
            color: WebDesign.border(isDark),
          ),
          IconButton(
            onPressed: onOpenSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: WebDesign.iconSm),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(
              minWidth: WebDesign.minTarget,
              minHeight: WebDesign.minTarget,
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _Segment({
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fg = selected
        ? WebDesign.brandOnSurface(isDark)
        : WebDesign.textSecondary(isDark);

    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(WebDesign.radiusSm),
            child: AnimatedContainer(
              duration: WebDesign.fast,
              constraints: const BoxConstraints(minHeight: WebDesign.minTarget),
              padding: const EdgeInsets.symmetric(horizontal: WebDesign.space3),
              decoration: BoxDecoration(
                color: selected
                    ? WebDesign.brandWash(isDark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(WebDesign.radiusSm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: WebDesign.iconSm, color: fg),
                  const SizedBox(width: WebDesign.space1 + 2),
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Top navigation bar for the public/user RoadSense web shell (`#/map`,
/// `#/reports`, `#/account`), with responsive behavior down to `390px`.
class WebAppShellHeader extends StatelessWidget {
  final WebShellRoute activeRoute;
  final int myReportsCount;
  final String displayName;
  final String? roleLabel;
  final bool isVerified;
  final bool isLiveConnected;
  final ValueChanged<WebShellRoute> onSelectRoute;
  final VoidCallback onOpenHelp;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleTheme;
  final VoidCallback onSignOut;

  const WebAppShellHeader({
    super.key,
    required this.activeRoute,
    required this.myReportsCount,
    required this.displayName,
    this.roleLabel,
    this.isVerified = true,
    this.isLiveConnected = true,
    required this.onSelectRoute,
    required this.onOpenHelp,
    required this.onOpenSettings,
    required this.onToggleTheme,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < 820;
    final isNarrow = width < 480;
    final height = isCompact
        ? WebDesign.headerHeightMobile
        : WebDesign.headerHeight;

    final initials = displayName.trim().isNotEmpty
        ? displayName.trim().characters.first.toUpperCase()
        : 'R';

    return Semantics(
      container: true,
      label: 'Primary navigation',
      child: Material(
        color: WebDesign.surface(isDark),
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? WebDesign.space2 : WebDesign.space4,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: WebDesign.border(isDark))),
          ),
          child: Row(
            children: [
              // Brand wordmark
              InkWell(
                onTap: () => onSelectRoute(WebShellRoute.map),
                borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WebDesign.space1,
                    vertical: WebDesign.space1,
                  ),
                  child: RoadSenseBrand(size: 34, showWordmark: !isNarrow),
                ),
              ),
              SizedBox(width: isNarrow ? WebDesign.space2 : WebDesign.space4),
              // Primary navigation tabs
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _NavDestinationButton(
                        icon: Icons.map_outlined,
                        activeIcon: Icons.map_rounded,
                        label: 'Map',
                        selected: activeRoute == WebShellRoute.map,
                        compact: isNarrow,
                        onTap: () => onSelectRoute(WebShellRoute.map),
                      ),
                      const SizedBox(width: WebDesign.space1),
                      _NavDestinationButton(
                        icon: Icons.assignment_outlined,
                        activeIcon: Icons.assignment_rounded,
                        label: isNarrow ? 'Reports' : 'My Reports',
                        badgeCount: myReportsCount,
                        selected: activeRoute == WebShellRoute.reports,
                        compact: isNarrow,
                        onTap: () => onSelectRoute(WebShellRoute.reports),
                      ),
                      if (!isCompact) ...[
                        const SizedBox(width: WebDesign.space1),
                        _NavDestinationButton(
                          icon: Icons.person_outline_rounded,
                          activeIcon: Icons.person_rounded,
                          label: 'Profile',
                          selected: activeRoute == WebShellRoute.account,
                          compact: false,
                          onTap: () => onSelectRoute(WebShellRoute.account),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!isCompact) ...[
                Padding(
                  padding: const EdgeInsets.only(right: WebDesign.space2),
                  child: Tooltip(
                    message: isLiveConnected
                        ? 'Synced with cloud hazard feed'
                        : 'Connecting to cloud feed',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: WebDesign.space2,
                        vertical: WebDesign.space1,
                      ),
                      decoration: BoxDecoration(
                        color: WebDesign.sunken(isDark),
                        borderRadius: BorderRadius.circular(
                          WebDesign.radiusPill,
                        ),
                        border: Border.all(color: WebDesign.border(isDark)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: isLiveConnected
                                  ? WebDesign.statusStyle(
                                      StatusTone.approved,
                                      isDark,
                                    ).fg
                                  : WebDesign.statusStyle(
                                      StatusTone.pending,
                                      isDark,
                                    ).fg,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: WebDesign.space1 + 2),
                          Text(
                            isLiveConnected ? 'Live' : 'Syncing',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: WebDesign.textSecondary(isDark),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (!isNarrow)
                IconButton(
                  onPressed: onOpenHelp,
                  tooltip: 'Help & Guide',
                  icon: const Icon(Icons.help_outline_rounded, size: 19),
                  constraints: const BoxConstraints(
                    minWidth: WebDesign.touchTarget,
                    minHeight: WebDesign.touchTarget,
                  ),
                ),
              if (!isCompact)
                IconButton(
                  onPressed: onOpenSettings,
                  tooltip: 'Preferences & Map Settings',
                  icon: const Icon(Icons.tune_rounded, size: 19),
                  constraints: const BoxConstraints(
                    minWidth: WebDesign.touchTarget,
                    minHeight: WebDesign.touchTarget,
                  ),
                ),
              const SizedBox(width: WebDesign.space1),
              // Account / Profile Menu
              PopupMenuButton<String>(
                tooltip: 'Account menu',
                offset: const Offset(0, 48),
                onSelected: (value) {
                  switch (value) {
                    case 'account':
                      onSelectRoute(WebShellRoute.account);
                    case 'reports':
                      onSelectRoute(WebShellRoute.reports);
                    case 'theme':
                      onToggleTheme();
                    case 'settings':
                      onOpenSettings();
                    case 'help':
                      onOpenHelp();
                    case 'signout':
                      onSignOut();
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem<String>(
                    enabled: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          style: theme.textTheme.labelLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${roleLabel ?? 'Surveyor'} · ${isVerified ? 'Verified' : 'Unverified'}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    value: 'account',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.person_outline_rounded, size: 18),
                      title: Text('Account & Security'),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'reports',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.assignment_outlined, size: 18),
                      title: Text('My Reports'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'theme',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 18,
                      ),
                      title: Text(
                        isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                      ),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'settings',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.tune_rounded, size: 18),
                      title: Text('Preferences & Map'),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'help',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.help_outline_rounded, size: 18),
                      title: Text('Help & Guide'),
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'signout',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.logout_rounded,
                        size: 18,
                        color: WebDesign.danger(isDark),
                      ),
                      title: Text(
                        'Sign Out',
                        style: TextStyle(
                          color: WebDesign.danger(isDark),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                child: Semantics(
                  button: true,
                  label: 'Open account menu for $displayName',
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: WebDesign.minTarget,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: WebDesign.space2,
                      vertical: WebDesign.space1,
                    ),
                    decoration: BoxDecoration(
                      color: activeRoute == WebShellRoute.account
                          ? WebDesign.brandWash(isDark)
                          : WebDesign.sunken(isDark),
                      borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                      border: Border.all(
                        color: activeRoute == WebShellRoute.account
                            ? WebDesign.brand(isDark)
                            : WebDesign.border(isDark),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 13,
                          backgroundColor: WebDesign.brand(isDark),
                          child: Text(
                            initials,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (!isNarrow) ...[
                          const SizedBox(width: WebDesign.space2),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: WebDesign.textPrimary(isDark),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: WebDesign.textSecondary(isDark),
                        ),
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

class _NavDestinationButton extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int? badgeCount;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _NavDestinationButton({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.badgeCount,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fg = selected
        ? WebDesign.brandOnSurface(isDark)
        : WebDesign.textSecondary(isDark);

    return Semantics(
      button: true,
      selected: selected,
      label: badgeCount != null ? '$label ($badgeCount)' : label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        child: Container(
          constraints: const BoxConstraints(minHeight: WebDesign.touchTarget),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? WebDesign.space2 : WebDesign.space3,
            vertical: WebDesign.space1,
          ),
          decoration: BoxDecoration(
            color: selected ? WebDesign.brandWash(isDark) : Colors.transparent,
            borderRadius: BorderRadius.circular(WebDesign.radiusSm),
            border: selected
                ? Border.all(
                    color: WebDesign.brand(isDark).withValues(alpha: 0.32),
                  )
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? activeIcon : icon, size: 17, color: fg),
              const SizedBox(width: WebDesign.space1 + 2),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (badgeCount != null && badgeCount! > 0) ...[
                const SizedBox(width: WebDesign.space1 + 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? WebDesign.brand(isDark)
                        : WebDesign.sunken(isDark),
                    borderRadius: BorderRadius.circular(WebDesign.radiusPill),
                    border: selected
                        ? null
                        : Border.all(color: WebDesign.border(isDark)),
                  ),
                  child: Text(
                    '$badgeCount',
                    style: WebDesign.tabular(
                      theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: selected
                            ? Colors.white
                            : WebDesign.textSecondary(isDark),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Defect class badge combining distinct icon shape, color indicator, name,
/// and DPWH classification code so hazard categories never depend solely on hue.
class WebDefectBadge extends StatelessWidget {
  final String defectName;
  final String? dpwhCode;
  final bool dense;

  const WebDefectBadge({
    super.key,
    required this.defectName,
    this.dpwhCode,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cls = DpwhStandards.classForReport({
      'primaryDefect': defectName,
      if (dpwhCode != null) 'primaryDpwhCode': dpwhCode,
    });
    final color = cls?.color ?? DpwhStandards.getClassColor(defectName);
    final icon = cls != null
        ? WebDesign.defectIcon(cls)
        : Icons.warning_amber_rounded;
    final code = cls?.code ?? dpwhCode ?? '';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? WebDesign.space2 : WebDesign.space2 + 2,
        vertical: dense ? 2 : WebDesign.space1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.45 : 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 12 : 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              code.isNotEmpty
                  ? '${cls?.name ?? defectName} · $code'
                  : defectName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: dense ? 10.5 : 11.5,
                color: isDark ? Colors.white : WebDesign.textPrimary(isDark),
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Severity chip combining icon shape + high-contrast text label.
class WebSeverityBadge extends StatelessWidget {
  final String severity;
  final bool dense;

  const WebSeverityBadge({
    super.key,
    required this.severity,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final style = WebDesign.severityStyle(severity, isDark);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? WebDesign.space2 : WebDesign.space2 + 2,
        vertical: dense ? 2 : WebDesign.space1,
      ),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: style.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: dense ? 12 : 13, color: style.fg),
          const SizedBox(width: 4),
          Text(
            style.label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: dense ? 10.5 : 11.5,
              color: style.fg,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact map key explaining defect classes (shape + color) and report statuses.
class WebMapLegendCard extends StatelessWidget {
  final VoidCallback? onClose;

  const WebMapLegendCard({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return WebCard(
      padding: const EdgeInsets.all(WebDesign.space3),
      elevated: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 270),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Eyebrow('MAP KEY · DEFECT TYPES')),
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Close map key',
                    icon: const Icon(Icons.close_rounded, size: 16),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: WebDesign.space2),
            for (final cls in DpwhStandards.allClasses) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: WebDesign.space1 + 2),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: cls.color.withValues(
                          alpha: isDark ? 0.24 : 0.14,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(color: cls.color, width: 1.5),
                      ),
                      child: Icon(
                        WebDesign.defectIcon(cls),
                        size: 13,
                        color: cls.color,
                      ),
                    ),
                    const SizedBox(width: WebDesign.space2),
                    Expanded(
                      child: Text(
                        cls.name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: WebDesign.textPrimary(isDark),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      cls.code,
                      style: WebDesign.tabular(
                        theme.textTheme.labelSmall?.copyWith(
                          color: WebDesign.textMuted(isDark),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: WebDesign.space4),
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 14,
                  color: WebDesign.statusStyle(StatusTone.approved, isDark).fg,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Approved: Verified public hazard',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 14,
                  color: WebDesign.statusStyle(StatusTone.pending, isDark).fg,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Pending: Your awaiting moderation',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Concise accessible help modal for search, filters, DPWH classes, and status rules.
class WebHelpDialog extends StatelessWidget {
  const WebHelpDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final maxH = MediaQuery.sizeOf(context).height * 0.84;

    return Dialog(
      insetPadding: const EdgeInsets.all(WebDesign.space4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(
                WebDesign.space5,
                WebDesign.space4,
                WebDesign.space3,
                WebDesign.space4,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: WebDesign.border(isDark)),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.help_outline_rounded,
                    color: WebDesign.brandOnSurface(isDark),
                  ),
                  const SizedBox(width: WebDesign.space2),
                  Expanded(
                    child: Text(
                      'RoadSense AI Web Guide',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close guide',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(WebDesign.space5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Eyebrow('SEARCH & FILTERS'),
                    const SizedBox(height: WebDesign.space2),
                    Text(
                      'Use the map search bar to find places across Bulacan, any of the 24 Santa Maria barangays, or specific road hazard reports by ID, defect class, barangay.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: WebDesign.space4),
                    const Eyebrow('4 SUPPORTED ROAD DEFECT CLASSES'),
                    const SizedBox(height: WebDesign.space2),
                    Wrap(
                      spacing: WebDesign.space2,
                      runSpacing: WebDesign.space2,
                      children: [
                        for (final cls in DpwhStandards.allClasses)
                          WebDefectBadge(
                            defectName: cls.name,
                            dpwhCode: cls.code,
                          ),
                      ],
                    ),
                    const SizedBox(height: WebDesign.space4),
                    const Eyebrow('AI DETECTION CONFIDENCE'),
                    const SizedBox(height: WebDesign.space2),
                    Text(
                      'AI confidence indicates how certain the detector is about the defect class. Reports are reviewed before appearing on the public map.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: WebDesign.space4),
                    const Eyebrow('REPORT STATUSES'),
                    const SizedBox(height: WebDesign.space2),
                    Text(
                      '• Approved: Verified by an administrator and visible to everyone on the map.\n'
                      '• Pending review: Awaiting moderation; only visible to you on the map and editable in My Reports.\n'
                      '• Rejected: Declined during review; remains visible in My Reports for your records.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: WebDesign.space5,
                vertical: WebDesign.space3,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: WebDesign.border(isDark)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Got it'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared hit target and activation feedback for web and admin map pins.
class WebMapMarkerButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Widget child;
  const WebMapMarkerButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: WebDesign.brand(dark).withValues(alpha: .1),
            focusColor: WebDesign.brand(dark).withValues(alpha: .2),
            onTap: onTap,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Shared widgets for the RoadSense web UI.
///
/// Web-only (see CLAUDE.md section 1). Every widget here draws its colours and
/// metrics from [WebDesign], so a token change lands everywhere at once instead
/// of needing 400-odd hex literals edited by hand.
library;

import 'package:flutter/material.dart';

import 'web_design.dart';

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
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  const SectionHeading({
    super.key,
    required this.title,
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

  const StatusChip({super.key, required this.tone, this.label, this.dense = false});

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

/// Segmented Map / Profile switcher plus a settings button.
///
/// One implementation for both surfaces. It previously existed twice — copied
/// between `web_map_screen.dart` and `web_profile_screen.dart` — so the two
/// copies were already drifting apart.
class WebViewSwitcher extends StatelessWidget {
  final bool isMapActive;
  final VoidCallback? onSelectMap;
  final VoidCallback? onSelectProfile;
  final VoidCallback onOpenSettings;

  const WebViewSwitcher({
    super.key,
    required this.isMapActive,
    required this.onOpenSettings,
    this.onSelectMap,
    this.onSelectProfile,
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
          _Segment(
            icon: Icons.person_rounded,
            label: 'Profile',
            selected: !isMapActive,
            onTap: isMapActive ? onSelectProfile : null,
          ),
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

    return MouseRegion(
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
            padding: const EdgeInsets.symmetric(
              horizontal: WebDesign.space3,
            ),
            decoration: BoxDecoration(
              color: selected ? WebDesign.brandWash(isDark) : Colors.transparent,
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
    );
  }
}

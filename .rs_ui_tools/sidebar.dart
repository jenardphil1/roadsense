  /// Left navigation rail.
  ///
  /// Items are grouped by job (monitor / moderate / administer) rather than one
  /// flat list. Nav indices are unchanged, so `_buildCurrentView` and `titles`
  /// still line up.
  Widget _buildWebSidebar(
    BuildContext context, {
    required bool isSuperAdmin,
    required int pendingCount,
    required int approvedCount,
    required int totalCount,
    required String role,
  }) {
    final user = CloudService.instance.currentUser;
    final displayName = user?.displayName ?? 'Admin account';
    final email = user?.email ?? '';
    final isDark = AppSettings.instance.isDarkMode;
    final text = Theme.of(context).textTheme;

    return Container(
      width: WebDesign.sidebarWidth,
      decoration: BoxDecoration(
        color: _surface(isDark),
        border: Border(right: BorderSide(color: _border(isDark))),
      ),
      child: Column(
        children: [
          // Brand lockup — same height as the header bar so the two align.
          Container(
            height: WebDesign.headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: WebDesign.space4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: _border(isDark))),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: WebDesign.brand(isDark),
                    borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                  ),
                  child: Icon(
                    Icons.add_road_rounded,
                    color: isDark ? const Color(0xFF06283D) : Colors.white,
                    size: WebDesign.iconSm,
                  ),
                ),
                const SizedBox(width: WebDesign.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'RoadSense',
                        style: text.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isSuperAdmin ? 'Super admin' : 'Admin portal',
                        style: text.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: WebDesign.space2,
                vertical: WebDesign.space3,
              ),
              children: [
                _navGroupLabel('Monitoring'),
                _buildNavItem(
                  index: 0,
                  icon: Icons.insights_outlined,
                  activeIcon: Icons.insights_rounded,
                  label: 'Overview',
                ),
                _buildNavItem(
                  index: 3,
                  icon: Icons.map_outlined,
                  activeIcon: Icons.map_rounded,
                  label: 'GIS map',
                  badgeCount: totalCount,
                  badgeTone: StatusTone.info,
                ),

                const SizedBox(height: WebDesign.space4),
                _navGroupLabel('Moderation'),
                _buildNavItem(
                  index: 1,
                  icon: Icons.inbox_outlined,
                  activeIcon: Icons.inbox_rounded,
                  label: 'Pending review',
                  badgeCount: pendingCount,
                  badgeTone: StatusTone.pending,
                ),
                _buildNavItem(
                  index: 2,
                  icon: Icons.verified_outlined,
                  activeIcon: Icons.verified_rounded,
                  label: 'Approved hazards',
                  badgeCount: approvedCount,
                  badgeTone: StatusTone.approved,
                ),

                if (isSuperAdmin) ...[
                  const SizedBox(height: WebDesign.space4),
                  _navGroupLabel('Administration'),
                  _buildNavItem(
                    index: 4,
                    icon: Icons.manage_accounts_outlined,
                    activeIcon: Icons.manage_accounts_rounded,
                    label: 'Users & export',
                  ),
                ],
              ],
            ),
          ),

          Divider(color: _border(isDark), height: 1),

          // Live sync indicator. Icon plus word, so it does not lean on the
          // dot's colour alone to say "connected".
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WebDesign.space4,
              WebDesign.space3,
              WebDesign.space4,
              WebDesign.space2,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_done_outlined,
                  size: WebDesign.iconXs,
                  color: WebDesign.statusStyle(StatusTone.approved, isDark).fg,
                ),
                const SizedBox(width: WebDesign.space2),
                const Expanded(child: Eyebrow('Cloud sync active')),
              ],
            ),
          ),

          // Account menu. Replaces the 16px icon-only sign-out button, which was
          // both an undersized target and unlabelled.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WebDesign.space2,
              0,
              WebDesign.space2,
              WebDesign.space3,
            ),
            child: _AccountMenuTile(
              displayName: displayName,
              email: email,
              role: role,
              isDark: isDark,
              onSignOut: () async => await CloudService.instance.signOut(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navGroupLabel(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        0,
        WebDesign.space3,
        WebDesign.space2,
      ),
      child: Eyebrow(label),
    );
  }

  /// One sidebar navigation row.
  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
    int? badgeCount,
    StatusTone badgeTone = StatusTone.neutral,
  }) {
    final isSelected = _selectedIndex == index;
    final isDark = AppSettings.instance.isDarkMode;
    final text = Theme.of(context).textTheme;

    final fg = isSelected
        ? WebDesign.brandOnSurface(isDark)
        : WebDesign.textSecondary(isDark);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(WebDesign.radiusSm),
          child: InkWell(
            borderRadius: BorderRadius.circular(WebDesign.radiusSm),
            onTap: () {
              setState(() => _selectedIndex = index);
              if (MediaQuery.of(context).size.width <
                  WebDesign.desktopBreakpoint) {
                Navigator.of(context).pop();
              }
            },
            child: AnimatedContainer(
              duration: WebDesign.fast,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: WebDesign.space3),
              decoration: BoxDecoration(
                color: isSelected
                    ? WebDesign.brandWash(isDark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(WebDesign.radiusSm),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected ? activeIcon : icon,
                    size: WebDesign.iconSm,
                    color: fg,
                  ),
                  const SizedBox(width: WebDesign.space3),
                  Expanded(
                    child: Text(
                      label,
                      style: text.labelLarge?.copyWith(
                        color: fg,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badgeCount != null && badgeCount > 0)
                    _navBadge(badgeCount, badgeTone, isDark, text),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navBadge(int count, StatusTone tone, bool isDark, TextTheme text) {
    final style = WebDesign.statusStyle(tone, isDark);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WebDesign.space2,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: style.outline),
      ),
      child: Text(
        '$count',
        style: WebDesign.tabular(
          text.labelSmall?.copyWith(
                color: style.fg,
                letterSpacing: 0,
                fontSize: 11,
              ) ??
              const TextStyle(),
        ),
      ),
    );
  }


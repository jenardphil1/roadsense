  /// Top header bar: where you are on the left, what you can do on the right.
  ///
  /// The old bar printed the same string twice — once as the breadcrumb tail and
  /// again as the page title — and left the right-hand side as an ungrouped pile
  /// of five controls. Here the breadcrumb carries a short section name, the
  /// title carries the full one, and the actions are grouped by kind.
  Widget _buildWebHeader(
    BuildContext context, {
    required bool isDesktop,
    required bool isSuperAdmin,
    required String role,
    required int pendingCount,
  }) {
    // (section, page title) per nav index.
    const sections = [
      ('Monitoring', 'Overview'),
      ('Moderation', 'Pending review'),
      ('Moderation', 'Approved hazards'),
      ('Monitoring', 'GIS map & inspection'),
      ('Administration', 'Users & data export'),
    ];

    final i = _selectedIndex.clamp(0, sections.length - 1);
    final section = sections[i].$1;
    final title = sections[i].$2;
    final isDark = AppSettings.instance.isDarkMode;
    final text = Theme.of(context).textTheme;
    final showSearch = _selectedIndex == 1 || _selectedIndex == 2;

    return Container(
      height: WebDesign.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: WebDesign.space5),
      decoration: BoxDecoration(
        color: _surface(isDark),
        border: Border(bottom: BorderSide(color: _border(isDark))),
      ),
      child: Row(
        children: [
          if (!isDesktop)
            Padding(
              padding: const EdgeInsets.only(right: WebDesign.space2),
              child: IconButton(
                icon: const Icon(Icons.menu_rounded),
                tooltip: 'Open navigation',
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),

          // Location. Breadcrumb names the section, the title names the page —
          // no longer the same words stacked on themselves.
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Eyebrow(section),
                const SizedBox(height: 1),
                Text(
                  title,
                  style: text.titleLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          const Spacer(),

          if (showSearch) ...[
            SizedBox(
              width: 280,
              child: TextField(
                controller: _searchController,
                style: text.bodyMedium?.copyWith(
                  color: WebDesign.textPrimary(isDark),
                ),
                decoration: InputDecoration(
                  hintText: 'Search reporter or coordinates',
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: WebDesign.iconSm,
                  ),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            size: WebDesign.iconXs,
                          ),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        ),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ),
            const SizedBox(width: WebDesign.space3),
          ],

          // Intake mode. One control, one tap target — the old version nested a
          // Switch inside an InkWell, so the row and the switch each fired the
          // same toggle and a click near the edge could feel dead.
          StreamBuilder<bool>(
            stream: CloudService.instance.streamAutoAcceptSetting(),
            builder: (context, autoSnapshot) {
              final isAutoAccept = autoSnapshot.data ?? false;
              final tone = isAutoAccept ? StatusTone.approved : StatusTone.info;
              final style = WebDesign.statusStyle(tone, isDark);

              return Tooltip(
                message: isAutoAccept
                    ? 'Auto-accept is on: new reports publish to the live map '
                          'immediately. Click to require review.'
                    : 'Manual review is on: new reports wait for approval '
                          'before reaching the live map. Click to auto-accept.',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                      onTap: () => _setAutoAccept(!isAutoAccept),
                      child: Container(
                        height: WebDesign.minTarget,
                        padding: const EdgeInsets.symmetric(
                          horizontal: WebDesign.space3,
                        ),
                        decoration: BoxDecoration(
                          color: style.bg,
                          borderRadius: BorderRadius.circular(
                            WebDesign.radiusSm,
                          ),
                          border: Border.all(color: style.outline),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isAutoAccept
                                  ? Icons.bolt_rounded
                                  : Icons.fact_check_outlined,
                              size: WebDesign.iconXs,
                              color: style.fg,
                            ),
                            const SizedBox(width: WebDesign.space2),
                            Text(
                              isAutoAccept ? 'Auto-accept' : 'Manual review',
                              style: text.labelMedium?.copyWith(
                                color: style.fg,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),

          const SizedBox(width: WebDesign.space3),
          Container(width: 1, height: 24, color: _border(isDark)),
          const SizedBox(width: WebDesign.space2),

          IconButton(
            tooltip: isDark ? 'Switch to light theme' : 'Switch to dark theme',
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: WebDesign.iconMd,
            ),
            onPressed: () {
              AppSettings.instance.toggleTheme(!isDark);
              setState(() {});
            },
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune_rounded, size: WebDesign.iconMd),
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) =>
                    WebSettingsDialog(onSettingsChanged: () => setState(() {})),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Flips the intake mode and confirms it in words, not an emoji.
  Future<void> _setAutoAccept(bool value) async {
    await CloudService.instance.setAutoAcceptSetting(value);
    if (!mounted) return;
    final isDark = AppSettings.instance.isDarkMode;
    ScaffoldMessenger.of(context).showSnackBar(
      WebDesign.snack(
        value
            ? 'Auto-accept enabled. New reports publish to the live map '
                  'immediately.'
            : 'Manual review enabled. New reports now wait for approval.',
        isDark: isDark,
        tone: value ? StatusTone.approved : StatusTone.info,
      ),
    );
  }


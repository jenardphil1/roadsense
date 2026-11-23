import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import 'dpwh_standards.dart';
import 'road_hazard_marker.dart';
import 'web_components.dart';
import 'web_design.dart';
import 'web_report_query.dart';

/// Suggestion entry combining matching cloud reports and geocoded/local places
/// so unified search clearly labels what each result represents.
class WebUnifiedSearchSuggestion {
  final bool isReport;
  final WebReportItem? report;
  final String? reportMatchReason;
  final Map<String, dynamic>? rawPlace;

  const WebUnifiedSearchSuggestion.report(this.report, {this.reportMatchReason})
    : isReport = true,
      rawPlace = null;

  const WebUnifiedSearchSuggestion.place(this.rawPlace)
    : isReport = false,
      report = null,
      reportMatchReason = null;
}

/// Persistent desktop left rail / mobile sheet workspace for searching places
/// and reports, filtering road defects, browsing synchronized results, and
/// inspecting full report details without jarring modal interruptions.
class WebMapWorkspacePanel extends StatelessWidget {
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchQuery;
  final bool isSearchingPlaces;
  final bool isSearchHistoryOpen;
  final List<WebUnifiedSearchSuggestion> unifiedSuggestions;
  final int highlightedSuggestionIndex;
  final List<Map<String, dynamic>> searchHistory;
  final Map<String, dynamic>? searchedPlace;
  final int nearbyPlaceHazardCount;
  final VoidCallback onClearSearchedPlace;
  final ValueChanged<LatLng> onDirectionsToPlace;

  final WebReportFilter filter;
  final ValueChanged<WebReportFilter> onFilterChanged;
  final bool isFilterDrawerOpen;
  final VoidCallback onToggleFilterDrawer;
  final VoidCallback onOpenBarangayPicker;

  final WebReportQueryResult queryResult;
  final int visibleResultLimit;
  final VoidCallback onLoadMoreResults;
  final WebReportItem? selectedReport;
  final ValueChanged<WebReportItem> onSelectReport;
  final VoidCallback onBackToResults;
  final String? currentUid;
  final bool isAdminUser;
  final bool hasUserLocation;
  final bool isCloudLoading;
  final String? cloudError;
  final VoidCallback onRetryCloud;

  final VoidCallback onOpenRoutePlanner;
  final Widget routePlannerContent;
  final bool isRoutePlanningMode;

  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSubmitSearch;
  final VoidCallback onClearSearch;
  final ValueChanged<WebUnifiedSearchSuggestion> onSelectSuggestion;
  final ValueChanged<Map<String, dynamic>> onSelectHistoryItem;
  final ValueChanged<int> onRemoveHistoryItem;
  final VoidCallback onClearHistory;
  final ValueChanged<int> onMoveSuggestionHighlight;

  final ValueChanged<WebReportItem> onCenterReportOnMap;
  final ValueChanged<String> onViewFullPhoto;
  final ValueChanged<WebReportItem>? onEditReport;
  final ValueChanged<WebReportItem>? onDeleteReport;
  final Future<void> Function(WebReportItem, String status)? onAdminModerate;
  final VoidCallback? onCollapsePanel;
  final VoidCallback? onEnableGps;

  const WebMapWorkspacePanel({
    super.key,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchQuery,
    required this.isSearchingPlaces,
    required this.isSearchHistoryOpen,
    required this.unifiedSuggestions,
    required this.highlightedSuggestionIndex,
    required this.searchHistory,
    required this.searchedPlace,
    required this.nearbyPlaceHazardCount,
    required this.onClearSearchedPlace,
    required this.onDirectionsToPlace,
    required this.filter,
    required this.onFilterChanged,
    required this.isFilterDrawerOpen,
    required this.onToggleFilterDrawer,
    required this.onOpenBarangayPicker,
    required this.queryResult,
    required this.visibleResultLimit,
    required this.onLoadMoreResults,
    required this.selectedReport,
    required this.onSelectReport,
    required this.onBackToResults,
    required this.currentUid,
    required this.isAdminUser,
    required this.hasUserLocation,
    required this.isCloudLoading,
    required this.cloudError,
    required this.onRetryCloud,
    required this.onOpenRoutePlanner,
    required this.routePlannerContent,
    required this.isRoutePlanningMode,
    required this.onSearchChanged,
    required this.onSubmitSearch,
    required this.onClearSearch,
    required this.onSelectSuggestion,
    required this.onSelectHistoryItem,
    required this.onRemoveHistoryItem,
    required this.onClearHistory,
    required this.onMoveSuggestionHighlight,
    required this.onCenterReportOnMap,
    required this.onViewFullPhoto,
    this.onEditReport,
    this.onDeleteReport,
    this.onAdminModerate,
    this.onCollapsePanel,
    this.onEnableGps,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (isRoutePlanningMode) {
      return Semantics(
        container: true,
        label: 'Route planner panel',
        child: Container(
          color: WebDesign.surface(isDark),
          child: SingleChildScrollView(child: routePlannerContent),
        ),
      );
    }

    if (selectedReport != null) {
      return Semantics(
        container: true,
        label: 'Road defect report details',
        child: WebReportDetailPanel(
          report: selectedReport!,
          currentUid: currentUid,
          isAdminUser: isAdminUser,
          onBack: onBackToResults,
          onCenterOnMap: () => onCenterReportOnMap(selectedReport!),
          onViewFullPhoto: () => onViewFullPhoto(selectedReport!.imageUrl),
          onEditReport: onEditReport != null
              ? () => onEditReport!(selectedReport!)
              : null,
          onDeleteReport: onDeleteReport != null
              ? () => onDeleteReport!(selectedReport!)
              : null,
          onAdminModerate: onAdminModerate != null
              ? (status) => onAdminModerate!(selectedReport!, status)
              : null,
        ),
      );
    }

    final hasDropdown =
        unifiedSuggestions.isNotEmpty ||
        (isSearchHistoryOpen &&
            searchController.text.trim().isEmpty &&
            searchHistory.isNotEmpty);

    return Semantics(
      container: true,
      label: 'Map search, filters, and road reports panel',
      child: Container(
        color: WebDesign.surface(isDark),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchHeader(context, isDark),
            if (hasDropdown)
              Flexible(
                fit: FlexFit.loose,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: unifiedSuggestions.isNotEmpty
                      ? _buildUnifiedSuggestionsList(context, isDark)
                      : _buildHistoryList(context, isDark),
                ),
              ),
            _buildFilterToolbar(context, isDark),
            if (isFilterDrawerOpen)
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 380),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      WebDesign.space3,
                      0,
                      WebDesign.space3,
                      WebDesign.space3,
                    ),
                    child: WebMapFilterControls(
                      filter: filter,
                      onChanged: onFilterChanged,
                      onOpenBarangayPicker: onOpenBarangayPicker,
                    ),
                  ),
                ),
              ),
            if (filter.hasAnyFilter) _buildActiveFilterChips(context, isDark),
            if (searchedPlace != null)
              _buildSearchedPlaceBanner(context, isDark),
            if (cloudError != null) _buildCloudErrorBanner(context, isDark),
            if (queryResult.nearestRequestedWithoutLocation)
              _buildNearestLocationNotice(context, isDark),
            Expanded(child: _buildResultsBody(context, isDark)),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchHeader(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        WebDesign.space3,
        WebDesign.space3,
        WebDesign.space2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: WebDesign.border(isDark))),
      ),
      child: Row(
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    onMoveSuggestionHighlight(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    onMoveSuggestionHighlight(-1),
                const SingleActivator(LogicalKeyboardKey.escape): onClearSearch,
              },
              child: Semantics(
                textField: true,
                label: 'Search places, barangays, or road reports',
                child: TextField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: WebDesign.textPrimary(isDark),
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search place, barangay, defect, or #ID',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSearchingPlaces)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        if (searchController.text.isNotEmpty)
                          IconButton(
                            onPressed: onClearSearch,
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded, size: 16),
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                      ],
                    ),
                  ),
                  onChanged: onSearchChanged,
                  onSubmitted: (_) {
                    if (highlightedSuggestionIndex >= 0 &&
                        highlightedSuggestionIndex <
                            unifiedSuggestions.length) {
                      onSelectSuggestion(
                        unifiedSuggestions[highlightedSuggestionIndex],
                      );
                    } else {
                      onSubmitSearch();
                    }
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: WebDesign.space1 + 2),
          Tooltip(
            message: 'Directions / Plan Route',
            child: OutlinedButton(
              onPressed: onOpenRoutePlanner,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(
                  WebDesign.touchTarget,
                  WebDesign.touchTarget,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Icon(Icons.directions_rounded, size: 19),
            ),
          ),
          if (onCollapsePanel != null) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onCollapsePanel,
              tooltip: 'Hide side panel',
              icon: const Icon(Icons.chevron_left_rounded),
              constraints: const BoxConstraints(
                minWidth: WebDesign.minTarget,
                minHeight: WebDesign.minTarget,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUnifiedSuggestionsList(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final reportSuggestions = <({int idx, WebUnifiedSearchSuggestion item})>[];
    final placeSuggestions = <({int idx, WebUnifiedSearchSuggestion item})>[];
    for (int i = 0; i < unifiedSuggestions.length; i++) {
      final s = unifiedSuggestions[i];
      if (s.isReport) {
        reportSuggestions.add((idx: i, item: s));
      } else {
        placeSuggestions.add((idx: i, item: s));
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        border: Border(bottom: BorderSide(color: WebDesign.border(isDark))),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: WebDesign.space2),
        children: [
          if (reportSuggestions.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(
                WebDesign.space3,
                WebDesign.space1,
                WebDesign.space3,
                WebDesign.space1,
              ),
              child: Eyebrow('MATCHING ROAD REPORTS'),
            ),
            for (final entry in reportSuggestions)
              _buildSuggestionTile(
                context,
                isDark,
                entry.item,
                highlighted: entry.idx == highlightedSuggestionIndex,
                theme: theme,
              ),
          ],
          if (placeSuggestions.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(
                WebDesign.space3,
                WebDesign.space2,
                WebDesign.space3,
                WebDesign.space1,
              ),
              child: Eyebrow('PLACES & BARANGAYS'),
            ),
            for (final entry in placeSuggestions)
              _buildSuggestionTile(
                context,
                isDark,
                entry.item,
                highlighted: entry.idx == highlightedSuggestionIndex,
                theme: theme,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestionTile(
    BuildContext context,
    bool isDark,
    WebUnifiedSearchSuggestion suggestion, {
    required bool highlighted,
    required ThemeData theme,
  }) {
    final bg = highlighted ? WebDesign.brandWash(isDark) : Colors.transparent;
    if (suggestion.isReport && suggestion.report != null) {
      final r = suggestion.report!;
      return Material(
        color: bg,
        child: InkWell(
          onTap: () => onSelectSuggestion(suggestion),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WebDesign.space3,
              vertical: WebDesign.space2,
            ),
            child: Row(
              children: [
                RoadDefectGlyph(
                  classId: DpwhStandards.classifyByName(r.primaryDefect).classId,
                  size: 20,
                  color: DpwhStandards.getClassColor(r.primaryDefect),
                ),
                const SizedBox(width: WebDesign.space2 + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${r.primaryDefect} · #${r.shortId}',
                        style: theme.textTheme.labelLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${r.locationLabel} · ${suggestion.reportMatchReason ?? r.primaryDpwhCode}',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                StatusChip.fromStatus(r.normalizedStatus, dense: true),
              ],
            ),
          ),
        ),
      );
    }

    final place = suggestion.rawPlace ?? const <String, dynamic>{};
    final name = (place['_name'] ?? place['display_name'] ?? 'Place')
        .toString();
    final shortAddr = (place['_short_addr'] ?? '').toString();
    final isBarangay =
        place['_is_barangay'] == true ||
        name.toLowerCase().contains('barangay');

    return Material(
      color: bg,
      child: InkWell(
        onTap: () => onSelectSuggestion(suggestion),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: WebDesign.space3,
            vertical: WebDesign.space2,
          ),
          child: Row(
            children: [
              Icon(
                isBarangay ? Icons.location_city_rounded : Icons.place_outlined,
                size: 18,
                color: WebDesign.brandOnSurface(isDark),
              ),
              const SizedBox(width: WebDesign.space2 + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: theme.textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (shortAddr.isNotEmpty)
                      Text(
                        shortAddr,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (isBarangay)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: WebDesign.brandWash(isDark),
                    borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                  ),
                  child: Text(
                    'Barangay',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: WebDesign.brandOnSurface(isDark),
                      letterSpacing: 0,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryList(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        border: Border(bottom: BorderSide(color: WebDesign.border(isDark))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WebDesign.space3,
              WebDesign.space2,
              WebDesign.space2,
              WebDesign.space1,
            ),
            child: Row(
              children: [
                const Expanded(child: Eyebrow('RECENT SEARCHES')),
                TextButton(
                  onPressed: onClearHistory,
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: searchHistory.length,
              itemBuilder: (ctx, i) {
                final item = searchHistory[i];
                final name = (item['name'] ?? '').toString();
                final addr = (item['address'] ?? '').toString();
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.history_rounded, size: 18),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                  subtitle: addr.isNotEmpty
                      ? Text(addr, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    tooltip: 'Remove from recent searches',
                    onPressed: () => onRemoveHistoryItem(i),
                  ),
                  onTap: () => onSelectHistoryItem(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterToolbar(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final activeCount = filter.activeFilterCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        WebDesign.space2,
        WebDesign.space3,
        WebDesign.space2,
      ),
      child: Wrap(
        spacing: WebDesign.space2,
        runSpacing: WebDesign.space2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: onToggleFilterDrawer,
            style: OutlinedButton.styleFrom(
              backgroundColor: (isFilterDrawerOpen || activeCount > 0)
                  ? WebDesign.brandWash(isDark)
                  : null,
              foregroundColor: (isFilterDrawerOpen || activeCount > 0)
                  ? WebDesign.brandOnSurface(isDark)
                  : WebDesign.textPrimary(isDark),
              side: BorderSide(
                color: (isFilterDrawerOpen || activeCount > 0)
                    ? WebDesign.brand(isDark)
                    : WebDesign.border(isDark),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: const Icon(Icons.filter_list_rounded, size: 17),
            label: Text(activeCount > 0 ? 'Filters ($activeCount)' : 'Filters'),
          ),
          FilterChip(
            label: const Text('In map area'),
            selected: filter.onlyInMapBounds,
            onSelected: (v) =>
                onFilterChanged(filter.copyWith(onlyInMapBounds: v)),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 138),
            child: DropdownButtonHideUnderline(
              child: Semantics(
                label: 'Sort road reports',
                child: Container(
                  height: WebDesign.minTarget,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: WebDesign.sunken(isDark),
                    borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                    border: Border.all(color: WebDesign.border(isDark)),
                  ),
                  child: DropdownButton<WebReportSort>(
                    value: filter.sort,
                    isDense: true,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: WebDesign.textPrimary(isDark),
                    ),
                    dropdownColor: WebDesign.surface(isDark),
                    items: const [
                      DropdownMenuItem(
                        value: WebReportSort.newest,
                        child: Text('Newest first'),
                      ),
                      DropdownMenuItem(
                        value: WebReportSort.oldest,
                        child: Text('Oldest first'),
                      ),
                      DropdownMenuItem(
                        value: WebReportSort.nearest,
                        child: Text('Nearest first'),
                      ),
                    ],
                    onChanged: (next) {
                      if (next != null) {
                        onFilterChanged(filter.copyWith(sort: next));
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveFilterChips(BuildContext context, bool isDark) {
    final chips = <Widget>[];
    for (final cls in filter.defectClasses) {
      chips.add(
        InputChip(
          label: Text(cls),
          onDeleted: () {
            final next = Set<String>.from(filter.defectClasses)..remove(cls);
            onFilterChanged(filter.copyWith(defectClasses: next));
          },
        ),
      );
    }
    for (final st in filter.statuses) {
      chips.add(
        InputChip(
          label: Text('Status: $st'),
          onDeleted: () {
            final next = Set<String>.from(filter.statuses)..remove(st);
            onFilterChanged(filter.copyWith(statuses: next));
          },
        ),
      );
    }
    for (final key in filter.barangayKeys) {
      final match = santaMariaBarangayCatalog.where((b) => b.key == key);
      final label = match.isNotEmpty ? 'Brgy. ${match.first.name}' : key;
      chips.add(
        InputChip(
          label: Text(label),
          onDeleted: () {
            final next = Set<String>.from(filter.barangayKeys)..remove(key);
            onFilterChanged(filter.copyWith(barangayKeys: next));
          },
        ),
      );
    }
    if (filter.datePreset != WebDateRangePreset.all) {
      final label = switch (filter.datePreset) {
        WebDateRangePreset.last24h => 'Last 24h',
        WebDateRangePreset.last7d => 'Last 7 days',
        WebDateRangePreset.last30d => 'Last 30 days',
        WebDateRangePreset.custom => 'Custom dates',
        WebDateRangePreset.all => '',
      };
      chips.add(
        InputChip(
          label: Text(label),
          onDeleted: () => onFilterChanged(
            filter.copyWith(
              datePreset: WebDateRangePreset.all,
              clearCustomDates: true,
            ),
          ),
        ),
      );
    }
    if (filter.onlyInMapBounds) {
      chips.add(
        InputChip(
          label: const Text('Visible map area'),
          onDeleted: () =>
              onFilterChanged(filter.copyWith(onlyInMapBounds: false)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        0,
        WebDesign.space3,
        WebDesign.space2,
      ),
      child: Wrap(
        spacing: WebDesign.space1 + 2,
        runSpacing: WebDesign.space1 + 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...chips,
          TextButton(
            onPressed: () => onFilterChanged(filter.clearAll()),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchedPlaceBanner(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final place = searchedPlace!;
    final name = (place['name'] ?? 'Selected Location').toString();
    final address = (place['address'] ?? '').toString();
    final loc = place['location'] as LatLng?;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        0,
        WebDesign.space3,
        WebDesign.space2,
      ),
      child: WebCard(
        padding: const EdgeInsets.all(WebDesign.space3),
        accentBorder: WebDesign.brand(isDark).withValues(alpha: 0.45),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.place_rounded,
                  size: 18,
                  color: WebDesign.brandOnSurface(isDark),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: onClearSearchedPlace,
                  tooltip: 'Dismiss selected place',
                  icon: const Icon(Icons.close_rounded, size: 16),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),
            if (address.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                address,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: WebDesign.space2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$nearbyPlaceHazardCount reported hazard(s) within 1 km',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: WebDesign.textSecondary(isDark),
                    ),
                  ),
                ),
                if (loc != null)
                  OutlinedButton.icon(
                    onPressed: () => onDirectionsToPlace(loc),
                    icon: const Icon(Icons.directions_rounded, size: 16),
                    label: const Text('Directions'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudErrorBanner(BuildContext context, bool isDark) {
    final style = WebDesign.statusStyle(StatusTone.rejected, isDark);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        0,
        WebDesign.space3,
        WebDesign.space2,
      ),
      child: WebCard(
        padding: const EdgeInsets.all(WebDesign.space3),
        accentBorder: style.outline,
        child: Row(
          children: [
            Icon(style.icon, color: style.fg, size: 18),
            const SizedBox(width: WebDesign.space2),
            Expanded(
              child: Text(
                'Unable to refresh cloud reports: $cloudError',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: WebDesign.textPrimary(isDark),
                ),
              ),
            ),
            TextButton(onPressed: onRetryCloud, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildNearestLocationNotice(BuildContext context, bool isDark) {
    final info = WebDesign.statusStyle(StatusTone.info, isDark);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WebDesign.space3,
        0,
        WebDesign.space3,
        WebDesign.space2,
      ),
      child: Container(
        padding: const EdgeInsets.all(WebDesign.space2 + 2),
        decoration: BoxDecoration(
          color: info.bg,
          borderRadius: BorderRadius.circular(WebDesign.radiusSm),
          border: Border.all(color: info.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.my_location_rounded, size: 16, color: info.fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasUserLocation
                        ? 'Sorted by distance from your GPS position.'
                        : 'Your GPS location is off. Enable location or select a place so Nearest can sort from your position.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: WebDesign.textPrimary(isDark),
                    ),
                  ),
                ),
              ],
            ),
            if (!hasUserLocation && onEnableGps != null) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('web_enable_gps_button'),
                onPressed: onEnableGps,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                icon: const Icon(Icons.my_location_rounded, size: 15),
                label: const Text('Enable GPS'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultsBody(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    if (isCloudLoading && queryResult.totalDatasetCount == 0) {
      return const Center(child: CircularProgressIndicator());
    }

    final items = queryResult.items;
    final totalLoaded = queryResult.totalDatasetCount;

    if (items.isEmpty) {
      final hasQueryOrFilter =
          searchQuery.trim().isNotEmpty || filter.hasAnyFilter;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(WebDesign.space4),
        child: EmptyState(
          icon: hasQueryOrFilter
              ? Icons.filter_alt_off_outlined
              : Icons.map_outlined,
          title: hasQueryOrFilter
              ? 'No matching road reports'
              : 'No road reports loaded yet',
          message: hasQueryOrFilter
              ? 'No road defect reports match the current search or active filters.'
              : 'Approved public hazard reports and your pending submissions will appear here automatically.',
          action: hasQueryOrFilter
              ? Wrap(
                  spacing: WebDesign.space2,
                  children: [
                    if (filter.hasAnyFilter)
                      OutlinedButton(
                        onPressed: () => onFilterChanged(filter.clearAll()),
                        child: const Text('Reset filters'),
                      ),
                    if (searchQuery.trim().isNotEmpty)
                      ElevatedButton(
                        onPressed: onClearSearch,
                        child: const Text('Clear search'),
                      ),
                  ],
                )
              : null,
        ),
      );
    }

    final displayed = items.take(visibleResultLimit).toList(growable: false);
    final hasMore = items.length > displayed.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: WebDesign.space3,
            vertical: WebDesign.space2,
          ),
          decoration: BoxDecoration(
            color: WebDesign.sunken(isDark),
            border: Border(
              top: BorderSide(color: WebDesign.border(isDark)),
              bottom: BorderSide(color: WebDesign.border(isDark)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Showing ${displayed.length} of ${items.length} matching ($totalLoaded loaded)',
                  style: WebDesign.tabular(theme.textTheme.labelMedium),
                ),
              ),
              Text('Client index', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(WebDesign.space3),
            itemCount: displayed.length + (hasMore ? 1 : 0),
            separatorBuilder: (_, _) =>
                const SizedBox(height: WebDesign.space2),
            itemBuilder: (ctx, i) {
              if (i >= displayed.length) {
                final remaining = items.length - displayed.length;
                return OutlinedButton(
                  onPressed: onLoadMoreResults,
                  child: Text('Show more ($remaining remaining)'),
                );
              }
              final item = displayed[i];
              return WebReportSummaryCard(
                report: item,
                isSelected: selectedReport?.docId == item.docId,
                onTap: () => onSelectReport(item),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Filter controls card with Defect Class (4 active classes), Status,
/// Searchable Santa Maria Barangay picker, Severity, and Date Range.
class WebMapFilterControls extends StatelessWidget {
  final WebReportFilter filter;
  final ValueChanged<WebReportFilter> onChanged;
  final VoidCallback onOpenBarangayPicker;

  const WebMapFilterControls({
    super.key,
    required this.filter,
    required this.onChanged,
    required this.onOpenBarangayPicker,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return WebCard(
      padding: const EdgeInsets.all(WebDesign.space3),
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Eyebrow('DEFECT TYPE (4 ACTIVE CLASSES)')),
              if (filter.hasAnyFilter)
                TextButton(
                  onPressed: () => onChanged(filter.clearAll()),
                  child: const Text('Clear all'),
                ),
            ],
          ),
          const SizedBox(height: WebDesign.space1 + 2),
          Wrap(
            spacing: WebDesign.space1 + 2,
            runSpacing: WebDesign.space1 + 2,
            children: [
              for (final cls in DpwhStandards.allClasses)
                FilterChip(
                  avatar: RoadDefectGlyph(
                    classId: cls.classId,
                    size: 16,
                    color: cls.color,
                  ),
                  label: Text(cls.name),
                  selected: filter.defectClasses.contains(cls.name),
                  onSelected: (selected) {
                    final next = Set<String>.from(filter.defectClasses);
                    if (selected) {
                      next.add(cls.name);
                    } else {
                      next.remove(cls.name);
                    }
                    onChanged(filter.copyWith(defectClasses: next));
                  },
                ),
            ],
          ),
          const SizedBox(height: WebDesign.space3),
          const Eyebrow('STATUS'),
          const SizedBox(height: WebDesign.space1 + 2),
          Wrap(
            spacing: WebDesign.space1 + 2,
            runSpacing: WebDesign.space1 + 2,
            children: [
              for (final st in const [
                ('approved', 'Approved'),
                ('pending', 'Pending review'),
              ])
                FilterChip(
                  label: Text(st.$2),
                  selected: filter.statuses.contains(st.$1),
                  onSelected: (selected) {
                    final next = Set<String>.from(filter.statuses);
                    if (selected) {
                      next.add(st.$1);
                    } else {
                      next.remove(st.$1);
                    }
                    onChanged(filter.copyWith(statuses: next));
                  },
                ),
            ],
          ),
          const SizedBox(height: WebDesign.space3),
          const Eyebrow('SANTA MARIA, BULACAN BARANGAY'),
          const SizedBox(height: WebDesign.space1 + 2),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onOpenBarangayPicker,
                  icon: const Icon(Icons.location_city_rounded, size: 16),
                  label: Text(
                    filter.barangayKeys.isEmpty
                        ? 'All 24 Santa Maria barangays'
                        : '${filter.barangayKeys.length} barangay(s) selected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (filter.barangayKeys.isNotEmpty) ...[
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () =>
                      onChanged(filter.copyWith(barangayKeys: const {})),
                  tooltip: 'Clear barangay filter',
                  icon: const Icon(Icons.clear_rounded, size: 17),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Scope: 24 official barangays of Santa Maria, Bulacan.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: WebDesign.textMuted(isDark),
            ),
          ),
          const SizedBox(height: WebDesign.space3),
          const Eyebrow('REPORTED DATE'),
          const SizedBox(height: WebDesign.space1 + 2),
          Wrap(
            spacing: WebDesign.space1 + 2,
            runSpacing: WebDesign.space1 + 2,
            children: [
              for (final preset in const [
                (WebDateRangePreset.all, 'Any time'),
                (WebDateRangePreset.last24h, '24 hours'),
                (WebDateRangePreset.last7d, '7 days'),
                (WebDateRangePreset.last30d, '30 days'),
              ])
                ChoiceChip(
                  label: Text(preset.$2),
                  selected: filter.datePreset == preset.$1,
                  onSelected: (_) => onChanged(
                    filter.copyWith(
                      datePreset: preset.$1,
                      clearCustomDates: preset.$1 != WebDateRangePreset.custom,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Synchronized card representing one report in the map side rail or sheet.
class WebReportSummaryCard extends StatelessWidget {
  final WebReportItem report;
  final bool isSelected;
  final VoidCallback onTap;

  const WebReportSummaryCard({
    super.key,
    required this.report,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Semantics(
      button: true,
      selected: isSelected,
      label: '${report.primaryDefect}, ${report.locationLabel}',
      child: Material(
        color: isSelected
            ? WebDesign.brandWash(isDark)
            : WebDesign.surface(isDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WebDesign.radiusMd),
          side: BorderSide(
            color: isSelected
                ? WebDesign.brand(isDark)
                : WebDesign.border(isDark),
            width: isSelected ? 1.8 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(WebDesign.radiusMd),
          child: Padding(
            padding: const EdgeInsets.all(WebDesign.space3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ThumbnailPreview(imageUrl: report.imageUrl, size: 58),
                const SizedBox(width: WebDesign.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: WebDefectBadge(
                              defectName: report.primaryDefect,
                              dpwhCode: report.primaryDpwhCode,
                              dense: true,
                            ),
                          ),
                          const SizedBox(width: 6),
                          StatusChip.fromStatus(
                            report.normalizedStatus,
                            dense: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        report.locationLabel,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: WebDesign.space2,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            WebReportQueryEngine.formatTimestamp(
                              report.timestamp,
                            ),
                            style: WebDesign.tabular(theme.textTheme.bodySmall),
                          ),
                        ],
                      ),
                    ],
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

/// Inline predictable report inspection view docked inside the panel or mobile
/// sheet so inspecting a report never covers the map unnecessarily.
class WebReportDetailPanel extends StatelessWidget {
  final WebReportItem report;
  final String? currentUid;
  final bool isAdminUser;
  final VoidCallback onBack;
  final VoidCallback onCenterOnMap;
  final VoidCallback onViewFullPhoto;
  final VoidCallback? onEditReport;
  final VoidCallback? onDeleteReport;
  final Future<void> Function(String status)? onAdminModerate;

  const WebReportDetailPanel({
    super.key,
    required this.report,
    required this.currentUid,
    required this.isAdminUser,
    required this.onBack,
    required this.onCenterOnMap,
    required this.onViewFullPhoto,
    this.onEditReport,
    this.onDeleteReport,
    this.onAdminModerate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final canOwnerManage =
        currentUid != null &&
        currentUid!.isNotEmpty &&
        report.reporterUid == currentUid &&
        report.normalizedStatus == 'pending';

    return Container(
      color: WebDesign.surface(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Back bar
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: WebDesign.space2,
              vertical: WebDesign.space2,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: WebDesign.border(isDark)),
              ),
            ),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Back to results'),
                ),
                const Spacer(),
                if (report.docId.isNotEmpty)
                  Text(
                    '#${report.shortId}',
                    style: WebDesign.tabular(
                      theme.textTheme.labelMedium?.copyWith(
                        color: WebDesign.textMuted(isDark),
                      ),
                    ),
                  ),
                const SizedBox(width: WebDesign.space2),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(WebDesign.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: WebDesign.space2,
                    runSpacing: WebDesign.space2,
                    children: [
                      WebDefectBadge(
                        defectName: report.primaryDefect,
                        dpwhCode: report.primaryDpwhCode,
                      ),
                      StatusChip.fromStatus(report.normalizedStatus),
                    ],
                  ),
                  const SizedBox(height: WebDesign.space3),
                  Text(
                    report.locationLabel,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Reported ${WebReportQueryEngine.formatTimestamp(report.timestamp)} · ${report.publicAttribution(currentUid)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: WebDesign.space3),
                  // Photo viewer card
                  _DetailPhotoBox(
                    imageUrl: report.imageUrl,
                    onTapFullPhoto: onViewFullPhoto,
                  ),
                  const SizedBox(height: WebDesign.space3),
                  // Primary action
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onCenterOnMap,
                      icon: const Icon(
                        Icons.center_focus_strong_rounded,
                        size: 17,
                      ),
                      label: const Text('Center map'),
                    ),
                  ),
                  if (report.normalizedStatus == 'rejected' &&
                      report.rejectionReason.trim().isNotEmpty) ...[
                    const SizedBox(height: WebDesign.space3),
                    WebCard(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      elevated: false,
                      accentBorder: WebDesign.statusStyle(
                        StatusTone.rejected,
                        isDark,
                      ).outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Eyebrow('MODERATION REASON'),
                          const SizedBox(height: 4),
                          Text(
                            report.rejectionReason.trim(),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: WebDesign.textPrimary(isDark),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: WebDesign.space4),
                  // Coordinates & Cluster summary
                  WebCard(
                    padding: const EdgeInsets.all(WebDesign.space3),
                    elevated: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Eyebrow('LOCATION & INSPECTION METADATA'),
                        const SizedBox(height: WebDesign.space2),
                        CoordinatePill(
                          latitude: report.location.latitude,
                          longitude: report.location.longitude,
                        ),
                        const SizedBox(height: WebDesign.space2),
                        _kvRow(
                          context,
                          'Defect count',
                          report.potholeCount > 1
                              ? '${report.potholeCount} defects in report'
                              : '1 defect recorded',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: WebDesign.space3),
                  // DPWH Guidelines
                  WebCard(
                    padding: const EdgeInsets.all(WebDesign.space3),
                    elevated: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Eyebrow('RECOMMENDED ACTION'),
                        const SizedBox(height: WebDesign.space2),
                        Text(
                          report.correctiveMeasure,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: WebDesign.textPrimary(isDark),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (report.detections.isNotEmpty) ...[
                    const SizedBox(height: WebDesign.space3),
                    WebCard(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      elevated: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Eyebrow(
                            'AI MODEL DETECTIONS (${report.detections.length})',
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Confidence reflects how certain the detector is about the defect class.',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: WebDesign.space2),
                          for (final det in report.detections)
                            _DetectionBreakdownRow(detection: det),
                        ],
                      ),
                    ),
                  ],
                  if (canOwnerManage &&
                      (onEditReport != null || onDeleteReport != null)) ...[
                    const SizedBox(height: WebDesign.space4),
                    const Eyebrow('MANAGE YOUR PENDING REPORT'),
                    const SizedBox(height: WebDesign.space2),
                    Row(
                      children: [
                        if (onEditReport != null)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: onEditReport,
                              icon: const Icon(Icons.edit_outlined, size: 17),
                              label: const Text('Edit'),
                            ),
                          ),
                        if (onEditReport != null && onDeleteReport != null)
                          const SizedBox(width: WebDesign.space2),
                        if (onDeleteReport != null)
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: WebDesign.danger(isDark),
                                side: BorderSide(
                                  color: WebDesign.danger(
                                    isDark,
                                  ).withValues(alpha: 0.45),
                                ),
                              ),
                              onPressed: onDeleteReport,
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 17,
                              ),
                              label: const Text('Move to Trash'),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (isAdminUser && onAdminModerate != null) ...[
                    const SizedBox(height: WebDesign.space4),
                    const Eyebrow('MODERATOR ACTIONS'),
                    const SizedBox(height: WebDesign.space2),
                    Row(
                      children: [
                        if (report.normalizedStatus != 'approved')
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: WebDesign.approveAction,
                              ),
                              onPressed: () => onAdminModerate!('approved'),
                              icon: const Icon(Icons.check_rounded, size: 17),
                              label: const Text('Approve'),
                            ),
                          ),
                        if (report.normalizedStatus != 'approved' &&
                            report.normalizedStatus != 'rejected')
                          const SizedBox(width: WebDesign.space2),
                        if (report.normalizedStatus != 'rejected')
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => onAdminModerate!('rejected'),
                              icon: const Icon(Icons.close_rounded, size: 17),
                              label: const Text('Reject'),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(BuildContext context, String k, String v) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(k, style: theme.textTheme.bodySmall)),
        Text(
          v,
          style: theme.textTheme.labelMedium?.copyWith(
            color: WebDesign.textPrimary(theme.brightness == Brightness.dark),
          ),
        ),
      ],
    );
  }
}

class _DetectionBreakdownRow extends StatelessWidget {
  final Map<String, dynamic> detection;

  const _DetectionBreakdownRow({required this.detection});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rawName =
        (detection['className'] ??
                detection['class'] ??
                detection['label'] ??
                detection['defect'] ??
                'Distress')
            .toString();
    final cls =
        DpwhStandards.activeClassForDetection(detection) ??
        DpwhStandards.classifyByName(rawName);
    final conf = (detection['confidence'] as num?)?.toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          RoadDefectGlyph(
            classId: cls.classId,
            size: 17,
            color: cls.color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${cls.name} (${cls.code})',
              style: theme.textTheme.bodySmall?.copyWith(
                color: WebDesign.textPrimary(
                  theme.brightness == Brightness.dark,
                ),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            conf != null
                ? '${WebReportQueryEngine.formatConfidence(conf)} AI confidence'
                : 'Confidence unavailable',
            style: WebDesign.tabular(theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _DetailPhotoBox extends StatelessWidget {
  final String imageUrl;
  final VoidCallback onTapFullPhoto;

  const _DetailPhotoBox({required this.imageUrl, required this.onTapFullPhoto});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasUrl = imageUrl.startsWith('http');

    return Container(
      height: 190,
      width: double.infinity,
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      clipBehavior: Clip.antiAlias,
      child: !hasUrl
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_not_supported_outlined,
                    size: 32,
                    color: WebDesign.textMuted(isDark),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'No photo attached to this report',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                Semantics(
                  button: true,
                  label: 'Open full-size road defect photo',
                  child: InkWell(
                    onTap: onTapFullPhoto,
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      loadingBuilder: (ctx, child, progress) {
                        if (progress == null) return child;
                        return const Center(child: CircularProgressIndicator());
                      },
                      errorBuilder: (_, _, _) => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image_outlined,
                              size: 32,
                              color: WebDesign.textMuted(isDark),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Image failed to load',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: WebDesign.space2,
                  bottom: WebDesign.space2,
                  child: ElevatedButton.icon(
                    onPressed: onTapFullPhoto,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.72),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    icon: const Icon(Icons.open_in_full_rounded, size: 15),
                    label: const Text('View full photo'),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ThumbnailPreview extends StatelessWidget {
  final String imageUrl;
  final double size;

  const _ThumbnailPreview({required this.imageUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: WebDesign.sunken(isDark),
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        border: Border.all(color: WebDesign.border(isDark)),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl.startsWith('http')
          ? Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.broken_image_outlined,
                size: 20,
                color: WebDesign.textMuted(isDark),
              ),
            )
          : Icon(
              Icons.add_road_rounded,
              size: 22,
              color: WebDesign.textMuted(isDark),
            ),
    );
  }
}

/// Searchable modal dialog letting users select one or more of the 24
/// official barangays of Santa Maria, Bulacan cleanly without duplicate names.
class SantaMariaBarangayPickerDialog extends StatefulWidget {
  final Set<String> initialSelection;

  const SantaMariaBarangayPickerDialog({
    super.key,
    required this.initialSelection,
  });

  @override
  State<SantaMariaBarangayPickerDialog> createState() =>
      _SantaMariaBarangayPickerDialogState();
}

class _SantaMariaBarangayPickerDialogState
    extends State<SantaMariaBarangayPickerDialog> {
  final TextEditingController _search = TextEditingController();
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelection);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final query = WebReportQueryEngine.normalizeSearchText(_search.text);
    final filtered = santaMariaBarangayCatalog
        .where((b) {
          if (query.isEmpty) return true;
          return b.key.contains(query) || b.name.toLowerCase().contains(query);
        })
        .toList(growable: false);

    return Dialog(
      insetPadding: const EdgeInsets.all(WebDesign.space4),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(
                WebDesign.space4,
                WebDesign.space3,
                WebDesign.space2,
                WebDesign.space3,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: WebDesign.border(isDark)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Santa Maria, Bulacan Barangays',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Select one or more of the 24 official barangays.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close picker',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(WebDesign.space3),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Filter barangays (e.g. Poblacion, Bulac...)',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () => setState(() => _search.clear()),
                          tooltip: 'Clear barangay search',
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(WebDesign.space4),
                      child: EmptyState(
                        icon: Icons.location_off_outlined,
                        title: 'No matching barangay',
                        message:
                            'No official Santa Maria barangay matched "${_search.text.trim()}".',
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (ctx, i) {
                        final entry = filtered[i];
                        final checked = _selected.contains(entry.key);
                        return CheckboxListTile(
                          value: checked,
                          dense: true,
                          title: Text('Barangay ${entry.name}'),
                          subtitle: const Text('Santa Maria, Bulacan'),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(entry.key);
                              } else {
                                _selected.remove(entry.key);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: WebDesign.space4,
                vertical: WebDesign.space3,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: WebDesign.border(isDark)),
                ),
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: WebDesign.space2,
                  runSpacing: WebDesign.space2,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => setState(() => _selected.clear()),
                      child: const Text('Clear all'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(_selected),
                      child: Text('Apply (${_selected.length})'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

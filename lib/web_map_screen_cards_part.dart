part of 'web_map_screen.dart';

extension _WebMapScreenCards on MapScreenState {
  Widget _buildRouteSummaryInPlanner({
    required bool isDark,
    required bool isClearAhead,
    required String distStr,
    required String totalEtaStr,
    required int activePotholeCount,
  }) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);
    final RouteComparisonResult? comparison = _routeComparison;
    final RouteHazardSummary? activeSummary =
        _activeRouteIndex?.summary ??
        (comparison != null && _selectedRouteIndex < comparison.options.length
            ? comparison.options[_selectedRouteIndex].summary
            : null);
    final int displayedPotholeCount =
        activeSummary?.distinctPotholeCount ?? activePotholeCount;
    final int? remainingAheadCount =
        (_navHazardState != null &&
            (_isSimulatingRoute || _followMode != FollowMode.none))
        ? _navHazardState!.remainingPotholeCount
        : null;
    final String summaryLine = activeSummary != null
        ? activeSummary.formattedSummaryLine(
            formattedEta: totalEtaStr.isNotEmpty ? totalEtaStr : null,
          )
        : '${distStr.isNotEmpty ? distStr : '0 m'} · ${totalEtaStr.isNotEmpty ? totalEtaStr : '-- min'} · '
              '${displayedPotholeCount == 0 ? 'No reported potholes along this route' : '$displayedPotholeCount reported pothole${displayedPotholeCount == 1 ? '' : 's'}'}';
    final String updatedLabel = RoadReportCache.formatDataUpdatedLabel(
      widget.reportsLastUpdatedAt,
      isUsingCached: widget.isUsingCachedData || _routeUsingCachedGeometry,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Primary Selected Route Card
        Container(
          margin: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Selected route',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: subtextColor,
                      ),
                    ),
                  ),
                  if (activeSummary?.isApproximate ?? true)
                    Tooltip(
                      message:
                          activeSummary?.roadMatchNote ??
                          'Approximate count within ${RouteCorridorConfig.defaultCorridorMeters.round()} m route corridor',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFF59E0B,
                          ).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Approximate',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? const Color(0xFFFDE68A)
                                : const Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                summaryLine,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
              if (remainingAheadCount != null && displayedPotholeCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Remaining ahead: $remainingAheadCount of $displayedPotholeCount reported potholes',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: brandBlue,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                updatedLabel,
                style: TextStyle(fontSize: 11.5, color: subtextColor),
              ),
              if (activeSummary != null &&
                  activeSummary.otherDefectCounts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Other road defects along route: ${activeSummary.otherDefectsSummary}',
                  style: TextStyle(fontSize: 11.5, color: subtextColor),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Semantics(
                    button: true,
                    label: 'Find fewer potholes',
                    child: ElevatedButton.icon(
                      onPressed: _isSearchingAlternatives
                          ? null
                          : () => unawaited(_findFewerPotholes()),
                      icon: _isSearchingAlternatives
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.alt_route_rounded, size: 16),
                      label: Text(
                        _isSearchingAlternatives
                            ? 'Searching routes...'
                            : 'Find fewer potholes',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: brandBlue,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  if (_alternativeRoutes.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: _toggleRouteSimulation,
                      icon: Icon(
                        _isSimulatingRoute
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                        size: 16,
                      ),
                      label: Text(_isSimulatingRoute ? 'Stop' : 'Simulate'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: () {
                      _applyMapState(() {
                        _showTurnByTurnSheet = !_showTurnByTurnSheet;
                      });
                    },
                    icon: const Icon(Icons.list_alt_rounded, size: 16),
                    label: const Text('Steps'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // 2. Empty/Single-Route/No-Safer-Alternative Explanation
        if (comparison != null &&
            (_hasEvaluatedFewerPotholes || comparison.options.length > 1) &&
            !comparison.hasFewerPotholesOption)
          Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFCBD5E1),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: subtextColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    comparison.options.length <= 1
                        ? 'No route with fewer reported potholes was found. The routing service returned a single road path here.'
                        : 'No route with fewer reported potholes was found within a reasonable detour.',
                    style: TextStyle(fontSize: 12, color: textColor),
                  ),
                ),
              ],
            ),
          ),

        // 3. Up to 3 Route Comparison Options (Fastest / Fewer / Alternative)
        if (comparison != null && comparison.options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Route comparison',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 6),
                ...comparison.options.take(3).map((option) {
                  final bool isSelected =
                      _selectedRouteIndex == option.routeIndex;
                  final int count = option.summary.distinctPotholeCount;
                  final String potholeLabel = count == 0
                      ? '0 reported potholes'
                      : '$count reported pothole${count == 1 ? '' : 's'}';
                  final String optionDist =
                      RoutePotholeAdvisor.formatRouteDistance(
                        option.summary.distanceMeters,
                      );
                  final String optionDur = _formatEta(
                    option.summary.durationSeconds,
                    distanceMeters: option.summary.distanceMeters,
                    potholeCount: count,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      button: true,
                      selected: isSelected,
                      label:
                          '${option.roleLabel}, $optionDist, $optionDur, $potholeLabel. ${option.tradeoffExplanation}',
                      child: Material(
                        color: isSelected
                            ? brandBlue.withValues(alpha: isDark ? 0.18 : 0.08)
                            : (isDark ? const Color(0xFF0F172A) : Colors.white),
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          onTap: () => _selectActiveRoute(option.routeIndex),
                          borderRadius: BorderRadius.circular(10),
                          focusColor: brandBlue.withValues(alpha: 0.16),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isSelected
                                    ? brandBlue
                                    : (isDark
                                          ? const Color(0xFF334155)
                                          : const Color(0xFFE2E8F0)),
                                width: isSelected ? 1.8 : 1.0,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      isSelected
                                          ? Icons.check_circle_rounded
                                          : Icons
                                                .radio_button_unchecked_rounded,
                                      size: 18,
                                      color: isSelected
                                          ? brandBlue
                                          : subtextColor,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        option.roleLabel,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '$optionDist · $optionDur',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$potholeLabel · ${option.viaSummary ?? 'Road route'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: count == 0
                                        ? (isDark
                                              ? const Color(0xFF6EE7B7)
                                              : const Color(0xFF047857))
                                        : subtextColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  option.tradeoffExplanation,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: subtextColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

        // 4. "Show potholes along route" Filter Toggle & Selectable On-Route List
        if (activeSummary != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SwitchListTile.adaptive(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(
                'Show potholes along route',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              subtitle: Text(
                displayedPotholeCount == 0
                    ? 'No reported potholes along this route'
                    : '$displayedPotholeCount reported pothole${displayedPotholeCount == 1 ? '' : 's'} within ${activeSummary.corridorMeters.round()} m',
                style: TextStyle(fontSize: 11.5, color: subtextColor),
              ),
              value: _showPotholesAlongRouteOnly,
              onChanged: (val) =>
                  _applyMapState(() => _showPotholesAlongRouteOnly = val),
            ),
          ),
          if (_showPotholesAlongRouteOnly &&
              activeSummary.potholeEncounters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: activeSummary.potholeEncounters
                    .map((enc) {
                      final String distAlong = enc.chainDistanceMeters >= 1000
                          ? '${(enc.chainDistanceMeters / 1000).toStringAsFixed(1)} km from start'
                          : '${enc.chainDistanceMeters.round()} m from start';
                      final String? road = enc.hazard.roadName;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: InkWell(
                          onTap: () => _focusRouteEncounter(enc),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 44),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  size: 16,
                                  color: Color(0xFFD97706),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${enc.hazard.defectName}${road != null && road.isNotEmpty ? ' · $road' : ''} ($distAlong)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: textColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.center_focus_strong_rounded,
                                  size: 16,
                                  color: brandBlue,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildWebPotholeWarningBanner({
    required bool isDark,
    int activePotholeCount = 0,
    String? nearestInfo,
    String? nextPotholeEta,
  }) {
    final bool isOnRoute =
        _destination != null && _alternativeRoutes.isNotEmpty;
    final NavigationHazardState? nav = _navHazardState;
    final UpcomingHazardCountdown? upcoming = _upcomingHazard;
    final RouteSwitchSuggestion? suggestion = _routeSwitchSuggestion;
    final RouteHazardSummary? activeSummary = _currentActiveRouteSummary;

    final double? distMeters =
        nav?.distanceToNextMeters ?? upcoming?.distanceMeters;
    final NavigationHazardStatus status =
        nav?.status ??
        ((upcoming != null || _showWarningBanner)
            ? NavigationHazardStatus.hazardAhead
            : NavigationHazardStatus.clearAhead);
    final bool isUpdatingRoute =
        _isRouting ||
        _isAutoRerouting ||
        status == NavigationHazardStatus.offRoute;
    final bool isLowAccuracy = nav?.isLowAccuracy ?? false;
    final bool isUsingSaved =
        widget.isUsingCachedData || _routeUsingCachedGeometry;
    final bool isHazardAhead = status == NavigationHazardStatus.hazardAhead;

    final bool isUrgent =
        _showWarningBanner ||
        (isHazardAhead && distMeters != null && distMeters <= 45.0);
    final bool isWarning =
        isUpdatingRoute ||
        isLowAccuracy ||
        status == NavigationHazardStatus.waitingForLocation ||
        isUsingSaved ||
        (!isUrgent &&
            isHazardAhead &&
            distMeters != null &&
            distMeters <= 250.0);
    final bool isClear =
        !isUpdatingRoute &&
        !isLowAccuracy &&
        status == NavigationHazardStatus.clearAhead &&
        !_showWarningBanner;

    final Color accentColor = isClear
        ? const Color(0xFF047857)
        : (isUrgent
              ? const Color(0xFFB91C1C)
              : (isWarning
                    ? const Color(0xFFB45309)
                    : const Color(0xFF1D4ED8)));

    final Color cardBg = isUrgent
        ? const Color(0xFF991B1B)
        : (isDark ? const Color(0xFF0F172A) : Colors.white);

    final Color titleColor = isUrgent
        ? Colors.white
        : (isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A));
    final Color subtitleColor = isUrgent
        ? Colors.white.withValues(alpha: 0.92)
        : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569));

    String countdownValue;
    if (isUpdatingRoute) {
      countdownValue = 'Sync';
    } else if (status == NavigationHazardStatus.waitingForLocation) {
      countdownValue = 'GPS';
    } else if (distMeters != null) {
      countdownValue = RoutePotholeAdvisor.formatDistanceAhead(distMeters);
    } else if (nearestInfo != null &&
        nearestInfo.isNotEmpty &&
        nearestInfo != 'Clear ahead') {
      countdownValue = nearestInfo;
    } else {
      countdownValue = 'Clear';
    }

    String headline;
    if (isUpdatingRoute) {
      headline = 'Updating route...';
    } else if (status == NavigationHazardStatus.waitingForLocation) {
      headline = 'Waiting for location...';
    } else if (isLowAccuracy && !isHazardAhead) {
      headline = 'Location accuracy is low.';
    } else if (isHazardAhead) {
      headline = distMeters != null
          ? 'Pothole ahead · ${RoutePotholeAdvisor.formatDistanceAhead(distMeters)}'
          : 'Pothole ahead';
    } else if (isUsingSaved) {
      headline = 'Using saved pothole data.';
    } else {
      headline = 'No reported potholes ahead on this route.';
    }

    final int remainingCount =
        nav?.remainingPotholeCount ??
        (upcoming == null ? 0 : activePotholeCount);
    final int totalCount = nav?.totalRoutePotholeCount ?? activePotholeCount;
    final List<String> metaParts = [];
    if (isHazardAhead) {
      if (isOnRoute && totalCount > 0) {
        metaParts.add(
          '$remainingCount reported pothole${remainingCount == 1 ? '' : 's'} remaining on your route (total $totalCount)',
        );
      } else if (upcoming != null && upcoming.barangay.isNotEmpty) {
        metaParts.add(upcoming.barangay);
      }
      if (isLowAccuracy) {
        metaParts.add('Location accuracy is low.');
      }
    } else if (isOnRoute) {
      metaParts.add(
        totalCount == 0
            ? '0 reported potholes on route'
            : '$remainingCount remaining of $totalCount on route',
      );
      if (totalCount == 0 &&
          activeSummary != null &&
          activeSummary.totalOtherDefectsCount > 0) {
        metaParts.add('Other defects: ${activeSummary.otherDefectsSummary}');
      }
    }
    if (isUsingSaved && headline != 'Using saved pothole data.') {
      metaParts.add('Using saved pothole data.');
    }
    if (isOnRoute && nextPotholeEta != null && nextPotholeEta.isNotEmpty) {
      metaParts.add('ETA $nextPotholeEta');
    }
    final String subtitle = metaParts.join(' · ');

    final double progress = distMeters == null
        ? (isUrgent ? 1.0 : 0.0)
        : (1.0 - (distMeters / 500.0)).clamp(0.06, 1.0);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUrgent
              ? const Color(0xFFFCA5A5)
              : accentColor.withValues(alpha: 0.45),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: (isUrgent ? const Color(0xFFEF4444) : Colors.black)
                .withValues(alpha: isDark ? 0.36 : 0.16),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isUrgent
                      ? Colors.white.withValues(alpha: 0.18)
                      : accentColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  countdownValue,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: isUrgent ? Colors.white : accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (suggestion != null && isOnRoute) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () =>
                      _selectActiveRoute(suggestion.recommendedRouteIndex),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF047857),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Switch (-${suggestion.hazardsAvoided})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (!isClear && isHazardAhead) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: isUrgent
                    ? Colors.white.withValues(alpha: 0.20)
                    : accentColor.withValues(alpha: 0.14),
                valueColor: AlwaysStoppedAnimation<Color>(
                  isUrgent ? Colors.white : accentColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeIconButton({
    required IconData icon,
    required OsrmTravelMode mode,
    required String label,
    required bool isDark,
  }) {
    final bool isSelected = _travelMode == mode;
    const Color brandBlue = Color(0xFF2563EB);
    final Color subtextColor = AppDesign.textSecondary(isDark);

    return InkWell(
      onTap: () {
        _applyMapState(() => _travelMode = mode);
        if (_searchController.text.isNotEmpty &&
            _originController.text.isNotEmpty) {
          _searchAndRoute();
        } else if (_destination != null) {
          _calculateRoute(_destination!);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? brandBlue : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: isSelected ? brandBlue : subtextColor,
        ),
      ),
    );
  }

  Widget _buildHistoryAndPresetsInPlanner(bool isDark) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. "Your location" Quick Item
        InkWell(
          onTap: () {
            if (_currentPosition != null) {
              if (_isEditingOrigin) {
                _applyMapState(() {
                  _originController.text = 'Your location';
                  _customOrigin = null;
                  _originTextDirty = false;
                });
              } else {
                _applyMapState(() {
                  _searchController.text = 'Your location';
                  _destination = _currentPosition;
                  _destinationTextDirty = false;
                });
              }
              if (_originController.text.isNotEmpty &&
                  _searchController.text.isNotEmpty) {
                _searchAndRoute();
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: brandBlue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.my_location_rounded,
                    color: brandBlue,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  'Your location',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: brandBlue,
                  ),
                ),
              ],
            ),
          ),
        ),

        // 2. "Home" Preset Item
        InkWell(
          onTap: () {
            _selectHistoryItem({
              'name': _homeName,
              'address': _homeAddress,
              'lat': _homeLat,
              'lon': _homeLon,
              'status': 'Home location',
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.home_outlined,
                    color: isDark ? Colors.white70 : const Color(0xFF475569),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _homeName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      Text(
                        _homeAddress,
                        style: TextStyle(fontSize: 11.5, color: subtextColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _editHomeLocationDialog,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Edit',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: brandBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Divider(
          height: 1,
          thickness: 0.8,
          color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
        ),

        // 3. Recent History List
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _searchHistory.length,
          itemBuilder: (ctx, i) {
            final h = _searchHistory[i];
            final name = (h['name'] ?? '').toString();
            final address = (h['address'] ?? '').toString();
            final status = h['status']?.toString();
            final bool isClosed =
                status?.toLowerCase().contains('closed') == true;

            return Material(
              color: Colors.transparent,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _selectHistoryItem(h),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF1F5F9),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.schedule_rounded,
                                  color: subtextColor,
                                  size: 16,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (address.isNotEmpty)
                                    Text(
                                      address,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: subtextColor,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  if (status != null && status.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        status,
                                        style: TextStyle(
                                          fontSize: 11.0,
                                          fontWeight: FontWeight.w600,
                                          color: isClosed
                                              ? const Color(0xFFEF4444)
                                              : const Color(0xFF10B981),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: subtextColor,
                    ),
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    tooltip: 'Remove',
                    onPressed: () => _removeFromSearchHistory(i),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            );
          },
        ),

        // 4. Delays & Road Disruptions Footer matching Screenshot
        Container(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Delays',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Light traffic in this area',
                style: TextStyle(fontSize: 11.5, color: subtextColor),
              ),
              const SizedBox(height: 4),
              Text(
                'No known road disruptions. Pothole hazards will show on route.',
                style: TextStyle(
                  fontSize: 11.0,
                  color: subtextColor.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestionsListInPlanner(bool isDark) {
    final Color textColor = AppDesign.textPrimary(isDark);
    final Color subtextColor = AppDesign.textSecondary(isDark);
    const Color brandBlue = Color(0xFF2563EB);

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _suggestions.length,
      separatorBuilder: (ctx, i) => Divider(
        height: 1,
        thickness: 0.8,
        color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
      ),
      itemBuilder: (ctx, i) {
        final s = _suggestions[i];
        final name = (s['_name'] ?? s['display_name']).toString();
        final shortAddr = (s['_short_addr'] ?? '').toString();
        final bool isBarangay =
            s['_is_barangay'] == true ||
            name.toLowerCase().contains('barangay');
        const Color brgyTeal = Color(0xFF0D9488);

        return InkWell(
          onTap: () => _selectSuggestion(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: isBarangay
                        ? brgyTeal.withValues(alpha: 0.14)
                        : brandBlue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isBarangay
                        ? Icons.holiday_village_rounded
                        : Icons.place_rounded,
                    color: isBarangay ? brgyTeal : brandBlue,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isBarangay) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: brgyTeal.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: brgyTeal.withValues(alpha: 0.35),
                                  width: 0.8,
                                ),
                              ),
                              child: const Text(
                                'BARANGAY',
                                style: TextStyle(
                                  fontSize: 9.0,
                                  fontWeight: FontWeight.bold,
                                  color: brgyTeal,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (shortAddr.isNotEmpty && shortAddr != name)
                        Text(
                          shortAddr,
                          style: TextStyle(fontSize: 11.5, color: subtextColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLocationPermissionCard(bool isDark) {
    final bool isLocationOff = _isLocationDisabled;
    final Color statusColor = isLocationOff
        ? WebDesign.statusStyle(StatusTone.pending, isDark).fg
        : WebDesign.brand(isDark);

    return Container(
      padding: const EdgeInsets.all(WebDesign.space3),
      decoration: WebDesign.cardDecoration(isDark, radius: WebDesign.radiusLg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(WebDesign.radiusSm),
            ),
            child: Icon(
              isLocationOff
                  ? Icons.location_off_rounded
                  : Icons.my_location_rounded,
              color: statusColor,
              size: 18,
            ),
          ),
          const SizedBox(width: WebDesign.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isLocationOff ? 'GPS unavailable' : 'Enable location',
                  style: TextStyle(
                    color: WebDesign.textPrimary(isDark),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isLocationOff
                      ? 'Turn on location services for nearby road defect warnings.'
                      : 'Allow browser location to center the map and check nearby hazards.',
                  style: TextStyle(
                    color: WebDesign.textSecondary(isDark),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: WebDesign.space2),
                Wrap(
                  spacing: WebDesign.space2,
                  runSpacing: WebDesign.space1,
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        if (isLocationOff) {
                          await Geolocator.openLocationSettings();
                        } else {
                          await _determinePosition(requestPermission: true);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: statusColor,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(
                          horizontal: WebDesign.space3,
                        ),
                      ),
                      child: Text(
                        isLocationOff ? 'Turn On GPS' : 'Allow Location',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          _applyMapState(() => _dismissedLocationBanner = true),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(
                          horizontal: WebDesign.space2,
                        ),
                      ),
                      child: const Text(
                        'Dismiss',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Dismiss location prompt',
            onPressed: () =>
                _applyMapState(() => _dismissedLocationBanner = true),
            icon: const Icon(Icons.close_rounded, size: 16),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceTab(int index, String label, bool isDark) {
    final isSelected = _placeCardTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => _applyMapState(() => _placeCardTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected
                    ? const Color(0xFF00796B)
                    : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              color: isSelected
                  ? (isDark ? Colors.white : const Color(0xFF00796B))
                  : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircularAction({
    required IconData icon,
    required String label,
    required bool isPrimary,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isPrimary
                    ? const Color(0xFF00796B)
                    : (isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE0F2F1)),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: isPrimary ? Colors.white : const Color(0xFF00796B),
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceInfoRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xFF00796B)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF1E293B),
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchedPlaceCard(bool isDark) {
    if (_searchedPlace == null) return const SizedBox.shrink();

    final String name =
        _searchedPlace!['name'] as String? ?? 'Searched Location';
    final String address = _searchedPlace!['address'] as String? ?? '';
    final LatLng loc = _searchedPlace!['location'] as LatLng;
    final double distKm =
        (_searchedPlace!['distanceKm'] as num?)?.toDouble() ?? 0.0;
    final int estMinutes = (distKm * 2.2).round().clamp(1, 999);
    final String category =
        _searchedPlace!['category'] as String? ?? 'DESTINATION';

    return Container(
      constraints: const BoxConstraints(maxHeight: 520, maxWidth: 420),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Hero Image / Visual Banner Header
              Stack(
                children: [
                  Container(
                    height: 120,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark
                            ? [
                                const Color(0xFF0F172A),
                                const Color(0xFF1E293B),
                                const Color(0xFF003853),
                              ]
                            : [
                                const Color(0xFF0288D1),
                                const Color(0xFF0097A7),
                                const Color(0xFF00796B),
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.location_city_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 36),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Floating Close Button (✕)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: GestureDetector(
                      onTap: () {
                        _applyMapState(() {
                          _searchedPlace = null;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // 2. Title & Rating Block
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 17.5,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF202124),
                      ),
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        address,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF5F6368),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Text(
                          '4.8',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFF59E0B),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Row(
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                            Icon(
                              Icons.star_half_rounded,
                              size: 15,
                              color: Color(0xFFF59E0B),
                            ),
                          ],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '(OSM Verified)',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF5F6368),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFF1F3F4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            category,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white70
                                  : const Color(0xFF3C4043),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 3. Tab Bar (Overview, Routes & Safety, About)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    _buildPlaceTab(0, 'Overview', isDark),
                    _buildPlaceTab(1, 'Routes & Safety', isDark),
                    _buildPlaceTab(2, 'About', isDark),
                  ],
                ),
              ),

              // 4. Circular Actions Row (Directions, A->B Plan, Hazards, Share)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildCircularAction(
                      icon: Icons.directions_rounded,
                      label: 'Directions',
                      isPrimary: true,
                      isDark: isDark,
                      onTap: () {
                        _applyMapState(() {
                          _isRoutePlanningMode = true;
                          _originController.text = 'Your location';
                          _searchController.text = name;
                          _destination = loc;
                          _customOrigin = null;
                          _searchedPlace = null;
                          _destinationTextDirty = false;
                          _originTextDirty = false;
                        });
                        _calculateRoute(loc);
                      },
                    ),
                    _buildCircularAction(
                      icon: Icons.alt_route_rounded,
                      label: 'A → B Plan',
                      isPrimary: false,
                      isDark: isDark,
                      onTap: () {
                        _applyMapState(() {
                          _isRoutePlanningMode = true;
                          _originController.text = 'Your location';
                          _searchController.text = name;
                          _destination = loc;
                          _customOrigin = null;
                          _searchedPlace = null;
                          _destinationTextDirty = false;
                          _originTextDirty = false;
                        });
                        _calculateRoute(loc);
                      },
                    ),
                    _buildCircularAction(
                      icon: Icons.warning_amber_rounded,
                      label: 'Hazards',
                      isPrimary: false,
                      isDark: isDark,
                      onTap: () {
                        _animatedMapMove(loc, 17.0);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Scanning hazards near $name...'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                    _buildCircularAction(
                      icon: Icons.share_rounded,
                      label: 'Share',
                      isPrimary: false,
                      isDark: isDark,
                      onTap: () {
                        Clipboard.setData(
                          ClipboardData(
                            text:
                                '$name\n$address\nCoordinates: ${loc.latitude}, ${loc.longitude}',
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('📍 Location copied to clipboard!'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),

              Divider(
                height: 1,
                thickness: 1,
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFF1F5F9),
              ),

              // 5. Details List (Address, ETA, Coordinates, Safety)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _buildPlaceInfoRow(
                      icon: Icons.location_on_rounded,
                      title: address.isNotEmpty ? address : name,
                      subtitle: distKm > 0
                          ? '${distKm.toStringAsFixed(1)} km from your location (approx. $estMinutes min)'
                          : 'Bulacan, Philippines',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _buildPlaceInfoRow(
                      icon: Icons.alt_route_rounded,
                      title: 'Project-OSRM & OpenStreetMap',
                      subtitle:
                          'Lat ${loc.latitude.toStringAsFixed(5)}, Lng ${loc.longitude.toStringAsFixed(5)}',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _buildPlaceInfoRow(
                      icon: Icons.shield_rounded,
                      title: 'Pothole Scanner AI Active',
                      subtitle: 'Automatic safe path & proximity alerts ready',
                      isDark: isDark,
                    ),
                  ],
                ),
              ),

              // 6. Bottom Primary CTA Button
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00796B),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.navigation_rounded, size: 18),
                    label: const Text(
                      'Start A → B Navigation',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                    onPressed: () {
                      _applyMapState(() {
                        _isRoutePlanningMode = true;
                        _originController.text = 'Your location';
                        _searchController.text = name;
                        _destination = loc;
                        _customOrigin = null;
                        _searchedPlace = null;
                        _destinationTextDirty = false;
                        _originTextDirty = false;
                      });
                      _calculateRoute(loc);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _formatStepDistanceWidget(double meters, bool isDark) {
    String formatted;
    if (meters >= 1000) {
      final double km = meters / 1000.0;
      if (km == km.roundToDouble()) {
        formatted = '${km.round()} km';
      } else {
        formatted = '${km.toStringAsFixed(1)} km';
      }
    } else {
      formatted = '${meters.round()} m';
    }
    return Text(
      formatted,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
      ),
    );
  }

  Widget _buildStepText(RouteStep step, bool isDark) {
    final name = step.roadName;
    final instruction = step.instruction;

    if (name.isNotEmpty && instruction.contains(name)) {
      final parts = instruction.split(name);
      return RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 14.0,
            color: isDark ? Colors.white70 : const Color(0xFF334155),
            height: 1.3,
          ),
          children: [
            TextSpan(text: parts[0]),
            TextSpan(
              text: name,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts[1]),
          ],
        ),
      );
    }

    return Text(
      instruction,
      style: TextStyle(
        fontSize: 14.0,
        fontWeight: FontWeight.w500,
        color: isDark ? Colors.white70 : const Color(0xFF334155),
        height: 1.3,
      ),
    );
  }

  Widget _buildManeuverIcon(
    RouteStep step,
    bool isFirst,
    bool isLast,
    bool isDark,
  ) {
    if (isFirst) {
      return Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        child: const Text(
          'A',
          style: TextStyle(
            color: Color(0xFF10B981), // Emerald green
            fontSize: 22,
            fontWeight: FontWeight.w900,
            fontFamily: 'serif',
          ),
        ),
      );
    }
    if (isLast) {
      return Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        child: const Text(
          'B',
          style: TextStyle(
            color: Color(0xFFDC2626), // Deep red
            fontSize: 22,
            fontWeight: FontWeight.w900,
            fontFamily: 'serif',
          ),
        ),
      );
    }

    final type = step.maneuverType.toLowerCase();
    final modifier = (step.modifier ?? '').toLowerCase();

    IconData iconData = Icons.navigation_rounded;

    if (modifier.contains('slight right') ||
        modifier.contains('sharp right') ||
        modifier == 'right') {
      iconData = Icons.turn_right_rounded;
    } else if (modifier.contains('slight left') ||
        modifier.contains('sharp left') ||
        modifier == 'left') {
      iconData = Icons.turn_left_rounded;
    } else if (modifier.contains('uturn')) {
      iconData = Icons.u_turn_left_rounded;
    } else if (type == 'roundabout' || type == 'rotary') {
      iconData = Icons.roundabout_right_rounded;
    } else if (type == 'fork') {
      iconData = modifier.contains('left')
          ? Icons.fork_left_rounded
          : Icons.fork_right_rounded;
    } else if (type == 'merge') {
      iconData = Icons.merge_rounded;
    } else {
      iconData = Icons.straight_rounded;
    }

    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      child: Icon(
        iconData,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
        size: 22,
      ),
    );
  }

  void _onEndpointPanStart(int kind) {
    final LatLng? point = kind == 1
        ? (_customOrigin ??
              (_destination != null
                  ? (_currentPosition ?? MapScreenState._bulacanCenter)
                  : null))
        : _destination;
    if (point == null) return;
    _endpointPressStart = DateTime.now();
    _endpointDragDistance = 0.0;
    _applyMapState(() {
      _draggingEndpointKind = kind;
      _isDraggingEndpoint = true;
      _endpointDragAccum = Offset.zero;
      _endpointDragScreenBase = _mapController.camera.latLngToScreenOffset(
        point,
      );
    });
    _liveRerouteTimer?.cancel();
    _liveRerouteTimer = Timer.periodic(
      const Duration(milliseconds: 850),
      (_) => _rerouteFromEndpoints(),
    );
  }

  void _onEndpointPanUpdate(DragUpdateDetails details) {
    final Offset? base = _endpointDragScreenBase;
    if (!_isDraggingEndpoint || base == null) return;
    _endpointDragAccum += details.delta;
    _endpointDragDistance += details.delta.distance;
    final LatLng moved = _mapController.camera.screenOffsetToLatLng(
      base + _endpointDragAccum,
    );
    final String coords =
        '${moved.latitude.toStringAsFixed(5)}, ${moved.longitude.toStringAsFixed(5)}';
    _applyMapState(() {
      if (_draggingEndpointKind == 1) {
        _customOrigin = moved;
        if (_originController.text != coords) {
          _originController.text = coords;
          _originTextDirty = false;
        }
        _rubberBandActiveRoute(newStart: moved);
        if (_p2pPoint != null) {
          final double distM = Geolocator.distanceBetween(
            moved.latitude,
            moved.longitude,
            _p2pPoint!.latitude,
            _p2pPoint!.longitude,
          );
          _p2pDistanceKm = distM / 1000.0;
          _p2pMinutes = (_p2pDistanceKm / 35.0 * 60).round().clamp(1, 999);
          _p2pHazardCount = _countHazardsBetween(moved, _p2pPoint!);
        }
      } else {
        _destination = moved;
        _p2pPoint = moved;
        _rubberBandActiveRoute(newEnd: moved);
        final start =
            _customOrigin ?? _currentPosition ?? MapScreenState._bulacanCenter;
        final double distM = Geolocator.distanceBetween(
          start.latitude,
          start.longitude,
          moved.latitude,
          moved.longitude,
        );
        _p2pDistanceKm = distM / 1000.0;
        _p2pMinutes = (_p2pDistanceKm / 35.0 * 60).round().clamp(1, 999);
        _p2pHazardCount = _countHazardsBetween(start, moved);
        _p2pAddress = coords;
        if (_searchController.text != coords) {
          _searchController.text = coords;
          _destinationTextDirty = false;
        }
      }
    });
  }

  void _onEndpointPanEnd(DragEndDetails details) {
    if (!_isDraggingEndpoint) return;
    _liveRerouteTimer?.cancel();
    _endpointDragScreenBase = null;
    final int kind = _draggingEndpointKind;
    final bool wasTap =
        DateTime.now().difference(_endpointPressStart).inMilliseconds < 350 &&
        _endpointDragDistance < 8.0;
    _applyMapState(() => _isDraggingEndpoint = false);

    if (wasTap) {
      _handleEndpointTap(kind);
      return;
    }
    _rerouteFromEndpoints(force: true);
    _resolveDraggedLabel(kind);
  }

  void _handleEndpointTap(int kind) {
    final LatLng? loc = kind == 1
        ? (_customOrigin ?? _currentPosition ?? MapScreenState._bulacanCenter)
        : _destination;
    if (loc == null || !mounted) return;
    _applyMapState(() {
      _tappedRequestSeq++;
      _tappedPoint = loc;
      _tappedPointLabel = '';
    });
    _resolveTappedLabel(_tappedRequestSeq);
  }

  Future<void> _resolveTappedLabel(int seq) async {
    final LatLng? point = _tappedPoint;
    if (point == null) return;
    final parts = await _reverseGeocodeParts(point);
    if (!mounted || seq != _tappedRequestSeq || _tappedPoint != point) {
      return;
    }
    _applyMapState(() {
      _tappedPointLabel = parts[0];
      _tappedPointSecondary = parts.length > 1 ? parts[1] : '';
    });
  }

  void _routeToTappedPoint() {
    final LatLng? loc = _tappedPoint;
    if (loc == null || !mounted) return;
    final String combined = [
      _tappedPointLabel,
      _tappedPointSecondary,
    ].where((e) => e.isNotEmpty).join(', ');
    _applyMapState(() {
      _isRoutePlanningMode = true;
      _destination = loc;
      _searchController.text = combined.isEmpty
          ? '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}'
          : combined;
      if (_originController.text.trim().isEmpty) {
        _originController.text = 'Your location';
        _customOrigin = null;
      }
      _destinationTextDirty = false;
      _isEditingOrigin = false;
      _tappedPoint = null;
      _tappedPointLabel = '';
      _tappedPointSecondary = '';
    });
    final start =
        (_originController.text == 'Your location' || _customOrigin == null)
        ? (_currentPosition ?? MapScreenState._bulacanCenter)
        : _customOrigin;
    _calculateRoute(loc, customOrigin: start);
  }

  int _countHazardsBetween(LatLng a, LatLng b) {
    int count = 0;
    for (final p in _effectivePotholes) {
      if (_isReportExcluded(p)) continue;
      final defectNames = DpwhStandards.extractDetectionClassNames(
        p.detections,
      );
      final bool isPotholeReport =
          DpwhStandards.tryClassify(p.primaryDefect) == DpwhStandards.pothole ||
          defectNames.any(
            (name) => DpwhStandards.tryClassify(name) == DpwhStandards.pothole,
          );
      if (!isPotholeReport) continue;
      final d = _distancePointToSegmentMeters(p.location, a, b);
      if (d <= 75.0) {
        count += (p.potholeCount > 0 ? p.potholeCount : 1);
      }
    }
    return count;
  }

  void _showPointToPointPill({
    required LatLng point,
    String? name,
    String? address,
    bool updateCamera = false,
    bool autoRoute = true,
  }) {
    final start =
        _customOrigin ?? _currentPosition ?? MapScreenState._bulacanCenter;
    final double distMeters = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      point.latitude,
      point.longitude,
    );
    final double distKm = distMeters / 1000.0;
    final int minutes = (distKm / 35.0 * 60).round().clamp(1, 999);
    final int hazardCount = _countHazardsBetween(start, point);

    final String initialName = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
    final String initialAddr = (address != null && address.trim().isNotEmpty)
        ? address.trim()
        : 'Bulacan, Central Luzon';

    _applyMapState(() {
      _p2pPoint = point;
      _destination = point;
      _tappedPoint = point;
      _isP2pPillVisible = true;
      _p2pName = initialName;
      _p2pAddress = initialAddr;
      _p2pDistanceKm = distKm;
      _p2pMinutes = minutes;
      _p2pHazardCount = hazardCount;
      _rubberBandActiveRoute(newStart: start, newEnd: point);
    });

    if (autoRoute) {
      unawaited(
        _calculateRoute(
          point,
          customOrigin: start,
          fitCamera: false,
          silent: true,
        ),
      );
    }

    if (name == null || name.trim().isEmpty) {
      _reverseGeocodeParts(point).then((parts) {
        if (!mounted || _p2pPoint != point) return;
        _applyMapState(() {
          if (parts.isNotEmpty && parts[0].isNotEmpty) {
            _p2pName = parts[0];
          }
          if (parts.length > 1 && parts[1].isNotEmpty) {
            _p2pAddress = parts[1];
          }
        });
      });
    }

    if (updateCamera) {
      _animatedMapMove(point, 16.5);
    }
  }

  void _routeToP2pPoint() {
    final LatLng? loc = _p2pPoint ?? _destination;
    if (loc == null || !mounted) return;
    final String combined = [
      _p2pName,
      _p2pAddress,
    ].where((e) => e.isNotEmpty).join(', ');
    _applyMapState(() {
      _isRoutePlanningMode = true;
      _destination = loc;
      _searchController.text = combined.isEmpty
          ? '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}'
          : combined;
      if (_originController.text.trim().isEmpty) {
        _originController.text = 'Your location';
        _customOrigin = null;
      }
      _destinationTextDirty = false;
      _isEditingOrigin = false;
    });
    final start =
        (_originController.text == 'Your location' || _customOrigin == null)
        ? (_currentPosition ?? MapScreenState._bulacanCenter)
        : _customOrigin;
    _calculateRoute(loc, customOrigin: start);
  }

  void _swapP2pEndpoints() {
    if (_p2pPoint == null) return;
    final oldDest = _p2pPoint!;
    final oldOrigin =
        _customOrigin ?? _currentPosition ?? MapScreenState._bulacanCenter;
    final oldName = _p2pName;

    _applyMapState(() {
      _customOrigin = oldDest;
      _originController.text = oldName.isNotEmpty
          ? oldName
          : '${oldDest.latitude.toStringAsFixed(4)}, ${oldDest.longitude.toStringAsFixed(4)}';
      _p2pPoint = oldOrigin;
      _destination = oldOrigin;
      _p2pName = 'Your Location';
      _p2pAddress =
          '${oldOrigin.latitude.toStringAsFixed(4)}, ${oldOrigin.longitude.toStringAsFixed(4)}';
      _searchController.text = 'Your Location';
      _rubberBandActiveRoute(newStart: oldDest, newEnd: oldOrigin);
    });

    _reverseGeocodeParts(oldOrigin).then((parts) {
      if (!mounted || _p2pPoint != oldOrigin) return;
      _applyMapState(() {
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          _p2pName = parts[0];
        }
        if (parts.length > 1 && parts[1].isNotEmpty) {
          _p2pAddress = parts[1];
        }
      });
    });

    unawaited(
      _calculateRoute(
        oldOrigin,
        customOrigin: oldDest,
        fitCamera: false,
        silent: true,
      ),
    );
  }

  Widget _buildP2pHazardStatusBadge(Color originGreen) {
    if (_p2pHazardCount == 0) {
      final int otherDefectsCount =
          _currentActiveRouteSummary?.totalOtherDefectsCount ?? 0;
      if (otherDefectsCount > 0) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 11,
              color: Color(0xFFF59E0B),
            ),
            const SizedBox(width: 3),
            Text(
              '0 Potholes · $otherDefectsCount Defect${otherDefectsCount == 1 ? '' : 's'}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF59E0B),
              ),
            ),
          ],
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_rounded, size: 11, color: originGreen),
          const SizedBox(width: 3),
          Text(
            'All Clear',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: originGreen,
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 11,
          color: Color(0xFFFBBF24),
        ),
        const SizedBox(width: 3),
        Text(
          '$_p2pHazardCount Pothole${_p2pHazardCount == 1 ? '' : 's'}',
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Color(0xFFFBBF24),
          ),
        ),
      ],
    );
  }

  Widget _buildPointToPointPill(bool isDark) {
    final Color pillBg = isDark
        ? const Color(0xEE0B1220)
        : const Color(0xF5FFFFFF);
    final Color pillBorder = isDark
        ? const Color(0xFF243247)
        : const Color(0xFFE2E8F0);
    final Color textPrimary = isDark
        ? const Color(0xFFF1F5F9)
        : const Color(0xFF0F172A);
    final Color textSecondary = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    const Color originGreen = Color(0xFF10B981);
    const Color destRose = Color(0xFFFB7185);
    const Color skyCyan = Color(0xFF38BDF8);

    final String originName = _customOrigin != null
        ? (_originController.text.isNotEmpty
              ? _originController.text
              : 'Custom Origin')
        : 'Your Location';
    final String destName = _p2pName.isNotEmpty ? _p2pName : 'Destination';
    final String destAddr = _p2pAddress;

    final String distText = _p2pDistanceKm < 1.0
        ? '${(_p2pDistanceKm * 1000).round()} m'
        : '${_p2pDistanceKm.toStringAsFixed(1)} km';
    final String etaText = '~$_p2pMinutes min';

    return GestureDetector(
      onPanUpdate: (details) {
        _applyMapState(() {
          final size = MediaQuery.of(context).size;
          final double approxWidth = math.min(size.width - 24, 630.0);
          final current =
              _p2pPillOffset ??
              Offset((size.width - approxWidth) / 2, size.height - 110);
          final newX = (current.dx + details.delta.dx).clamp(
            8.0,
            (size.width - approxWidth - 8.0).clamp(8.0, double.infinity),
          );
          final newY = (current.dy + details.delta.dy).clamp(
            60.0,
            (size.height - 100.0).clamp(60.0, double.infinity),
          );
          _p2pPillOffset = Offset(newX, newY);
        });
      },
      child: Material(
        color: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 780),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: pillBg,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: pillBorder, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 1. Grip Handle (Indicates draggable anywhere on screen)
                    Tooltip(
                      message: 'Drag to relocate pill anywhere on screen',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            size: 19,
                            color: textSecondary.withValues(alpha: 0.65),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 4),

                    // 2. Point A (Origin)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: originGreen,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 5),
                              const Text(
                                'POINT A',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  color: originGreen,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            originName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 3. Arrow Connector & Swap Action
                    Tooltip(
                      message: 'Swap Start and Destination',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _swapP2pEndpoints,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: const Icon(
                              Icons.east_rounded,
                              size: 16,
                              color: skyCyan,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 4. Point B (Destination)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 135),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: destRose,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 5),
                              const Text(
                                'POINT B',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  color: destRose,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            destName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              color: textPrimary,
                            ),
                          ),
                          if (destAddr.isNotEmpty)
                            Text(
                              destAddr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 6),

                    // Vertical subtle separator
                    Container(height: 26, width: 1, color: pillBorder),

                    const SizedBox(width: 8),

                    // 5. Metrics (Distance & ETA & Hazards)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.straighten_rounded,
                              size: 12,
                              color: skyCyan,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              distText,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: textPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.schedule_rounded,
                              size: 12,
                              color: Color(0xFF818CF8),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              etaText,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: textPrimary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        // Hazard Status Badge
                        _buildP2pHazardStatusBadge(originGreen),
                      ],
                    ),

                    const SizedBox(width: 8),

                    // 6. Action Button: Directions
                    Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF0284C7), Color(0xFF0369A1)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF0284C7,
                            ).withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _routeToP2pPoint,
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(
                                  Icons.directions_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'Directions',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 4),

                    // 7. Dismiss Button
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: textSecondary,
                      ),
                      tooltip: 'Close',
                      onPressed: () {
                        _applyMapState(() {
                          _isP2pPillVisible = false;
                          _p2pPoint = null;
                          _tappedPoint = null;
                          if (!_isRoutePlanningMode) {
                            _stopRouteSimulation();
                            _resetRoutePlannerState();
                          }
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTappedLocationBar(bool isDark) {
    final Color cardBg = isDark
        ? const Color(0xEE0B1220)
        : const Color(0xF5FFFFFF);
    final Color cardBorder = isDark
        ? const Color(0xFF243247)
        : const Color(0xFFE2E8F0);
    final Color textColor = isDark
        ? const Color(0xFFF1F5F9)
        : const Color(0xFF0F172A);
    final Color subtextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: cardBorder, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.place_rounded,
                color: Color(0xFFFB7185),
                size: 18,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 210),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _tappedPointLabel.isEmpty
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 11,
                                height: 11,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Loading…',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: subtextColor,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            _tappedPointLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: textColor,
                            ),
                          ),
                    if (_tappedPointSecondary.isNotEmpty)
                      Text(
                        _tappedPointSecondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: subtextColor),
                      ),
                    Text(
                      '${_tappedPoint!.latitude.toStringAsFixed(5)}, ${_tappedPoint!.longitude.toStringAsFixed(5)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: subtextColor.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                icon: Icon(Icons.close_rounded, size: 16, color: subtextColor),
                tooltip: 'Dismiss',
                onPressed: () => _applyMapState(() {
                  _tappedPoint = null;
                  _tappedPointLabel = '';
                  _tappedPointSecondary = '';
                }),
              ),
              const SizedBox(width: 4),
              Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0284C7), Color(0xFF0369A1)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _routeToTappedPoint,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(
                            Icons.directions_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'Directions',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
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

  Future<void> _resolveDraggedLabel(int kind) async {
    final LatLng? point = kind == 1
        ? (_customOrigin ?? _currentPosition ?? MapScreenState._bulacanCenter)
        : _destination;
    if (point == null || !mounted) return;
    final String label = await _reverseGeocodeLabel(point);
    if (!mounted || _isDraggingEndpoint) return;
    _applyMapState(() {
      if (kind == 1) {
        _originController.text = label;
        _originTextDirty = false;
      } else {
        _searchController.text = label;
        _destinationTextDirty = false;
        if (label.isNotEmpty) {
          _p2pName = label;
        }
      }
    });
  }

  Future<void> _rerouteFromEndpoints({bool force = false}) async {
    final LatLng? dest = _destination;
    if (dest == null) return;
    if (!force && (_silentRouting || _isRouting)) return;
    _silentRouting = true;
    try {
      await _calculateRoute(
        dest,
        customOrigin: _customOrigin,
        fitCamera: false,
        silent: true,
      );
    } finally {
      _silentRouting = false;
    }
  }

  void _onEndpointPanCancel() {
    _liveRerouteTimer?.cancel();
    _endpointDragScreenBase = null;
    if (!_isDraggingEndpoint) return;
    _applyMapState(() => _isDraggingEndpoint = false);
  }

  Marker _buildDraggableEndpointPin({
    required LatLng point,
    required int kind,
    required Color color,
  }) {
    final bool active = _isDraggingEndpoint && _draggingEndpointKind == kind;
    final String label = kind == 1 ? 'A' : 'B';
    final String tipText = kind == 1 ? 'Start (A)' : 'Destination (B)';

    final List<Color> gradient = kind == 1
        ? const [Color(0xFF38BDF8), Color(0xFF0284C7), Color(0xFF0369A1)]
        : const [Color(0xFFFDA4AF), Color(0xFFFB7185), Color(0xFFE11D48)];

    final Color badgeTextColor = kind == 1
        ? const Color(0xFF0C4A6E)
        : const Color(0xFF881337);

    return Marker(
      key: ValueKey('endpoint_pin_$kind'),
      point: point,
      width: 48,
      height: 64,
      alignment: Alignment.topCenter,
      child: Listener(
        onPointerCancel: (_) => _onEndpointPanCancel(),
        child: MouseRegion(
          cursor: active
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
              _EagerPanGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    _EagerPanGestureRecognizer
                  >(() => _EagerPanGestureRecognizer(), (instance) {
                    instance.dragStartBehavior = DragStartBehavior.down;
                    instance.onStart = (_) => _onEndpointPanStart(kind);
                    instance.onUpdate = (d) => _onEndpointPanUpdate(d);
                    instance.onEnd = (d) => _onEndpointPanEnd(d);
                    instance.onCancel = () => _onEndpointPanCancel();
                  }),
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(0, active ? -8 : 0, 0)
                ..scale(active ? 1.14 : 1.0, active ? 1.14 : 1.0, 1.0),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  // Floating Drag Pill Hint (Eye-friendly frosted pill)
                  if (active)
                    Positioned(
                      top: -24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xEE0B1220),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: gradient[0], width: 1.2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          tipText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),

                  // Pin Body with Custom 3D Teardrop Painter
                  CustomPaint(
                    size: const Size(40, 52),
                    painter: _ModernPinPainter(
                      gradientColors: gradient,
                      borderColor: Colors.white,
                      isLifted: active,
                    ),
                  ),

                  // Gleaming White Inner Emblem with Bold High-Contrast Letter
                  Positioned(
                    top: 7,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: badgeTextColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
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

  int _computedCurrentStepIndex() {
    final pos = _currentPosition;
    if (pos == null || _routeSteps.isEmpty) return -1;
    int bestIdx = -1;
    double bestDist = double.infinity;
    for (int i = 0; i < _routeSteps.length; i++) {
      final loc = _routeSteps[i].location;
      final d = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        loc.latitude,
        loc.longitude,
      );
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  Widget _buildSelectedPotholeCard(PotholeMarker pothole, bool isDark) {
    final isApproved = pothole.status == 'approved';
    final isRejected = pothole.status == 'rejected';
    final Color statusColor = isApproved
        ? const Color(0xFF10B981)
        : (isRejected ? const Color(0xFFEF4444) : const Color(0xFFF59E0B));
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.schedule_rounded);
    final String statusText = isApproved
        ? 'VERIFIED LIVE'
        : (isRejected ? 'REJECTED' : 'PENDING REVIEW');

    final Color severityColor = const Color(0xFF0284C7);
    final IconData severityIcon = Icons.warning_rounded;

    final String docIdStr = pothole.docId != null && pothole.docId!.isNotEmpty
        ? (pothole.docId!.length > 8
              ? pothole.docId!.substring(0, 8).toUpperCase()
              : pothole.docId!.toUpperCase())
        : (pothole.id != null ? '#${pothole.id}' : '#POTHOLE');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
          width: 1.5,
        ),
        boxShadow: [
          // Ambient colored glow matching severity
          BoxShadow(
            color: severityColor.withValues(alpha: isDark ? 0.32 : 0.20),
            blurRadius: 28,
            spreadRadius: 2,
            offset: const Offset(0, 6),
          ),
          // Deep drop shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.65 : 0.18),
            blurRadius: 36,
            spreadRadius: 4,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Top Severity Accent Stripe
            Container(
              height: 4.5,
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [severityColor, statusColor]),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top Title & Badges Bar
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Hazard Icon Pill
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: severityColor.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: severityColor.withValues(alpha: 0.4),
                            width: 1.2,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            severityIcon,
                            color: severityColor,
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Road Surface Hazard',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15.5,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isDark
                                          ? const Color(0xFF475569)
                                          : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Text(
                                    docIdStr,
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            Text(
                              'Surveyed road telemetry & optical hazard alert',
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Close Button
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            _applyMapState(() {
                              _selectedPothole = null;
                            });
                          },
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF334155)
                                  : const Color(0xFFF1F5F9),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF475569)
                                    : const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: isDark
                                  ? const Color(0xFFCBD5E1)
                                  : const Color(0xFF475569),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Middle Section: Thumbnail + Detailed Telemetry Badges
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Photo Thumbnail with Tap Preview
                      _buildPotholeImageThumbnail(pothole.imagePath, isDark),
                      const SizedBox(width: 14),

                      // Info Badges Column
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Status & Severity Row
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: DpwhStandards.getCodeColor(
                                      pothole.primaryDpwhCode,
                                    ).withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: DpwhStandards.getCodeColor(
                                        pothole.primaryDpwhCode,
                                      ).withValues(alpha: 0.7),
                                      width: 1.1,
                                    ),
                                  ),
                                  child: Text(
                                    '${pothole.primaryDpwhCode}: ${pothole.primaryDefect}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: DpwhStandards.getCodeColor(
                                        pothole.primaryDpwhCode,
                                      ),
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF2563EB,
                                    ).withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(
                                        0xFF2563EB,
                                      ).withValues(alpha: 0.6),
                                      width: 1.1,
                                    ),
                                  ),
                                  child: Text(
                                    'SLA: ${pothole.responseTime}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF2563EB),
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: statusColor.withValues(alpha: 0.5),
                                      width: 1.1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        statusIcon,
                                        color: statusColor,
                                        size: 12,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        statusText,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: statusColor,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                if (pothole.potholeCount > 1)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF334155)
                                          : const Color(0xFFF1F5F9),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isDark
                                            ? const Color(0xFF475569)
                                            : const Color(0xFFE2E8F0),
                                      ),
                                    ),
                                    child: Text(
                                      '${pothole.potholeCount} hazards cluster',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: isDark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ),
                              ],
                            ),

                            const SizedBox(height: 8),

                            // Interactive GPS Pill
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text:
                                          '${pothole.location.latitude}, ${pothole.location.longitude}',
                                    ),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Coordinates copied to clipboard!',
                                      ),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF0F172A)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isDark
                                          ? const Color(0xFF334155)
                                          : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.gps_fixed_rounded,
                                        color: Color(0xFF2563EB),
                                        size: 13,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        '${pothole.location.latitude.toStringAsFixed(5)}, ${pothole.location.longitude.toStringAsFixed(5)}',
                                        style: TextStyle(
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A),
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.copy_rounded,
                                        size: 11.5,
                                        color: isDark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF64748B),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'DPWH Action: ${pothole.correctiveMeasure}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Action: Full Report
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark
                            ? Colors.white
                            : const Color(0xFF0F172A),
                        backgroundColor: isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFF8FAFC),
                        side: BorderSide(
                          color: isDark
                              ? const Color(0xFF475569)
                              : const Color(0xFFCBD5E1),
                          width: 1.2,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                        ),
                      ),
                      icon: const Icon(
                        Icons.assignment_rounded,
                        size: 17,
                        color: Color(0xFF2563EB),
                      ),
                      label: const Text(
                        'Full Report',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () => _showPotholeDetails(pothole),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPotholeImageThumbnail(String imagePath, bool isDark) {
    if (imagePath.startsWith('http') || imagePath.startsWith('blob:')) {
      return GestureDetector(
        onTap: () => _openImagePreview(imagePath),
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.network(
                  imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      _placeholderThumb(isDark),
                ),
              ),
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 0.8),
                  ),
                  child: const Icon(
                    Icons.zoom_in_rounded,
                    color: Colors.white,
                    size: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _placeholderThumb(isDark);
  }

  Widget _placeholderThumb(bool isDark) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.no_photography_rounded,
            color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
            size: 28,
          ),
          const SizedBox(height: 4),
          Text(
            'No Image',
            style: TextStyle(
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  void _openImagePreview(String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(imageUrl, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRightMapProfileToggle({required bool isMapActive}) {
    if (!kIsWeb) return const SizedBox.shrink();

    return WebViewSwitcher(
      isMapActive: isMapActive,
      showLiveIndicator: true,
      onSelectProfile: isMapActive ? widget.onOpenProfile : null,
      onOpenSettings: () {
        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (ctx) =>
              WebSettingsDialog(onSettingsChanged: () => _applyMapState(() {})),
        );
      },
    );
  }

  /// Clean vertical map control dock with 44px accessible hit targets.
  Widget _buildGisControlDock(bool isDark) {
    final Color dockBg = WebDesign.surface(isDark);
    final Color dockBorder = WebDesign.border(isDark);
    final Color iconSecondary = WebDesign.textSecondary(isDark);
    final Color accentColor = WebDesign.brandOnSurface(isDark);

    Widget dockItem({
      required Widget icon,
      required VoidCallback onTap,
      required String tooltip,
      bool isActive = false,
      Color? activeColor,
    }) {
      return Semantics(
        button: true,
        label: tooltip,
        child: Tooltip(
          message: tooltip,
          preferBelow: false,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(WebDesign.radiusSm),
              child: Container(
                width: WebDesign.touchTarget,
                height: WebDesign.touchTarget,
                decoration: isActive
                    ? BoxDecoration(
                        color: (activeColor ?? accentColor).withValues(
                          alpha: 0.14,
                        ),
                        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                      )
                    : null,
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      );
    }

    Widget dockDivider() => Container(
      width: 28,
      height: 1,
      color: dockBorder,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );

    return Container(
      width: 48,
      decoration: BoxDecoration(
        color: dockBg,
        borderRadius: BorderRadius.circular(WebDesign.radiusMd),
        border: Border.all(color: dockBorder, width: 1.0),
        boxShadow: WebDesign.shadowSm(isDark),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          dockItem(
            icon: Icon(Icons.add_rounded, color: iconSecondary, size: 20),
            tooltip: 'Zoom in',
            onTap: () {
              try {
                final c = _mapController.camera;
                _animatedMapMove(c.center, (c.zoom + 1.0).clamp(3.0, 19.0));
              } catch (_) {}
            },
          ),
          dockItem(
            icon: Icon(Icons.remove_rounded, color: iconSecondary, size: 20),
            tooltip: 'Zoom out',
            onTap: () {
              try {
                final c = _mapController.camera;
                _animatedMapMove(c.center, (c.zoom - 1.0).clamp(3.0, 19.0));
              } catch (_) {}
            },
          ),
          dockDivider(),
          dockItem(
            icon: Icon(
              Icons.my_location_rounded,
              color: _followMode == FollowMode.location
                  ? accentColor
                  : iconSecondary,
              size: 19,
            ),
            tooltip: 'Center on my location',
            isActive: _followMode == FollowMode.location,
            onTap: () {
              if (_currentPosition != null) {
                _animatedMapMove(_currentPosition!, 16.5);
              }
              unawaited(_determinePosition(requestPermission: true));
            },
          ),
          dockItem(
            icon: Icon(
              Icons.local_fire_department_rounded,
              color: _showHeatmap
                  ? WebDesign.statusStyle(StatusTone.pending, isDark).fg
                  : iconSecondary,
              size: 20,
            ),
            tooltip: 'Heatmap',
            isActive: _showHeatmap,
            activeColor: WebDesign.statusStyle(StatusTone.pending, isDark).fg,
            onTap: () => _applyMapState(() => _showHeatmap = !_showHeatmap),
          ),
          dockItem(
            icon: Icon(
              Icons.legend_toggle_rounded,
              color: _isLegendOpen ? accentColor : iconSecondary,
              size: 20,
            ),
            tooltip: 'Map key',
            isActive: _isLegendOpen,
            onTap: () => _applyMapState(() => _isLegendOpen = !_isLegendOpen),
          ),
          dockDivider(),
          dockItem(
            icon: Icon(
              Icons.directions_rounded,
              color: _isRoutePlanningMode ? accentColor : iconSecondary,
              size: 20,
            ),
            tooltip: 'Directions / Plan Route',
            isActive: _isRoutePlanningMode,
            onTap: () {
              _applyMapState(() {
                _isRoutePlanningMode = true;
                _isSidePanelCollapsed = false;
                if (_originController.text.trim().isEmpty) {
                  _originController.text = 'Your location';
                  _customOrigin = null;
                }
              });
              final targetDest =
                  _destination ??
                  (_routePoints.isNotEmpty ? _routePoints.last : null);
              if (targetDest != null) {
                _calculateRoute(targetDest, customOrigin: _customOrigin);
              } else if (_searchController.text.isNotEmpty) {
                _searchAndRoute();
              }
            },
          ),
          dockDivider(),
          dockItem(
            icon: Transform.rotate(
              angle: -(_safeMapRotation * math.pi / 180.0),
              child: Icon(
                _safeMapRotation.abs() > 0.5
                    ? Icons.explore_rounded
                    : (_followMode == FollowMode.compass
                          ? Icons.explore_rounded
                          : Icons.navigation_rounded),
                color: _safeMapRotation.abs() > 0.5
                    ? WebDesign.danger(isDark)
                    : (_followMode == FollowMode.compass
                          ? accentColor
                          : iconSecondary),
                size: 20,
              ),
            ),
            tooltip: _safeMapRotation.abs() > 0.5
                ? 'Reset to North (0°)'
                : 'Toggle Compass / Navigation Mode',
            onTap: () {
              if (_mapController.camera.rotation.abs() > 0.5) {
                _mapController.rotate(0.0);
              } else {
                _toggleFollowMode();
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Paints a gradient vision cone matching Google Maps style.
class VisionConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        colors: [
          Colors.blue.withValues(alpha: 0.6),
          Colors.blue.withValues(alpha: 0.0),
        ],
        stops: const [0.1, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    final path = Path();
    path.moveTo(center.dx, center.dy);

    const sweepAngle = 1.8;
    const startAngle = -1.5708 - (sweepAngle / 2);

    path.arcTo(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
    );
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

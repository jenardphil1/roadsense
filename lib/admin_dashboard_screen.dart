import 'road_sense_brand.dart';
import 'sta_maria_sample_potholes.dart' show isSampleStaMariaMarkerId;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'admin_barangay_insights_view.dart';
import 'admin_forecast_metrics.dart';
import 'admin_map_view.dart';
import 'admin_overview_view.dart';
import 'admin_report_query.dart';
import 'admin_review_queue_view.dart';
import 'admin_trash_view.dart';
import 'admin_users_settings_view.dart';
import 'app_settings.dart';
import 'approval_priority.dart';
import 'cloud_service.dart';
import 'settings_dialog.dart';
import 'web_components.dart';
import 'web_design.dart';

enum _AdminSection {
  overview('Monitoring', 'Overview'),
  queue('Moderation', 'Review Queue'),
  map('Spatial', 'Admin Map'),
  barangay('Governance', 'Barangay Insights'),
  trash('Archive', 'Trash'),
  usersSettings('Administration', 'Users & Settings');

  final String group;
  final String title;
  const _AdminSection(this.group, this.title);
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  _AdminSection _section = _AdminSection.overview;
  late Future<String> _roleFuture;
  AdminReportFilter _queueFilter = const AdminReportFilter(
    statuses: {AdminReportStatus.pending},
    sort: AdminReportSort.priority,
  );
  static const _defaultMapFilter = AdminReportFilter(
    statuses: {AdminReportStatus.approved},
    sort: AdminReportSort.newest,
  );
  AdminReportFilter _mapFilter = _defaultMapFilter;
  String? _selectedReportId;
  LatLng? _mapFocusTarget;
  int _mapFocusNonce = 0;

  Position? _adminPosition;
  bool _isFetchingAdminPosition = false;

  bool _isGeocodingLgu = false;
  int _geocodedDone = 0;
  int _geocodedTotal = 0;

  @override
  void initState() {
    super.initState();
    final user = CloudService.instance.currentUser;
    _roleFuture = user != null
        ? CloudService.instance.getUserRole(user.uid)
        : Future.value('user');
  }

  Future<void> _fetchAdminPosition() async {
    if (_isFetchingAdminPosition) return;
    setState(() => _isFetchingAdminPosition = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 6),
          ),
        );
        if (mounted) {
          setState(() {
            _adminPosition = pos;
            _isFetchingAdminPosition = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _isFetchingAdminPosition = false);
    }
  }

  Future<void> _handleSoftDelete(AdminReportRow row) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await CloudService.instance.softDeletePothole(
      row.id,
      previousStatus: row.status.wireValue,
    );
    if (!mounted) return;
    if (_selectedReportId == row.id) {
      setState(() => _selectedReportId = null);
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Report #${row.shortId} moved to Trash.'),
        backgroundColor: WebDesign.surface(isDark),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            await CloudService.instance.restorePothole(
              row.id,
              targetStatus: row.status.wireValue,
            );
          },
        ),
      ),
    );
  }

  Future<int> _handleBulkSoftDelete(List<AdminReportRow> targets) async {
    final count = await CloudService.instance.bulkSoftDeletePotholes([
      for (final t in targets)
        (docId: t.id, previousStatus: t.status.wireValue),
    ]);
    if (mounted &&
        _selectedReportId != null &&
        targets.any((t) => t.id == _selectedReportId)) {
      setState(() => _selectedReportId = null);
    }
    return count;
  }

  Future<void> _startGeocodeBackfill(List<AdminReportRow> activeRows) async {
    final targets = activeRows.where((r) {
      if (!r.hasValidCoordinates) return false;
      final b = r.barangay.trim();
      final c = r.city.trim();
      return b.isEmpty ||
          b == 'Unassigned Barangay' ||
          c.isEmpty ||
          c == 'Unclassified Area';
    }).toList();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'All reports with valid GPS coordinates already have Barangay & City metadata.',
          isDark: isDark,
          tone: StatusTone.approved,
        ),
      );
      return;
    }

    setState(() {
      _isGeocodingLgu = true;
      _geocodedDone = 0;
      _geocodedTotal = targets.length;
    });

    var updated = 0;
    for (final row in targets) {
      if (!_isGeocodingLgu || !mounted) break;
      try {
        final info = await CloudService.instance.reverseGeocodeLgu(
          row.location!,
        );
        await CloudService.instance.updatePotholeLguLocation(
          row.id,
          barangay: info.barangay,
          city: info.city,
          province: info.province,
          formattedAddress: info.formattedAddress,
        );
        updated++;
      } catch (_) {}
      if (mounted) {
        setState(() => _geocodedDone++);
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    if (mounted) {
      setState(() => _isGeocodingLgu = false);
      ScaffoldMessenger.of(context).showSnackBar(
        WebDesign.snack(
          'Updated LGU metadata for $updated report(s).',
          isDark: isDark,
          tone: StatusTone.approved,
        ),
      );
    }
  }

  void _openQueueWithFilter(AdminReportFilter filter) {
    setState(() {
      _queueFilter = filter;
      _section = _AdminSection.queue;
    });
  }

  void _focusMapOnReport(LatLng location, AdminReportRow row) {
    setState(() {
      _selectedReportId = row.id;
      _mapFocusTarget = location;
      _mapFocusNonce++;
      // An explicit Locate action must still reveal its target report.
      _mapFilter = AdminReportFilter(
        statuses: {row.status},
        sort: AdminReportSort.newest,
      );
      _section = _AdminSection.map;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, _, _) {
        final isDark = AppSettings.instance.isDarkMode;
        return FutureBuilder<String>(
          future: _roleFuture,
          builder: (context, roleSnapshot) {
            if (roleSnapshot.connectionState != ConnectionState.done) {
              return Scaffold(
                backgroundColor: WebDesign.bg(isDark),
                body: const Center(child: CircularProgressIndicator()),
              );
            }

            final role = roleSnapshot.data ?? 'user';
            final isAdmin = role == 'admin' || role == 'super_admin';
            final isSuperAdmin = role == 'super_admin';
            final user = CloudService.instance.currentUser;

            if (!isAdmin) {
              return Scaffold(
                backgroundColor: WebDesign.bg(isDark),
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(WebDesign.space6),
                    child: WebCard(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 40,
                              color: WebDesign.danger(isDark),
                            ),
                            const SizedBox(height: WebDesign.space3),
                            Text(
                              'Administrator Access Required',
                              style: Theme.of(context).textTheme.titleLarge,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: WebDesign.space2),
                            Text(
                              'This account does not have verified administrator privileges in RoadSense.',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: WebDesign.space4),
                            OutlinedButton.icon(
                              onPressed: () async =>
                                  CloudService.instance.signOut(),
                              icon: const Icon(Icons.logout_rounded, size: 16),
                              label: const Text('Sign Out'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return StreamBuilder<QuerySnapshot>(
              stream: CloudService.instance.streamAllPotholes(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Scaffold(
                    backgroundColor: WebDesign.bg(isDark),
                    body: Center(
                      child: EmptyState(
                        icon: Icons.cloud_off_rounded,
                        title: 'Unable to load municipal report stream',
                        message: '${snap.error}',
                      ),
                    ),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return Scaffold(
                    backgroundColor: WebDesign.bg(isDark),
                    body: const Center(child: CircularProgressIndicator()),
                  );
                }

                final docs = snap.data?.docs ?? const <QueryDocumentSnapshot>[];
                final allRows = [
                  for (final d in docs)
                    if (!isSampleStaMariaMarkerId(d.id))
                      AdminReportRow.fromMap(
                        d.id,
                        d.data() as Map<String, dynamic>? ?? const {},
                      ),
                ];
                final activeRows = allRows
                    .where((r) => r.status != AdminReportStatus.deleted)
                    .toList();
                final trashedRows = allRows
                    .where((r) => r.status == AdminReportStatus.deleted)
                    .toList();
                final pendingCount = activeRows
                    .where((r) => r.status == AdminReportStatus.pending)
                    .length;

                final priorities = ApprovalPriority.rankAll(docs);
                final insights = computeAdminBarangayInsights(activeRows);
                final adminPosLatLng = _adminPosition != null
                    ? LatLng(
                        _adminPosition!.latitude,
                        _adminPosition!.longitude,
                      )
                    : null;

                return StreamBuilder<bool>(
                  stream: CloudService.instance.streamAutoAcceptSetting(),
                  builder: (context, autoSnap) {
                    final isAutoAccept = autoSnap.data ?? false;
                    final viewportWidth = MediaQuery.sizeOf(context).width;
                    final isDesktop =
                        viewportWidth >= WebDesign.desktopBreakpoint;

                    final sidebar = _AdminSidebar(
                      section: _section,
                      pendingCount: pendingCount,
                      activeCount: activeRows.length,
                      trashedCount: trashedRows.length,
                      displayName: user?.displayName ?? 'Administrator',
                      email: user?.email ?? '',
                      role: role,
                      onSelectSection: (next) {
                        setState(() {
                          if (next == _AdminSection.map) {
                            _mapFilter = _defaultMapFilter;
                            _selectedReportId = null;
                            _mapFocusTarget = null;
                          }
                          _section = next;
                        });
                        if (!isDesktop) {
                          Navigator.of(context).maybePop();
                        }
                      },
                      onSignOut: () async => CloudService.instance.signOut(),
                    );

                    return Scaffold(
                      backgroundColor: WebDesign.bg(isDark),
                      drawer: isDesktop ? null : Drawer(child: sidebar),
                      body: Row(
                        children: [
                          if (isDesktop) sidebar,
                          Expanded(
                            child: Column(
                              children: [
                                _AdminHeaderBar(
                                  section: _section,
                                  isDesktop: isDesktop,
                                  isDark: isDark,
                                  role: role,
                                  isAutoAccept: isAutoAccept,
                                  onNavigateSettings: () => setState(
                                    () =>
                                        _section = _AdminSection.usersSettings,
                                  ),
                                  onToggleTheme: () {
                                    AppSettings.instance.toggleTheme(!isDark);
                                    setState(() {});
                                  },
                                  onOpenWebSettings: () {
                                    showDialog<void>(
                                      context: context,
                                      builder: (_) => WebSettingsDialog(
                                        showMapPinPicker: false,
                                        onSettingsChanged: () =>
                                            setState(() {}),
                                      ),
                                    );
                                  },
                                ),
                                Expanded(
                                  child: switch (_section) {
                                    _AdminSection.overview => AdminOverviewView(
                                      activeRows: activeRows,
                                      trashedRows: trashedRows,
                                      priorities: priorities,
                                      barangayInsights: insights,
                                      isAutoAccept: isAutoAccept,
                                      snapshotLoadedAt: DateTime.now(),
                                      onNavigateQueuePending: () =>
                                          _openQueueWithFilter(
                                            const AdminReportFilter(
                                              statuses: {
                                                AdminReportStatus.pending,
                                              },
                                              sort: AdminReportSort.priority,
                                            ),
                                          ),
                                      onNavigateQueueSlaBreached: () =>
                                          _openQueueWithFilter(
                                            const AdminReportFilter(
                                              statuses: {
                                                AdminReportStatus.pending,
                                              },
                                              onlySlaBreached: true,
                                              sort: AdminReportSort.priority,
                                            ),
                                          ),
                                      onNavigateQueueApproved: () =>
                                          _openQueueWithFilter(
                                            const AdminReportFilter(
                                              statuses: {
                                                AdminReportStatus.approved,
                                              },
                                              sort: AdminReportSort.newest,
                                            ),
                                          ),
                                      onNavigateQueueRejected: () =>
                                          _openQueueWithFilter(
                                            const AdminReportFilter(
                                              statuses: {
                                                AdminReportStatus.rejected,
                                              },
                                              sort: AdminReportSort.newest,
                                            ),
                                          ),
                                      onNavigateQueueHighSeverity: () =>
                                          _openQueueWithFilter(
                                            const AdminReportFilter(
                                              statuses: {},
                                              severities: {AdminSeverity.high},
                                              sort: AdminReportSort.newest,
                                            ),
                                          ),
                                      onFilterByDefectClass: (name) =>
                                          _openQueueWithFilter(
                                            AdminReportFilter(
                                              statuses: const {},
                                              defectClasses: {name},
                                              sort: AdminReportSort.newest,
                                            ),
                                          ),
                                      onNavigateBarangayInsights: () =>
                                          setState(
                                            () => _section =
                                                _AdminSection.barangay,
                                          ),
                                      onNavigateSettings: () => setState(
                                        () => _section =
                                            _AdminSection.usersSettings,
                                      ),
                                      onInspectHotspot: (center, lead) {
                                        setState(() {
                                          _selectedReportId = lead?.id;
                                          _mapFocusTarget = center;
                                          _mapFocusNonce++;
                                          _mapFilter = const AdminReportFilter(
                                            statuses: {},
                                            sort: AdminReportSort.newest,
                                          );
                                          _section = _AdminSection.map;
                                        });
                                      },
                                    ),
                                    _AdminSection.queue => AdminReviewQueueView(
                                      activeRows: activeRows,
                                      priorities: priorities,
                                      filter: _queueFilter,
                                      onFilterChanged: (next) =>
                                          setState(() => _queueFilter = next),
                                      selectedReportId: _selectedReportId,
                                      onSelectReportId: (id) => setState(
                                        () => _selectedReportId = id,
                                      ),
                                      isSuperAdmin: isSuperAdmin,
                                      adminPosition: adminPosLatLng,
                                      isFetchingAdminPosition:
                                          _isFetchingAdminPosition,
                                      onRequestAdminPosition:
                                          _fetchAdminPosition,
                                      onLocateOnMap: _focusMapOnReport,
                                      onSoftDelete: _handleSoftDelete,
                                      onBulkSoftDelete: _handleBulkSoftDelete,
                                    ),
                                    _AdminSection.map => AdminMapView(
                                      activeRows: activeRows,
                                      priorities: priorities,
                                      filter: _mapFilter,
                                      onFilterChanged: (next) => setState(() {
                                        _mapFilter = next;
                                        _selectedReportId = null;
                                        _mapFocusTarget = null;
                                      }),
                                      selectedReportId: _selectedReportId,
                                      onSelectReportId: (id) => setState(
                                        () => _selectedReportId = id,
                                      ),
                                      requestedFocusLocation: _mapFocusTarget,
                                      focusRequestNonce: _mapFocusNonce,
                                      onSoftDelete: _handleSoftDelete,
                                    ),
                                    _AdminSection.barangay =>
                                      AdminBarangayInsightsView(
                                        insights: insights,
                                        isGeocoding: _isGeocodingLgu,
                                        geocodedDone: _geocodedDone,
                                        geocodedTotal: _geocodedTotal,
                                        onStartGeocodeBackfill: () =>
                                            _startGeocodeBackfill(activeRows),
                                        onStopGeocodeBackfill: () => setState(
                                          () => _isGeocodingLgu = false,
                                        ),
                                        onViewReportsInBarangay: (brgy) =>
                                            _openQueueWithFilter(
                                              AdminReportFilter(
                                                statuses: const {},
                                                barangayFilterKey:
                                                    brgy.canonicalKey,
                                                barangayDisplayLabel:
                                                    brgy.barangay,
                                                sort: AdminReportSort.newest,
                                              ),
                                            ),
                                        onFocusBarangayOnMap:
                                            (target, name, key) {
                                              setState(() {
                                                _mapFilter = _defaultMapFilter
                                                    .copyWith(
                                                      barangayFilterKey: key,
                                                      barangayDisplayLabel:
                                                          name,
                                                    );
                                                _selectedReportId = null;
                                                _mapFocusTarget = target;
                                                _mapFocusNonce++;
                                                _section = _AdminSection.map;
                                              });
                                            },
                                      ),
                                    _AdminSection.trash => AdminTrashView(
                                      trashedRows: trashedRows,
                                    ),
                                    _AdminSection.usersSettings =>
                                      AdminUsersSettingsView(
                                        activeRows: activeRows,
                                        priorities: priorities,
                                        isSuperAdmin: isSuperAdmin,
                                        currentUid: user?.uid ?? '',
                                      ),
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _AdminSidebar extends StatelessWidget {
  final _AdminSection section;
  final int pendingCount;
  final int activeCount;
  final int trashedCount;
  final String displayName;
  final String email;
  final String role;
  final ValueChanged<_AdminSection> onSelectSection;
  final VoidCallback onSignOut;

  const _AdminSidebar({
    required this.section,
    required this.pendingCount,
    required this.activeCount,
    required this.trashedCount,
    required this.displayName,
    required this.email,
    required this.role,
    required this.onSelectSection,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    final initialSource = displayName.trim().isNotEmpty
        ? displayName.trim()
        : email.trim();
    final initial = initialSource.isNotEmpty
        ? initialSource[0].toUpperCase()
        : 'A';

    return Container(
      width: WebDesign.sidebarWidth,
      decoration: BoxDecoration(
        color: WebDesign.surface(isDark),
        border: Border(right: BorderSide(color: WebDesign.border(isDark))),
      ),
      child: Column(
        children: [
          Container(
            height: WebDesign.headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: WebDesign.space4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: WebDesign.border(isDark)),
              ),
            ),
            child: Row(
              children: [
                const RoadSenseBrand(size: 32),
                const SizedBox(width: WebDesign.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'RoadSense Admin',
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        role == 'super_admin'
                            ? 'Super Admin Workspace'
                            : 'Municipal Operations',
                        style: theme.textTheme.bodySmall,
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Eyebrow('Operations'),
                ),
                _SidebarNavTile(
                  label: 'Overview',
                  icon: Icons.insights_outlined,
                  activeIcon: Icons.insights_rounded,
                  selected: section == _AdminSection.overview,
                  onTap: () => onSelectSection(_AdminSection.overview),
                ),
                _SidebarNavTile(
                  label: 'Review Queue',
                  icon: Icons.inbox_outlined,
                  activeIcon: Icons.inbox_rounded,
                  selected: section == _AdminSection.queue,
                  badgeCount: pendingCount,
                  badgeTone: StatusTone.pending,
                  onTap: () => onSelectSection(_AdminSection.queue),
                ),
                _SidebarNavTile(
                  label: 'Admin Map',
                  icon: Icons.map_outlined,
                  activeIcon: Icons.map_rounded,
                  selected: section == _AdminSection.map,
                  badgeCount: activeCount,
                  badgeTone: StatusTone.info,
                  onTap: () => onSelectSection(_AdminSection.map),
                ),
                const SizedBox(height: WebDesign.space4),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Eyebrow('Archive'),
                ),
                _SidebarNavTile(
                  label: 'Trash',
                  icon: Icons.delete_outline_rounded,
                  activeIcon: Icons.delete_rounded,
                  selected: section == _AdminSection.trash,
                  badgeCount: trashedCount > 0 ? trashedCount : null,
                  badgeTone: StatusTone.neutral,
                  onTap: () => onSelectSection(_AdminSection.trash),
                ),
                const SizedBox(height: WebDesign.space4),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Eyebrow('Governance'),
                ),
                _SidebarNavTile(
                  label: 'Users & Settings',
                  icon: Icons.admin_panel_settings_outlined,
                  activeIcon: Icons.admin_panel_settings_rounded,
                  selected: section == _AdminSection.usersSettings,
                  onTap: () => onSelectSection(_AdminSection.usersSettings),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: WebDesign.border(isDark)),
          Padding(
            padding: const EdgeInsets.all(WebDesign.space3),
            child: Container(
              padding: const EdgeInsets.all(WebDesign.space2),
              decoration: BoxDecoration(
                color: WebDesign.sunken(isDark),
                borderRadius: BorderRadius.circular(WebDesign.radiusMd),
                border: Border.all(color: WebDesign.border(isDark)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: WebDesign.brand(isDark),
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: WebDesign.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName.trim().isNotEmpty
                              ? displayName
                              : 'Admin Account',
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          role.toUpperCase().replaceAll('_', ' '),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: WebDesign.textMuted(isDark),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sign Out',
                    onPressed: onSignOut,
                    color: WebDesign.danger(isDark),
                    icon: const Icon(Icons.logout_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarNavTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool selected;
  final int? badgeCount;
  final StatusTone badgeTone;
  final VoidCallback onTap;

  const _SidebarNavTile({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onTap,
    this.badgeCount,
    this.badgeTone = StatusTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = selected
        ? WebDesign.brandOnSurface(isDark)
        : WebDesign.textSecondary(isDark);
    final badgeStyle = WebDesign.statusStyle(badgeTone, isDark);

    return Semantics(
      button: true,
      selected: selected,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected ? WebDesign.brandWash(isDark) : Colors.transparent,
          borderRadius: BorderRadius.circular(WebDesign.radiusSm),
          child: InkWell(
            borderRadius: BorderRadius.circular(WebDesign.radiusSm),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: WebDesign.touchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: WebDesign.space3,
                  vertical: WebDesign.space2,
                ),
                child: Row(
                  children: [
                    Icon(selected ? activeIcon : icon, size: 18, color: fg),
                    const SizedBox(width: WebDesign.space3),
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: selected
                              ? WebDesign.textPrimary(isDark)
                              : WebDesign.textSecondary(isDark),
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badgeCount != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeStyle.bg,
                          borderRadius: BorderRadius.circular(
                            WebDesign.radiusPill,
                          ),
                          border: Border.all(color: badgeStyle.outline),
                        ),
                        child: Text(
                          '$badgeCount',
                          style: WebDesign.tabular(
                            TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: badgeStyle.fg,
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
      ),
    );
  }
}

class _AdminHeaderBar extends StatelessWidget {
  final _AdminSection section;
  final bool isDesktop;
  final bool isDark;
  final String role;
  final bool isAutoAccept;
  final VoidCallback onNavigateSettings;
  final VoidCallback onToggleTheme;
  final VoidCallback onOpenWebSettings;

  const _AdminHeaderBar({
    required this.section,
    required this.isDesktop,
    required this.isDark,
    required this.role,
    required this.isAutoAccept,
    required this.onNavigateSettings,
    required this.onToggleTheme,
    required this.onOpenWebSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final isPhoneLandscape = size.width > size.height && size.height < 560;
    return Material(
      color: WebDesign.surface(isDark),
      child: SafeArea(
        bottom: false,
        child: Container(
          height: isPhoneLandscape
              ? 48.0
              : (isDesktop
                    ? WebDesign.headerHeight
                    : WebDesign.headerHeightMobile),
          padding: EdgeInsets.symmetric(
            horizontal: isDesktop ? WebDesign.space5 : WebDesign.space3,
          ),
          decoration: BoxDecoration(
            color: WebDesign.surface(isDark),
            border: Border(bottom: BorderSide(color: WebDesign.border(isDark))),
          ),
          child: Row(
            children: [
              if (!isDesktop)
                Padding(
                  padding: const EdgeInsets.only(right: WebDesign.space2),
                  child: IconButton(
                    tooltip: 'Open navigation menu',
                    icon: const Icon(Icons.menu_rounded),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isPhoneLandscape) Eyebrow(section.group),
                    Text(
                      section.title,
                      style: isPhoneLandscape
                          ? theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            )
                          : theme.textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
          if (isDesktop) ...[
            InkWell(
              borderRadius: BorderRadius.circular(WebDesign.radiusPill),
              onTap: onNavigateSettings,
              child: Tooltip(
                message:
                    'Manage Auto-Accept moderation policy in Users & Settings',
                child: StatusChip(
                  tone: isAutoAccept ? StatusTone.pending : StatusTone.approved,
                  label: isAutoAccept ? 'Auto-Accept ON' : 'Manual Review',
                  dense: true,
                ),
              ),
            ),
            const SizedBox(width: WebDesign.space2),
            StatusChip(
              tone: role == 'super_admin'
                  ? StatusTone.info
                  : StatusTone.neutral,
              label: role.toUpperCase().replaceAll('_', ' '),
              dense: true,
            ),
            const SizedBox(width: WebDesign.space2),
          ],
          IconButton(
            tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
            onPressed: onToggleTheme,
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: 'Open Web Settings',
            onPressed: onOpenWebSettings,
            icon: const Icon(Icons.tune_rounded, size: 20),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

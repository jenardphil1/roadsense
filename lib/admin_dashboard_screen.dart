import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:universal_html/html.dart' as html;
import 'approval_priority.dart';
import 'cloud_service.dart';
import 'app_settings.dart';
import 'settings_dialog.dart';
import 'web_components.dart';
import 'web_design.dart';

class AdminPotholeItem {
  final String id;
  final LatLng location;
  final Map<String, dynamic> data;

  AdminPotholeItem({
    required this.id,
    required this.location,
    required this.data,
  });

  String get status => (data['status'] as String? ?? 'pending').toLowerCase();
  String get severity => (data['overallSeverity'] as String? ?? 'medium').toLowerCase();
}

class AdminPotholeCluster {
  final String id;
  final LatLng center;
  final List<AdminPotholeItem> items;

  AdminPotholeCluster({
    required this.id,
    required this.center,
    required this.items,
  });

  bool get isSingle => items.length <= 1;
  AdminPotholeItem get singleItem => items.first;

  int get approvedCount => items.where((i) => i.status == 'approved').length;
  int get pendingCount => items.where((i) => i.status == 'pending').length;
  int get rejectedCount => items.where((i) => i.status == 'rejected').length;

  bool get hasPending => pendingCount > 0;
  bool get hasApproved => approvedCount > 0;
  bool get isMixed => hasPending && hasApproved;
}

class SpiderLinesPainter extends CustomPainter {
  final List<Offset> childOffsets;
  final bool isDark;

  SpiderLinesPainter({
    required this.childOffsets,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final linePaint = Paint()
      ..color = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: isDark ? 0.35 : 0.18)
      ..strokeWidth = 3.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);

    for (final offset in childOffsets) {
      final target = center + offset;
      canvas.drawLine(center, target, shadowPaint);
      canvas.drawLine(center, target, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant SpiderLinesPainter oldDelegate) {
    return oldDelegate.childOffsets != childOffsets ||
        oldDelegate.isDark != isDark;
  }
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with TickerProviderStateMixin {
  late MapController _mapController;
  int _selectedIndex =
      0; // 0: Overview, 1: Pending, 2: Approved, 3: Map, 4: Users
  String _mapFilterMode = 'approved'; // 'approved', 'pending', 'all'
  late Future<String> _roleFuture;

  LatLng? _selectedPotholeLocation;
  String? _selectedPotholeId;
  Map<String, dynamic>? _selectedPotholeData;
  String? _expandedClusterId;

  // Sorting & Location-based Filtering State
  String _listSortMode = 'priority'; // 'newest', 'oldest', 'proximity', 'severity', 'priority'
  String _listSeverityFilter = 'all'; // 'all', 'high', 'medium', 'low'
  Position? _adminPosition;
  bool _isFetchingAdminPosition = false;

  final TextEditingController _listSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    final user = CloudService.instance.currentUser;
    _roleFuture = user != null
        ? CloudService.instance.getUserRole(user.uid)
        : Future.value('user');
    _fetchAdminPosition();
  }

  @override
  void dispose() {
    _listSearchController.dispose();
    super.dispose();
  }

  /// Silently requests or gets the admin's current GPS position for proximity calculations
  Future<void> _fetchAdminPosition() async {
    if (_isFetchingAdminPosition) return;
    setState(() => _isFetchingAdminPosition = true);
    try {
      LocationPermission perm = await Geolocator.checkPermission();
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

  /// Extracts DateTime object reliably from Firestore data
  DateTime _extractTimestamp(Map<String, dynamic> data) {
    final ts = data['timestamp'];
    if (ts is Timestamp) return ts.toDate();
    if (ts is String) {
      final parsed = DateTime.tryParse(ts);
      if (parsed != null) return parsed;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Formats distance in meters or kilometers from admin's position
  String _formatDistanceToAdmin(double lat, double lng) {
    if (_adminPosition == null) return '';
    final meters = Geolocator.distanceBetween(
      _adminPosition!.latitude,
      _adminPosition!.longitude,
      lat,
      lng,
    );
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)} m away';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km away';
    }
  }

  /// Human-readable relative time formatter
  String _formatReportTime(dynamic timestamp) {
    if (timestamp == null) return 'Recent';
    DateTime? dt;
    if (timestamp is Timestamp) {
      dt = timestamp.toDate();
    } else if (timestamp is String) {
      dt = DateTime.tryParse(timestamp);
    }
    if (dt == null) return 'Recent';

    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  Color _pageBg(bool isDark) => WebDesign.bg(isDark);
  Color _surface(bool isDark) => WebDesign.surface(isDark);
  Color _border(bool isDark) => WebDesign.border(isDark);
  /// Smoothly glides the GIS map camera to a target location and zoom level
  void _animatedMapMove(LatLng destLocation, double destZoom) {
    try {
      final startLat = _mapController.camera.center.latitude;
      final startLng = _mapController.camera.center.longitude;
      final startZoom = _mapController.camera.zoom;

      final latTween = Tween<double>(
        begin: startLat,
        end: destLocation.latitude,
      );
      final lngTween = Tween<double>(
        begin: startLng,
        end: destLocation.longitude,
      );
      final zoomTween = Tween<double>(begin: startZoom, end: destZoom);

      final controller = AnimationController(
        duration: const Duration(milliseconds: 550),
        vsync: this,
      );

      final Animation<double> animation = CurvedAnimation(
        parent: controller,
        curve: Curves.fastOutSlowIn,
      );

      controller.addListener(() {
        try {
          _mapController.move(
            LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
            zoomTween.evaluate(animation),
          );
        } catch (_) {}
      });

      animation.addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          controller.dispose();
        }
      });

      controller.forward();
    } catch (_) {
      try {
        _mapController.move(destLocation, destZoom);
      } catch (_) {}
    }
  }

  void _locatePotholeOnMap(
    LatLng location,
    String docId,
    Map<String, dynamic> data,
  ) {
    final status = data['status'] as String? ?? 'pending';

    setState(() {
      _selectedIndex = 3; // Switch to GIS Map nav item
      _selectedPotholeLocation = location;
      _selectedPotholeId = docId;
      _selectedPotholeData = data;
      _expandedClusterId = null;

      // Automatically sync map filter mode:
      if (status == 'approved') {
        _mapFilterMode = 'approved';
      } else {
        _mapFilterMode = 'pending';
      }
    });

    Future.delayed(const Duration(milliseconds: 250), () {
      _animatedMapMove(location, 17.5);
    });
  }

  List<AdminPotholeCluster> _clusterAdminPotholes(
    List<AdminPotholeItem> potholes, {
    double radiusMeters = 15.0,
  }) {
    if (potholes.isEmpty) return [];

    final List<AdminPotholeCluster> clusters = [];
    final Set<AdminPotholeItem> visited = {};

    for (int i = 0; i < potholes.length; i++) {
      final p1 = potholes[i];
      if (visited.contains(p1)) continue;

      final List<AdminPotholeItem> group = [p1];
      visited.add(p1);

      for (int j = i + 1; j < potholes.length; j++) {
        final p2 = potholes[j];
        if (visited.contains(p2)) continue;

        final dist = Geolocator.distanceBetween(
          p1.location.latitude,
          p1.location.longitude,
          p2.location.latitude,
          p2.location.longitude,
        );

        if (dist <= radiusMeters) {
          group.add(p2);
          visited.add(p2);
        }
      }

      double sumLat = 0;
      double sumLng = 0;
      for (final p in group) {
        sumLat += p.location.latitude;
        sumLng += p.location.longitude;
      }
      final center = LatLng(sumLat / group.length, sumLng / group.length);
      final id = group.map((p) => p.id).join('_');

      clusters.add(AdminPotholeCluster(id: id, center: center, items: group));
    }

    return clusters;
  }

  Widget _buildMergedAdminClusterMarker({
    required AdminPotholeCluster cluster,
    required double size,
    required bool isDark,
    required bool isSelected,
  }) {
    final int totalCount = cluster.items.length;
    final bool isMixed = cluster.isMixed;
    final bool hasPending = cluster.hasPending;

    final Color primaryColor = isMixed
        ? const Color(0xFF2563EB)
        : (hasPending ? const Color(0xFFF59E0B) : const Color(0xFF10B981));

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _surface(isDark),
        border: Border.all(
          color: isSelected ? const Color(0xFF2563EB) : primaryColor,
          width: isSelected ? 3.0 : 2.2,
        ),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: isDark ? 0.45 : 0.25),
            blurRadius: 10,
            spreadRadius: 1,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.layers_rounded,
                  size: (size * 0.40).clamp(12.0, 20.0),
                  color: primaryColor,
                ),
                Text(
                  '$totalCount',
                  style: TextStyle(
                    fontSize: (size * 0.28).clamp(9.0, 13.0),
                    fontWeight: FontWeight.w900,
                    color: primaryColor,
                  ),
                ),
              ],
            ),
            if (isMixed)
              Positioned(
                top: 2,
                right: 2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF59E0B),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminSpiderClusterMarker(
    AdminPotholeCluster cluster,
    bool isDark,
  ) {
    final count = cluster.items.length;
    final double radius = count <= 2 ? 46.0 : (count <= 4 ? 54.0 : 66.0);
    final double boxSize = (radius + 28.0) * 2;
    final double centerXY = boxSize / 2;

    final List<Offset> childOffsets = [];
    for (int i = 0; i < count; i++) {
      final double angle = -math.pi / 2 + (i * 2 * math.pi / count);
      childOffsets.add(
        Offset(radius * math.cos(angle), radius * math.sin(angle)),
      );
    }

    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(boxSize, boxSize),
            painter: SpiderLinesPainter(
              childOffsets: childOffsets,
              isDark: isDark,
            ),
          ),
          Positioned(
            left: centerXY - 12,
            top: centerXY - 12,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _expandedClusterId = null;
                });
              },
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                  border: Border.all(
                    color: const Color(0xFF2563EB),
                    width: 3.0,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (int i = 0; i < count; i++) ...[
            Positioned(
              left: centerXY + childOffsets[i].dx - 16,
              top: centerXY + childOffsets[i].dy - 16,
              child: GestureDetector(
                onTap: () {
                  final item = cluster.items[i];
                  setState(() {
                    _selectedPotholeId = item.id;
                    _selectedPotholeLocation = item.location;
                    _selectedPotholeData = item.data;
                  });
                },
                child: _buildAdminSpiderChildNode(
                  item: cluster.items[i],
                  isSelected: _selectedPotholeId == cluster.items[i].id,
                  isDark: isDark,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdminSpiderChildNode({
    required AdminPotholeItem item,
    required bool isSelected,
    required bool isDark,
  }) {
    Color nodeColor;
    IconData nodeIcon;

    if (item.status == 'pending') {
      nodeColor = const Color(0xFFF59E0B);
      nodeIcon = Icons.pending_actions_rounded;
    } else if (item.status == 'rejected') {
      nodeColor = const Color(0xFF64748B);
      nodeIcon = Icons.cancel_rounded;
    } else {
      nodeColor = const Color(0xFF10B981);
      nodeIcon = Icons.verified_rounded;
    }

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: nodeColor,
        border: Border.all(
          color: isSelected ? Colors.white : (isDark ? const Color(0xFF0F172A) : Colors.white),
          width: isSelected ? 3.0 : 2.0,
        ),
        boxShadow: [
          BoxShadow(
            color: nodeColor.withValues(alpha: 0.5),
            blurRadius: isSelected ? 10 : 5,
            spreadRadius: isSelected ? 2 : 0,
          ),
        ],
      ),
      child: Center(
        child: Icon(
          nodeIcon,
          color: Colors.white,
          size: 15,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        final isDark = AppSettings.instance.isDarkMode;
        return FutureBuilder<String>(
          future: _roleFuture,
          builder: (context, roleSnapshot) {
            if (roleSnapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            final role = roleSnapshot.data ?? 'user';
            final isAdmin = role == 'admin' || role == 'super_admin';
            if (!isAdmin) {
              return const Scaffold(
                body: Center(
                  child: Text('Administrator access is required.'),
                ),
              );
            }
            final isSuperAdmin = role == 'super_admin';

            return StreamBuilder<QuerySnapshot>(
              stream: CloudService.instance.streamAllPotholes(),
              builder: (context, potholeSnapshot) {
                if (potholeSnapshot.hasError) {
                  return Scaffold(
                    backgroundColor: _pageBg(isDark),
                    body: Center(
                      child: Text('Error loading data: ${potholeSnapshot.error}'),
                    ),
                  );
                }
                if (potholeSnapshot.connectionState == ConnectionState.waiting &&
                    !potholeSnapshot.hasData) {
                  return Scaffold(
                    backgroundColor: _pageBg(isDark),
                    body: const Center(
                      child: CircularProgressIndicator(color: Color(0xFF10B981)),
                    ),
                  );
                }

                final docs = potholeSnapshot.data?.docs ?? [];
                final pendingDocs = docs
                    .where(
                      (d) =>
                          (d.data() as Map<String, dynamic>)['status'] == 'pending',
                    )
                    .toList();
                final approvedDocs = docs
                    .where(
                      (d) =>
                          (d.data() as Map<String, dynamic>)['status'] ==
                          'approved',
                    )
                    .toList();
                final deletedDocs = docs
                    .where(
                      (d) =>
                          (d.data() as Map<String, dynamic>)['status'] ==
                          'deleted',
                    )
                    .toList();
                final activeDocs = docs
                    .where(
                      (d) =>
                          (d.data() as Map<String, dynamic>)['status'] !=
                          'deleted',
                    )
                    .toList();

                return Scaffold(
                  backgroundColor: _pageBg(isDark),
              drawer: MediaQuery.of(context).size.width < 900
                  ? Drawer(
                      child: _buildWebSidebar(
                        context,
                        isSuperAdmin: isSuperAdmin,
                        pendingCount: pendingDocs.length,
                        approvedCount: approvedDocs.length,
                        deletedCount: deletedDocs.length,
                        totalCount: activeDocs.length,
                        role: role,
                      ),
                    )
                  : null,
              body: LayoutBuilder(
                builder: (context, constraints) {
                  final isDesktop = constraints.maxWidth >= 900;
                  return Row(
                    children: [
                      // Enterprise Left Navigation Sidebar (Desktop)
                      if (isDesktop)
                        _buildWebSidebar(
                          context,
                          isSuperAdmin: isSuperAdmin,
                          pendingCount: pendingDocs.length,
                          approvedCount: approvedDocs.length,
                          deletedCount: deletedDocs.length,
                          totalCount: activeDocs.length,
                          role: role,
                        ),

                      // Main Web Content Canvas
                      Expanded(
                        child: Column(
                          children: [
                            // Corporate Top Header Bar
                            _buildWebHeader(
                              context,
                              isDesktop: isDesktop,
                              isSuperAdmin: isSuperAdmin,
                              role: role,
                              pendingCount: pendingDocs.length,
                            ),

                            // Main View Canvas with Smooth Fade & Slide Page Transition
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder:
                                    (
                                      Widget child,
                                      Animation<double> animation,
                                    ) {
                                      return FadeTransition(
                                        opacity: animation,
                                        child: SlideTransition(
                                          position: Tween<Offset>(
                                            begin: const Offset(0.012, 0),
                                            end: Offset.zero,
                                          ).animate(animation),
                                          child: child,
                                        ),
                                      );
                                    },
                                child: KeyedSubtree(
                                  key: ValueKey<int>(_selectedIndex),
                                  child: _buildCurrentView(
                                    context,
                                    _selectedIndex,
                                    isSuperAdmin,
                                    docs,
                                    pendingDocs,
                                    approvedDocs,
                                    deletedDocs,
                                    activeDocs,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  },
);
}

  /// Helper to route active tab content canvas
  Widget _buildCurrentView(
    BuildContext context,
    int index,
    bool isSuperAdmin,
    List<QueryDocumentSnapshot> docs,
    List<QueryDocumentSnapshot> pendingDocs,
    List<QueryDocumentSnapshot> approvedDocs,
    List<QueryDocumentSnapshot> deletedDocs,
    List<QueryDocumentSnapshot> activeDocs,
  ) {
    switch (index) {
      case 0:
        return _buildAnalyticsOverview(activeDocs, pendingDocs, approvedDocs);
      case 1:
        return _buildPotholeList(
          context,
          pendingDocs,
          allDocs: activeDocs,
          isPendingTab: true,
        );
      case 2:
        return _buildPotholeList(
          context,
          approvedDocs,
          allDocs: activeDocs,
          isPendingTab: false,
        );
      case 3:
        return _buildGisMapView(activeDocs);
      case 4:
        if (isSuperAdmin) return _buildUserManagementView(activeDocs);
        return _buildAnalyticsOverview(activeDocs, pendingDocs, approvedDocs);
      case 5:
        return _buildTrashBinView(
          context,
          deletedDocs,
          allDocs: docs,
        );
      default:
        return _buildAnalyticsOverview(activeDocs, pendingDocs, approvedDocs);
    }
  }

  /// Left navigation rail.
  Widget _buildWebSidebar(
    BuildContext context, {
    required bool isSuperAdmin,
    required int pendingCount,
    required int approvedCount,
    required int deletedCount,
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
          // Brand lockup. Matched to the header bar's height so the sidebar rule
          // and the header rule form one continuous line across the page.
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

          // Navigation, grouped by job rather than one flat list. Indices are
          // unchanged, so `_buildCurrentView` and `titles` still line up.
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

                const SizedBox(height: WebDesign.space4),
                _navGroupLabel('Maintenance'),
                _buildNavItem(
                  index: 5,
                  icon: Icons.delete_outline_rounded,
                  activeIcon: Icons.delete_rounded,
                  label: 'Trash bin',
                  badgeCount: deletedCount,
                  badgeTone: StatusTone.rejected,
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

          // Live sync indicator. Icon plus word, so it does not lean on a dot's
          // colour alone to say "connected".
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
          // both an undersized pointer target and unlabelled.
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
  ///
  /// Badge colour comes from [StatusTone], so a pending count is always amber
  /// and an approved count always green — the same meaning the chips carry.
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
              curve: WebDesign.easeOut,
              // 44px keeps the row a comfortable pointer target; the old row
              // resolved to roughly 38.
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

  /// Top header bar: where you are on the left, what you can do on the right.
  ///
  /// The old bar printed the same string twice — once as the breadcrumb tail and
  /// again as the page title — and left the right side an ungrouped pile of five
  /// controls. Now the breadcrumb names the section, the title names the page,
  /// and the actions are grouped and separated by a rule. The "N pending" badge
  /// is gone because the sidebar already carries that count.
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
      ('Maintenance', 'Trash bin / Archived'),
    ];

    final idx = _selectedIndex.clamp(0, sections.length - 1);
    final section = sections[idx].$1;
    final title = sections[idx].$2;
    final isDark = AppSettings.instance.isDarkMode;
    final text = Theme.of(context).textTheme;

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

          // Auto-Accept / Manual Accept Toggle
          StreamBuilder<bool>(
            stream: CloudService.instance.streamAutoAcceptSetting(),
            builder: (context, autoSnapshot) {
              final isAutoAccept = autoSnapshot.data ?? false;
              return Container(
                margin: const EdgeInsets.only(right: 12),
                child: Tooltip(
                  message: isAutoAccept
                      ? 'Auto-Accept is ACTIVE: New pothole reports are immediately approved and published to the live map.'
                      : 'Manual Review is ACTIVE: New pothole reports require admin approval before appearing on the live map.',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () async {
                        final nextVal = !isAutoAccept;
                        await CloudService.instance.setAutoAcceptSetting(nextVal);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                nextVal
                                    ? '⚡ Auto-Accept Enabled: Submissions will be automatically approved.'
                                    : '📋 Manual Review Enabled: Submissions will require admin review.',
                              ),
                              backgroundColor: nextVal
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFF3B82F6),
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isAutoAccept
                              ? const Color(0xFF10B981)
                                  .withValues(alpha: isDark ? 0.2 : 0.12)
                              : (isDark
                                  ? Colors.white.withValues(alpha: 0.05)
                                  : const Color(0xFFF1F5F9)),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isAutoAccept
                                ? const Color(0xFF10B981)
                                    .withValues(alpha: isDark ? 0.5 : 0.4)
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : const Color(0xFFCBD5E1)),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isAutoAccept
                                  ? Icons.bolt_rounded
                                  : Icons.checklist_rtl_rounded,
                              size: 14,
                              color: isAutoAccept
                                  ? (isDark
                                      ? const Color(0xFF34D399)
                                      : const Color(0xFF059669))
                                  : (isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B)),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              isAutoAccept ? 'AUTO ACCEPT' : 'MANUAL ACCEPT',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: isAutoAccept
                                    ? (isDark
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFF047857))
                                    : (isDark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF475569)),
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Transform.scale(
                              scale: 0.65,
                              child: Switch(
                                value: isAutoAccept,
                                activeTrackColor: const Color(0xFF10B981)
                                    .withValues(alpha: 0.3),
                                activeThumbColor: const Color(0xFF10B981),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onChanged: (val) async {
                                  await CloudService.instance
                                      .setAutoAcceptSetting(val);
                                },
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

          // Role Badge Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isSuperAdmin
                  ? const Color(0xFF7C3AED).withValues(alpha: 0.15)
                  : const Color(0xFF10B981).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSuperAdmin
                    ? const Color(0xFF7C3AED).withValues(alpha: 0.4)
                    : const Color(0xFF10B981).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isSuperAdmin
                      ? Icons.workspace_premium_rounded
                      : Icons.verified_user_rounded,
                  size: 13,
                  color: isSuperAdmin
                      ? const Color(0xFFA78BFA)
                      : const Color(0xFF34D399),
                ),
                const SizedBox(width: 5),
                Text(
                  role.toUpperCase().replaceAll('_', ' '),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: isSuperAdmin
                        ? const Color(0xFFA78BFA)
                        : const Color(0xFF34D399),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          // Quick Theme Mode Toggle Button
          IconButton(
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? const Color(0xFFF59E0B) : const Color(0xFF475569),
              size: 20,
            ),
            onPressed: () {
              AppSettings.instance.toggleTheme(!isDark);
              setState(() {});
            },
          ),

          // Web Settings Dialog Button
          IconButton(
            tooltip: 'Open Web Settings',
            icon: Icon(
              Icons.tune_rounded,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
              size: 20,
            ),
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => WebSettingsDialog(
                  onSettingsChanged: () => setState(() {}),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Analytics Overview Canvas Tab
  Widget _buildAnalyticsOverview(
    List<QueryDocumentSnapshot> allDocs,
    List<QueryDocumentSnapshot> pendingDocs,
    List<QueryDocumentSnapshot> approvedDocs,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stat Metrics Cards Grid
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 800;
              return GridView.count(
                crossAxisCount: isWide ? 4 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: isWide ? 2.2 : 1.6,
                children: [
                  _buildMetricCard(
                    'Total Submissions',
                    '${allDocs.length}',
                    Icons.folder_open_rounded,
                    const Color(0xFF2563EB),
                  ),
                  _buildMetricCard(
                    'Pending Review',
                    '${pendingDocs.length}',
                    Icons.pending_actions_rounded,
                    const Color(0xFFD97706),
                  ),
                  _buildMetricCard(
                    'Approved Hazards',
                    '${approvedDocs.length}',
                    Icons.check_circle_outline_rounded,
                    const Color(0xFF059669),
                  ),
                  _buildMetricCard(
                    'Approval Rate',
                    allDocs.isNotEmpty
                        ? '${((approvedDocs.length / allDocs.length) * 100).toStringAsFixed(0)}%'
                        : '0%',
                    Icons.trending_up_rounded,
                    const Color(0xFF7C3AED),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 24),

          // Main Chart Section Card
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _surface(AppSettings.instance.isDarkMode),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _border(AppSettings.instance.isDarkMode).withValues(alpha: AppSettings.instance.isDarkMode ? 1 : 0.7),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: AppSettings.instance.isDarkMode ? 0.25 : 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hazard Audit Distribution',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: WebDesign.textPrimary(AppSettings.instance.isDarkMode),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Comparison of pending vs verified road hazard reports',
                  style: TextStyle(
                    fontSize: 12,
                    color: WebDesign.textSecondary(AppSettings.instance.isDarkMode),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 280,
                  child: allDocs.isEmpty
                      ? const Center(
                          child: Text(
                            'No pothole data collected yet.',
                            style: TextStyle(color: Color(0xFF94A3B8)),
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: PieChart(
                                PieChartData(
                                  sectionsSpace: 3,
                                  centerSpaceRadius: 55,
                                  sections: [
                                    PieChartSectionData(
                                      color: const Color(0xFFF59E0B),
                                      value: pendingDocs.length.toDouble(),
                                      title: '${pendingDocs.length}',
                                      radius: 60,
                                      titleStyle: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                    PieChartSectionData(
                                      color: const Color(0xFF10B981),
                                      value: approvedDocs.length.toDouble(),
                                      title: '${approvedDocs.length}',
                                      radius: 60,
                                      titleStyle: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildLegendItem(
                                    'Pending Review',
                                    '${pendingDocs.length}',
                                    const Color(0xFFF59E0B),
                                  ),
                                  const SizedBox(height: 12),
                                  _buildLegendItem(
                                    'Approved Live',
                                    '${approvedDocs.length}',
                                    const Color(0xFF10B981),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    final isDark = AppSettings.instance.isDarkMode;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surface(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _border(isDark).withValues(alpha: isDark ? 1 : 0.7),
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              Icon(
                Icons.trending_up_rounded,
                size: 14,
                color: color.withValues(alpha: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, String count, Color color) {
    final isDark = AppSettings.instance.isDarkMode;
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          count,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }

  /// Helper widget to build interactive severity filter chips with badge counts
  Widget _buildSeverityChip({
    required String label,
    required int count,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    final isSelected = _listSeverityFilter == value;
    return InkWell(
      onTap: () {
        setState(() {
          _listSeverityFilter = value;
        });
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: isDark ? 0.25 : 0.15)
              : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? color
                : (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isSelected ? color : color.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected
                    ? (isDark ? Colors.white : color)
                    : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF475569)),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withValues(alpha: 0.3)
                    : (isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFE2E8F0)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected
                      ? (isDark ? Colors.white : color)
                      : (isDark
                          ? const Color(0xFFCBD5E1)
                          : const Color(0xFF475569)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Enterprise Data List Layout with Smart Sorting & Location-based Filtering
  Widget _buildPotholeList(
    BuildContext context,
    List<QueryDocumentSnapshot> rawDocs, {
    required List<QueryDocumentSnapshot> allDocs,
    required bool isPendingTab,
  }) {
    final isDark = AppSettings.instance.isDarkMode;

    // 1. Calculate Severity Totals for Filter Chips
    final totalCount = rawDocs.length;
    final highCount = rawDocs.where((d) {
      final s = ((d.data() as Map<String, dynamic>)['overallSeverity'] as String? ?? '')
          .toLowerCase();
      return s == 'high';
    }).length;
    final medCount = rawDocs.where((d) {
      final s = ((d.data() as Map<String, dynamic>)['overallSeverity'] as String? ?? 'medium')
          .toLowerCase();
      return s == 'medium' || (s != 'high' && s != 'low');
    }).length;
    final lowCount = rawDocs.where((d) {
      final s = ((d.data() as Map<String, dynamic>)['overallSeverity'] as String? ?? '')
          .toLowerCase();
      return s == 'low';
    }).length;

    // 2. Filter Documents by Search Query & Severity
    final q = _listSearchController.text.trim().toLowerCase();
    List<QueryDocumentSnapshot> displayedDocs = rawDocs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final severity = (data['overallSeverity'] as String? ?? 'medium').toLowerCase();

      // Severity filter
      if (_listSeverityFilter != 'all') {
        if (_listSeverityFilter == 'high' && severity != 'high') return false;
        if (_listSeverityFilter == 'medium' && (severity != 'medium' && (severity == 'high' || severity == 'low'))) return false;
        if (_listSeverityFilter == 'low' && severity != 'low') return false;
      }

      // Search query filter
      if (q.isNotEmpty) {
        final name = (data['reporterName'] as String? ?? '').toLowerCase();
        final email = (data['reporterEmail'] as String? ?? '').toLowerCase();
        final address = (data['address'] as String? ?? '').toLowerCase();
        final id = doc.id.toLowerCase();
        final lat = (data['latitude'] as num?)?.toDouble().toString() ?? '';
        final lng = (data['longitude'] as num?)?.toDouble().toString() ?? '';
        if (!name.contains(q) &&
            !email.contains(q) &&
            !address.contains(q) &&
            !id.contains(q) &&
            !lat.contains(q) &&
            !lng.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    // 3. Sorting Execution
    int severityRank(String? s) {
      final str = (s ?? 'medium').toLowerCase();
      if (str == 'high') return 3;
      if (str == 'medium') return 2;
      return 1;
    }

    // Smart Priority Score for the review queue: the expected cost of leaving
    // each report pending. Computed once per build over the FULL collection,
    // because reporter trust and corroboration depend on approved/rejected
    // history. See lib/approval_priority.dart and CALCULATION_DOCUMENTATION.md §7.
    final priorities = ApprovalPriority.rankAll(allDocs);

    displayedDocs.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;

      if (_listSortMode == 'oldest') {
        final aTime = _extractTimestamp(aData);
        final bTime = _extractTimestamp(bData);
        return aTime.compareTo(bTime);
      } else if (_listSortMode == 'severity') {
        final aSev = severityRank(aData['overallSeverity'] as String?);
        final bSev = severityRank(bData['overallSeverity'] as String?);
        return bSev.compareTo(aSev);
      } else if (_listSortMode == 'priority') {
        final aScore = priorities[a.id]?.score ?? 0.0;
        final bScore = priorities[b.id]?.score ?? 0.0;
        final cmp = bScore.compareTo(aScore);
        if (cmp != 0) return cmp;
        // Stable tie-break: older first, so the queue does not jitter.
        return _extractTimestamp(aData).compareTo(_extractTimestamp(bData));
      } else if (_listSortMode == 'proximity') {
        if (_adminPosition != null) {
          final aDist = Geolocator.distanceBetween(
            _adminPosition!.latitude,
            _adminPosition!.longitude,
            (aData['latitude'] as num).toDouble(),
            (aData['longitude'] as num).toDouble(),
          );
          final bDist = Geolocator.distanceBetween(
            _adminPosition!.latitude,
            _adminPosition!.longitude,
            (bData['latitude'] as num).toDouble(),
            (bData['longitude'] as num).toDouble(),
          );
          return aDist.compareTo(bDist);
        }
        final aTime = _extractTimestamp(aData);
        final bTime = _extractTimestamp(bData);
        return bTime.compareTo(aTime);
      } else {
        // 'newest' (default)
        final aTime = _extractTimestamp(aData);
        final bTime = _extractTimestamp(bData);
        return bTime.compareTo(aTime);
      }
    });

    final isFiltered = q.isNotEmpty || _listSeverityFilter != 'all';

    return Column(
      children: [
        // ====================================================================
        // Control & Filter Toolbar Header
        // ====================================================================
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: _surface(isDark),
            border: Border(
              bottom: BorderSide(
                color: _border(isDark).withValues(alpha: isDark ? 1.0 : 0.7),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: Search Field + Sort Dropdown + GPS Button
              Row(
                children: [
                  // Live Search Field
                  Expanded(
                    child: Container(
                      height: 42,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF0F172A)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                      child: TextField(
                        controller: _listSearchController,
                        onChanged: (_) => setState(() {}),
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                        decoration: InputDecoration(
                          hintText:
                              'Search road, city, reporter, coordinates, #ID...',
                          hintStyle: TextStyle(
                            fontSize: 12.5,
                            color: isDark
                                ? const Color(0xFF64748B)
                                : const Color(0xFF94A3B8),
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: Color(0xFF2563EB),
                          ),
                          suffixIcon: _listSearchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 16),
                                  onPressed: () {
                                    _listSearchController.clear();
                                    setState(() {});
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Sort Selector Dropdown
                  Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF0F172A)
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _listSortMode,
                        dropdownColor: isDark
                            ? const Color(0xFF1E293B)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        icon: const Icon(
                          Icons.sort_rounded,
                          size: 18,
                          color: Color(0xFF2563EB),
                        ),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: 'newest',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.access_time_rounded,
                                  size: 14,
                                  color: Color(0xFF2563EB),
                                ),
                                SizedBox(width: 8),
                                Text('Newest to Oldest'),
                              ],
                            ),
                          ),
                          const DropdownMenuItem(
                            value: 'oldest',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.history_rounded,
                                  size: 14,
                                  color: Color(0xFFD97706),
                                ),
                                SizedBox(width: 8),
                                Text('Oldest to Newest'),
                              ],
                            ),
                          ),
                          const DropdownMenuItem(
                            value: 'proximity',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.near_me_rounded,
                                  size: 14,
                                  color: Color(0xFF059669),
                                ),
                                SizedBox(width: 8),
                                Text('Closest to My Location'),
                              ],
                            ),
                          ),
                          const DropdownMenuItem(
                            value: 'severity',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 14,
                                  color: Color(0xFFEF4444),
                                ),
                                SizedBox(width: 8),
                                Text('Highest Severity'),
                              ],
                            ),
                          ),
                          const DropdownMenuItem(
                            value: 'priority',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 14,
                                  color: Color(0xFF7C3AED),
                                ),
                                SizedBox(width: 8),
                                Text('Smart Priority Score'),
                              ],
                            ),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _listSortMode = val);
                            if (val == 'proximity' && _adminPosition == null) {
                              _fetchAdminPosition();
                            }
                          }
                        },
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Admin Location Proximity Status Chip
                  OutlinedButton.icon(
                    onPressed: _fetchAdminPosition,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      side: BorderSide(
                        color: _adminPosition != null
                            ? const Color(0xFF10B981)
                            : (isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFCBD5E1)),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      backgroundColor: _adminPosition != null
                          ? const Color(0xFF10B981).withValues(alpha: 0.1)
                          : Colors.transparent,
                    ),
                    icon: _isFetchingAdminPosition
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF2563EB),
                            ),
                          )
                        : Icon(
                            _adminPosition != null
                                ? Icons.gps_fixed_rounded
                                : Icons.location_searching_rounded,
                            size: 15,
                            color: _adminPosition != null
                                ? const Color(0xFF10B981)
                                : (isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B)),
                          ),
                    label: Text(
                      _adminPosition != null ? 'GPS Active' : 'Enable GPS',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _adminPosition != null
                            ? const Color(0xFF10B981)
                            : (isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF475569)),
                      ),
                    ),
                  ),

                  if (isPendingTab && displayedDocs.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: _surface(isDark),
                            title: const Text('Bulk Approve Pending Reports'),
                            content: Text(
                              'Approve and publish all ${displayedDocs.length} pending report(s) immediately to the live map?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF10B981),
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Approve All'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          final ids = displayedDocs.map((d) => d.id).toList();
                          final count = await CloudService.instance.bulkApprovePotholes(ids);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Successfully approved $count reports live.'),
                                backgroundColor: const Color(0xFF10B981),
                              ),
                            );
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 42),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: const Icon(Icons.done_all_rounded, size: 16),
                      label: Text(
                        'Approve All (${displayedDocs.length})',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 12),

              // Row 2: Severity Filter Chips + Result Counter
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Severity Chips
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildSeverityChip(
                        label: 'All Hazards',
                        count: totalCount,
                        value: 'all',
                        color: const Color(0xFF2563EB),
                        isDark: isDark,
                      ),
                      _buildSeverityChip(
                        label: 'High Severity',
                        count: highCount,
                        value: 'high',
                        color: const Color(0xFFEF4444),
                        isDark: isDark,
                      ),
                      _buildSeverityChip(
                        label: 'Medium Severity',
                        count: medCount,
                        value: 'medium',
                        color: const Color(0xFFF59E0B),
                        isDark: isDark,
                      ),
                      _buildSeverityChip(
                        label: 'Low Severity',
                        count: lowCount,
                        value: 'low',
                        color: const Color(0xFF10B981),
                        isDark: isDark,
                      ),
                    ],
                  ),

                  // Result Counter and Clear Filters
                  Row(
                    children: [
                      Text(
                        'Showing ${displayedDocs.length} of $totalCount reports',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                        ),
                      ),
                      if (isFiltered) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () {
                            setState(() {
                              _listSearchController.clear();
                              _listSeverityFilter = 'all';
                            });
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              'Reset Filters',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2563EB),
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),

        // ====================================================================
        // Scrollable List Content
        // ====================================================================
        Expanded(
          child: displayedDocs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isFiltered
                            ? Icons.filter_alt_off_rounded
                            : (isPendingTab
                                ? Icons.check_circle_outline_rounded
                                : Icons.map_outlined),
                        size: 48,
                        color: const Color(0xFF94A3B8),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isFiltered
                            ? 'No reports match your search or filter criteria.'
                            : (isPendingTab
                                ? 'No pending submissions for review!'
                                : 'No approved potholes currently recorded.'),
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (isFiltered) ...[
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              _listSearchController.clear();
                              _listSeverityFilter = 'all';
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: const Icon(Icons.refresh_rounded, size: 14),
                          label: const Text(
                            'Clear Filters',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(24),
                  itemCount: displayedDocs.length + (isPendingTab ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (isPendingTab && index == 0) {
                      return StreamBuilder<bool>(
                        stream: CloudService.instance.streamAutoAcceptSetting(),
                        builder: (context, autoSnapshot) {
                          final isAutoAccept = autoSnapshot.data ?? false;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: isAutoAccept
                                  ? const Color(0xFF10B981)
                                      .withValues(alpha: isDark ? 0.12 : 0.08)
                                  : const Color(0xFF3B82F6)
                                      .withValues(alpha: isDark ? 0.12 : 0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isAutoAccept
                                    ? const Color(0xFF10B981)
                                        .withValues(alpha: isDark ? 0.35 : 0.25)
                                    : const Color(0xFF3B82F6)
                                        .withValues(alpha: isDark ? 0.35 : 0.25),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isAutoAccept
                                      ? Icons.bolt_rounded
                                      : Icons.rule_folder_rounded,
                                  color: isAutoAccept
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFF3B82F6),
                                  size: 22,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        isAutoAccept
                                            ? 'Auto-Accept is currently ACTIVE'
                                            : 'Manual Acceptance Mode is ACTIVE',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        isAutoAccept
                                            ? 'New pothole submissions are automatically approved and published to the live map.'
                                            : 'New reports require manual approval here before they appear on the public map.',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: isDark
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFF64748B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    await CloudService.instance
                                        .setAutoAcceptSetting(!isAutoAccept);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isAutoAccept
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFF3B82F6),
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  icon: Icon(
                                    isAutoAccept
                                        ? Icons.pause_circle_outline_rounded
                                        : Icons.play_circle_outline_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    isAutoAccept
                                        ? 'Switch to Manual'
                                        : 'Enable Auto-Accept',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    }

                    final docIndex = isPendingTab ? index - 1 : index;
                    final doc = displayedDocs[docIndex];
                    final data = doc.data() as Map<String, dynamic>;
                    final imageUrl = data['imageUrl'] as String? ?? '';
                    final lat = (data['latitude'] as num).toDouble();
                    final lng = (data['longitude'] as num).toDouble();
                    final reporterName =
                        data['reporterName'] as String? ?? 'Anonymous Surveyor';
                    final reporterEmail =
                        data['reporterEmail'] as String? ?? 'No email';
                    final reporterPhotoUrl =
                        data['reporterPhotoUrl'] as String? ?? '';
                    final potholeLocation = LatLng(lat, lng);
                    final severity =
                        (data['overallSeverity'] as String? ?? 'medium').toLowerCase();
                    final priority = priorities[doc.id];
                    final priorityScore = priority?.score.round() ?? 0;
                    final distanceStr = _formatDistanceToAdmin(lat, lng);
                    final timeStr = _formatReportTime(data['timestamp']);

                    // Severity color definition
                    final Color sevColor;
                    if (severity == 'high') {
                      sevColor = const Color(0xFFEF4444);
                    } else if (severity == 'medium') {
                      sevColor = const Color(0xFFF59E0B);
                    } else {
                      sevColor = const Color(0xFF10B981);
                    }

                    // Priority Tier definition (bands from ApprovalPriority)
                    final band = priority?.band ?? PriorityBand.low;
                    final Color priorityColor = switch (band) {
                      PriorityBand.critical => const Color(0xFFEF4444),
                      PriorityBand.high => const Color(0xFFF59E0B),
                      PriorityBand.normal => const Color(0xFF3B82F6),
                      PriorityBand.low => const Color(0xFF10B981),
                    };
                    final String priorityTier = priority?.bandLabel ?? 'Low';
                    final List<String> priorityReasons =
                        priority?.reasons ?? const <String>[];
                    final int duplicateCount =
                        priority?.duplicateIds.length ?? 0;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: _surface(isDark),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _border(isDark).withValues(
                            alpha: isDark ? 1.0 : 0.7,
                          ),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? 0.25 : 0.04,
                            ),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Row(
                          children: [
                            // Left Color Accent Bar matching Severity
                            Container(
                              width: 5,
                              height: 104,
                              color: sevColor,
                            ),

                            // 1. Compact Thumbnail Preview (92x84)
                            Container(
                              margin: const EdgeInsets.all(10),
                              width: 92,
                              height: 84,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isDark
                                      ? const Color(0xFF334155)
                                      : const Color(0xFFCBD5E1),
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(9),
                                child: imageUrl.startsWith('http')
                                    ? GestureDetector(
                                        onTap: () => _openFullScreenImage(
                                          context: context,
                                          imageUrl: imageUrl,
                                          title: 'Hazard #${doc.id.length > 6 ? doc.id.substring(0, 6).toUpperCase() : doc.id.toUpperCase()}',
                                          subtitle: data['address'] as String? ?? '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
                                          severity: severity,
                                          status: isPendingTab ? 'pending' : 'approved',
                                        ),
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              Image.network(
                                                imageUrl,
                                                fit: BoxFit.cover,
                                                loadingBuilder: (
                                                  context,
                                                  child,
                                                  progress,
                                                ) {
                                                  if (progress == null) return child;
                                                  return const Center(
                                                    child: SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child: CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    ),
                                                  );
                                                },
                                                errorBuilder:
                                                    (context, error, stackTrace) =>
                                                        Container(
                                                  color: isDark
                                                      ? const Color(0xFF0F172A)
                                                      : const Color(0xFFF1F5F9),
                                                  child: const Icon(
                                                    Icons.broken_image_rounded,
                                                    size: 26,
                                                    color: Color(0xFF94A3B8),
                                                  ),
                                                ),
                                              ),
                                              Positioned(
                                                bottom: 3,
                                                right: 3,
                                                child: Container(
                                                  padding: const EdgeInsets.all(2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.65),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Icon(
                                                    Icons.fullscreen_rounded,
                                                    color: Colors.white,
                                                    size: 13,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : Container(
                                        color: isDark
                                            ? const Color(0xFF0F172A)
                                            : const Color(0xFFF1F5F9),
                                        child: const Icon(
                                          Icons.image_not_supported_rounded,
                                          size: 26,
                                          color: Color(0xFF94A3B8),
                                        ),
                                      ),
                              ),
                            ),

                            const SizedBox(width: 4),

                            // 2. Middle Details Column
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Row 1: Badges (Status, Severity, Priority, Time, ID)
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        // Status Badge Pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isPendingTab
                                                ? (isDark
                                                    ? const Color(0xFF78350F)
                                                        .withValues(alpha: 0.4)
                                                    : const Color(0xFFFFFBEB))
                                                : (isDark
                                                    ? const Color(0xFF065F46)
                                                        .withValues(alpha: 0.4)
                                                    : const Color(0xFFECFDF5)),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(
                                              color: isPendingTab
                                                  ? const Color(0xFFF59E0B)
                                                  : const Color(0xFF10B981),
                                            ),
                                          ),
                                          child: Text(
                                            isPendingTab
                                                ? 'PENDING'
                                                : 'APPROVED',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w800,
                                              color: isPendingTab
                                                  ? (isDark
                                                      ? const Color(0xFFFBBF24)
                                                      : const Color(0xFFB45309))
                                                  : (isDark
                                                      ? const Color(0xFF34D399)
                                                      : const Color(0xFF047857)),
                                            ),
                                          ),
                                        ),

                                        // Severity Badge
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: sevColor.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(color: sevColor),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.warning_rounded,
                                                size: 10,
                                                color: sevColor,
                                              ),
                                              const SizedBox(width: 3),
                                              Text(
                                                severity.toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w800,
                                                  color: sevColor,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Priority Score Pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: priorityColor.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(
                                              color: priorityColor,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.auto_awesome_rounded,
                                                size: 10,
                                                color: priorityColor,
                                              ),
                                              const SizedBox(width: 3),
                                              Text(
                                                'Priority: $priorityScore ($priorityTier)',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w800,
                                                  color: priorityColor,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Duplicate-cluster pill: other pending
                                        // reports within 25 m are very likely
                                        // the same physical pothole.
                                        if (isPendingTab && duplicateCount > 0)
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF7C3AED)
                                                  .withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color:
                                                    const Color(0xFF7C3AED),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.copy_all_rounded,
                                                  size: 10,
                                                  color: Color(0xFF7C3AED),
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  '$duplicateCount DUPLICATE'
                                                  '${duplicateCount == 1 ? '' : 'S'}',
                                                  style: const TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w800,
                                                    color: Color(0xFF7C3AED),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                        // Why this ranked where it did.
                                        if (isPendingTab)
                                          ...priorityReasons.take(3).map(
                                                (reason) => Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 6,
                                                    vertical: 2.5,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: isDark
                                                        ? const Color(
                                                            0xFF1E293B)
                                                        : const Color(
                                                            0xFFF1F5F9),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                    border: Border.all(
                                                      color: isDark
                                                          ? const Color(
                                                              0xFF334155)
                                                          : const Color(
                                                              0xFFCBD5E1),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    reason,
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: isDark
                                                          ? const Color(
                                                              0xFF94A3B8)
                                                          : const Color(
                                                              0xFF475569),
                                                    ),
                                                  ),
                                                ),
                                              ),

                                        // Monospace Report ID
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isDark
                                                ? const Color(0xFF1E293B)
                                                : const Color(0xFFF1F5F9),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(
                                              color: isDark
                                                  ? const Color(0xFF334155)
                                                  : const Color(0xFFE2E8F0),
                                            ),
                                          ),
                                          child: Text(
                                            '#${doc.id.substring(0, math.min(6, doc.id.length)).toUpperCase()}',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w700,
                                              color: isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : const Color(0xFF64748B),
                                            ),
                                          ),
                                        ),

                                        // Time Tag
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.access_time_rounded,
                                              size: 11,
                                              color: isDark
                                                  ? const Color(0xFF64748B)
                                                  : const Color(0xFF94A3B8),
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              timeStr,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w500,
                                                color: isDark
                                                    ? const Color(0xFF94A3B8)
                                                    : const Color(0xFF64748B),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 6),

                                    // Row 2: Reporter Info
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 9,
                                          backgroundColor:
                                              const Color(0xFF2563EB),
                                          backgroundImage:
                                              reporterPhotoUrl.isNotEmpty
                                                  ? NetworkImage(
                                                      reporterPhotoUrl,
                                                    )
                                                  : null,
                                          child: reporterPhotoUrl.isEmpty
                                              ? Text(
                                                  reporterName.isNotEmpty
                                                      ? reporterName[0]
                                                          .toUpperCase()
                                                      : 'U',
                                                  style: const TextStyle(
                                                    fontSize: 8.5,
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                )
                                              : null,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            '$reporterName • $reporterEmail',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isDark
                                                  ? const Color(0xFFCBD5E1)
                                                  : const Color(0xFF475569),
                                              fontWeight: FontWeight.w600,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 6),

                                    // Row 3: GPS Coordinates & Proximity Distance
                                    Wrap(
                                      spacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        // GPS Coordinates Pill (Tappable)
                                        InkWell(
                                          onTap: () => _locatePotholeOnMap(
                                            potholeLocation,
                                            doc.id,
                                            data,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isDark
                                                  ? const Color(0xFF0F172A)
                                                  : const Color(0xFFF1F5F9),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: isDark
                                                    ? const Color(0xFF334155)
                                                    : const Color(0xFFCBD5E1),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.gps_fixed_rounded,
                                                  size: 11,
                                                  color: Color(0xFF2563EB),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 10.5,
                                                    fontFamily: 'monospace',
                                                    color: isDark
                                                        ? Colors.white
                                                        : const Color(
                                                            0xFF0F172A,
                                                          ),
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                const Icon(
                                                  Icons.open_in_new_rounded,
                                                  size: 10,
                                                  color: Color(0xFF2563EB),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),

                                        // Distance from Admin Position (if available)
                                        if (distanceStr.isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFF059669,
                                              ).withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: const Color(0xFF059669),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.near_me_rounded,
                                                  size: 11,
                                                  color: Color(0xFF059669),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  distanceStr,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 10.5,
                                                    color: Color(0xFF059669),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(width: 12),

                            // 3. Right Action Buttons Group
                            Padding(
                              padding: const EdgeInsets.only(right: 14),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Full Report Inspection Button
                                  SizedBox(
                                    height: 36,
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            const Color(0xFF2563EB),
                                        side: const BorderSide(
                                          color: Color(0xFF2563EB),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.visibility_rounded,
                                        size: 14,
                                        color: Color(0xFF2563EB),
                                      ),
                                      label: const Text(
                                        'Full Report',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      onPressed: () => _showAdminPotholeDetails(
                                        docId: doc.id,
                                        data: data,
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 8),

                                  // View on Interactive Map Button
                                  SizedBox(
                                    height: 36,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isDark
                                            ? const Color(0xFF0F172A)
                                            : const Color(0xFF1E293B),
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.map_rounded,
                                        size: 14,
                                        color: Color(0xFF38BDF8),
                                      ),
                                      label: const Text(
                                        'View on Map',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      onPressed: () => _locatePotholeOnMap(
                                        potholeLocation,
                                        doc.id,
                                        data,
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 8),

                                  // Edit Button
                                  SizedBox(
                                    height: 36,
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF2563EB),
                                        side: BorderSide(
                                          color: const Color(0xFF2563EB)
                                              .withValues(alpha: 0.35),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.edit_rounded,
                                        size: 14,
                                      ),
                                      label: const Text(
                                        'Edit',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      onPressed: () => _showEditPotholeDialog(
                                        context,
                                        doc.id,
                                        data,
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 8),

                                  if (isPendingTab) ...[
                                    // Approve Button
                                    SizedBox(
                                      height: 36,
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFF059669),
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.check_circle_rounded,
                                          size: 14,
                                        ),
                                        label: const Text(
                                          'Approve',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                        onPressed: () async {
                                          await CloudService.instance
                                              .updatePotholeStatus(
                                                doc.id,
                                                'approved',
                                              );
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Reject Button
                                    SizedBox(
                                      height: 36,
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor:
                                              const Color(0xFFE11D48),
                                          side: const BorderSide(
                                            color: Color(0xFFFECDD3),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 14,
                                        ),
                                        label: const Text(
                                          'Reject',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                        onPressed: () async {
                                          await _handleDeletePothole(
                                            context: context,
                                            docId: doc.id,
                                            previousStatus: 'pending',
                                          );
                                        },
                                      ),
                                    ),
                                  ] else ...[
                                    // Remove Report Button
                                    SizedBox(
                                      height: 36,
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor:
                                              const Color(0xFFE11D48),
                                          side: const BorderSide(
                                            color: Color(0xFFFECDD3),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 14,
                                        ),
                                        label: const Text(
                                          'Remove Report',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                        onPressed: () async {
                                          await _handleDeletePothole(
                                            context: context,
                                            docId: doc.id,
                                            previousStatus: 'approved',
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Soft-deletes a pothole marker to Trash Bin and displays a 5-second UNDO snackbar
  Future<void> _handleDeletePothole({
    required BuildContext context,
    required String docId,
    required String previousStatus,
  }) async {
    await CloudService.instance.softDeletePothole(
      docId,
      previousStatus: previousStatus,
    );
    if (context.mounted) {
      final shortId = docId.length > 6
          ? docId.substring(0, 6).toUpperCase()
          : docId.toUpperCase();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFFDA4AF),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text('Pothole #$shortId moved to Trash Bin.'),
            ],
          ),
          backgroundColor: const Color(0xFF1E293B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'UNDO',
            textColor: const Color(0xFF38BDF8),
            onPressed: () async {
              await CloudService.instance.restorePothole(
                docId,
                targetStatus: previousStatus,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Pothole marker restored successfully!'),
                    backgroundColor: Color(0xFF059669),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
        ),
      );
    }
  }

  /// Trash Bin / Archived Hazards View
  Widget _buildTrashBinView(
    BuildContext context,
    List<QueryDocumentSnapshot> deletedDocs, {
    required List<QueryDocumentSnapshot> allDocs,
  }) {
    final isDark = AppSettings.instance.isDarkMode;

    // Filter deleted docs by search query
    final q = _listSearchController.text.trim().toLowerCase();
    final displayedDocs = deletedDocs.where((doc) {
      if (q.isEmpty) return true;
      final data = doc.data() as Map<String, dynamic>;
      final name = (data['reporterName'] as String? ?? '').toLowerCase();
      final email = (data['reporterEmail'] as String? ?? '').toLowerCase();
      final address = (data['address'] as String? ?? '').toLowerCase();
      final id = doc.id.toLowerCase();
      final lat = (data['latitude'] as num?)?.toDouble().toString() ?? '';
      final lng = (data['longitude'] as num?)?.toDouble().toString() ?? '';
      return name.contains(q) ||
          email.contains(q) ||
          address.contains(q) ||
          id.contains(q) ||
          lat.contains(q) ||
          lng.contains(q);
    }).toList();

    return Column(
      children: [
        // 1. Uniform Toolbar (Search & Action Controls)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            border: Border(
              bottom: BorderSide(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFCBD5E1),
                    ),
                  ),
                  child: TextField(
                    controller: _listSearchController,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          'Search deleted reports by road, reporter, email, coordinates, or #ID...',
                      hintStyle: TextStyle(
                        color: isDark
                            ? const Color(0xFF64748B)
                            : const Color(0xFF94A3B8),
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: Color(0xFF94A3B8),
                      ),
                      suffixIcon: _listSearchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded, size: 16),
                              onPressed: () {
                                _listSearchController.clear();
                                setState(() {});
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                    ),
                    onChanged: (val) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Empty Trash Bin Button
              if (deletedDocs.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor:
                            isDark ? const Color(0xFF1E293B) : Colors.white,
                        title: Row(
                          children: const [
                            Icon(
                              Icons.delete_forever_rounded,
                              color: Color(0xFFE11D48),
                            ),
                            SizedBox(width: 8),
                            Text('Empty Trash Bin?'),
                          ],
                        ),
                        content: Text(
                          'Are you sure you want to permanently delete all ${deletedDocs.length} items from the trash bin? This action CANNOT be undone.',
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFFCBD5E1)
                                : const Color(0xFF334155),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE11D48),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () async {
                              Navigator.of(ctx).pop();
                              final ids =
                                  deletedDocs.map((d) => d.id).toList();
                              await CloudService.instance
                                  .emptyTrashPotholes(ids);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Trash bin emptied successfully.',
                                    ),
                                    backgroundColor: Color(0xFFE11D48),
                                  ),
                                );
                              }
                            },
                            child: const Text('Empty Trash Now'),
                          ),
                        ],
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE11D48),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 42),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                  label: const Text(
                    'Empty Trash',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // 2. Info Status Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF131D31) : const Color(0xFFF1F5F9),
            border: Border(
              bottom: BorderSide(
                color: isDark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFE2E8F0),
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 15,
                color:
                    isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
              const SizedBox(width: 8),
              Text(
                'Showing ${displayedDocs.length} of ${deletedDocs.length} deleted reports in Recycle Bin',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),

        // 3. List of Deleted Items
        Expanded(
          child: displayedDocs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFF1F5F9),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.delete_sweep_outlined,
                          size: 48,
                          color: isDark
                              ? const Color(0xFF64748B)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Trash Bin is Empty',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Deleted pothole reports will appear here where you can restore or permanently delete them.',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: displayedDocs.length,
                  itemBuilder: (context, index) {
                    final doc = displayedDocs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final docId = doc.id;
                    final shortId = docId.length > 6
                        ? docId.substring(0, 6).toUpperCase()
                        : docId.toUpperCase();
                    final severity =
                        (data['overallSeverity'] as String? ?? 'medium')
                            .toLowerCase();
                    final prevStatus =
                        data['previousStatus'] as String? ?? 'approved';
                    final imageUrl = data['imageUrl'] as String? ?? '';
                    final reporterName =
                        data['reporterName'] as String? ?? 'Anonymous User';
                    final reporterEmail =
                        data['reporterEmail'] as String? ?? '';
                    final address = data['address'] as String? ??
                        '${(data['latitude'] as num?)?.toStringAsFixed(5)}, ${(data['longitude'] as num?)?.toStringAsFixed(5)}';

                    final deletedTimestamp = data['deletedAt'];
                    String deletedTimeStr = 'Recently deleted';
                    if (deletedTimestamp is Timestamp) {
                      deletedTimeStr =
                          'Deleted ${_formatReportTime(deletedTimestamp.toDate())}';
                    }

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color:
                            isDark ? const Color(0xFF1E293B) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Left Red Accent Stripe
                              Container(
                                width: 5,
                                color: const Color(0xFFE11D48),
                              ),

                              // Thumbnail
                              Container(
                                width: 92,
                                height: 84,
                                margin: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF1F5F9),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: imageUrl.isNotEmpty
                                    ? GestureDetector(
                                        onTap: () => _openFullScreenImage(
                                          context: context,
                                          imageUrl: imageUrl,
                                          title: 'Hazard #$shortId',
                                          subtitle: address,
                                          severity: severity,
                                          status: 'deleted',
                                        ),
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              Image.network(
                                                imageUrl,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (_, _, _) => const Icon(
                                                  Icons.broken_image_rounded,
                                                  color: Color(0xFF94A3B8),
                                                ),
                                              ),
                                              Positioned(
                                                bottom: 3,
                                                right: 3,
                                                child: Container(
                                                  padding: const EdgeInsets.all(2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.65),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Icon(
                                                    Icons.fullscreen_rounded,
                                                    color: Colors.white,
                                                    size: 13,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : const Icon(
                                        Icons.image_not_supported_rounded,
                                        color: Color(0xFF94A3B8),
                                      ),
                              ),

                              // Content Info
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 4,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      // Top Badges
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          // TRASHED Badge
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFE11D48)
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: const Color(0xFFE11D48)
                                                    .withValues(alpha: 0.4),
                                              ),
                                            ),
                                            child: const Text(
                                              '🗑️ TRASHED',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFFE11D48),
                                              ),
                                            ),
                                          ),

                                          // Previous status
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isDark
                                                  ? const Color(0xFF334155)
                                                  : const Color(0xFFE2E8F0),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              'WAS ${prevStatus.toUpperCase()}',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                                color: isDark
                                                    ? const Color(0xFFCBD5E1)
                                                    : const Color(0xFF475569),
                                              ),
                                            ),
                                          ),

                                          // Severity
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: (severity == 'high'
                                                      ? const Color(0xFFEF4444)
                                                      : severity == 'medium'
                                                          ? const Color(0xFFF59E0B)
                                                          : const Color(0xFF10B981))
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              severity.toUpperCase(),
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                                color: severity == 'high'
                                                    ? const Color(0xFFEF4444)
                                                    : severity == 'medium'
                                                        ? const Color(0xFFF59E0B)
                                                        : const Color(0xFF10B981),
                                              ),
                                            ),
                                          ),

                                          // ID
                                          Text(
                                            '#$shortId',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              fontFamily: 'monospace',
                                              color: isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : const Color(0xFF64748B),
                                            ),
                                          ),

                                          // Deleted time
                                          Text(
                                            '• $deletedTimeStr',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isDark
                                                  ? const Color(0xFF64748B)
                                                  : const Color(0xFF94A3B8),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),

                                      // Address / Location
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.location_on_rounded,
                                            size: 14,
                                            color: Color(0xFFE11D48),
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              address,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                                color: isDark
                                                    ? Colors.white
                                                    : const Color(0xFF0F172A),
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),

                                      // Reporter
                                      Text(
                                        'Reporter: $reporterName ${reporterEmail.isNotEmpty ? '($reporterEmail)' : ''}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isDark
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFF64748B),
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // Actions Row
                              Padding(
                                padding: const EdgeInsets.only(right: 14),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 1. Restore Button
                                    ElevatedButton.icon(
                                      onPressed: () async {
                                        await CloudService.instance
                                            .restorePothole(docId);
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Pothole #$shortId restored to ${prevStatus.toUpperCase()} successfully!',
                                              ),
                                              backgroundColor:
                                                  const Color(0xFF059669),
                                              duration:
                                                  const Duration(seconds: 3),
                                            ),
                                          );
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF059669),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.restore_from_trash_rounded,
                                        size: 15,
                                      ),
                                      label: const Text(
                                        'Restore',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),

                                    // 2. Full Report Button
                                    OutlinedButton.icon(
                                      onPressed: () =>
                                          _showAdminPotholeDetails(
                                        docId: docId,
                                        data: data,
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.visibility_outlined,
                                        size: 15,
                                      ),
                                      label: const Text(
                                        'Details',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),

                                    // 3. Permanent Delete
                                    IconButton(
                                      tooltip: 'Delete Forever (Permanent)',
                                      icon: const Icon(
                                        Icons.delete_forever_rounded,
                                        color: Color(0xFFE11D48),
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            backgroundColor: isDark
                                                ? const Color(0xFF1E293B)
                                                : Colors.white,
                                            title: const Text(
                                              'Delete Permanently?',
                                            ),
                                            content: Text(
                                              'Are you sure you want to permanently delete hazard report #$shortId? This CANNOT be undone.',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(ctx).pop(),
                                                child: const Text('Cancel'),
                                              ),
                                              ElevatedButton(
                                                style: ElevatedButton
                                                    .styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFFE11D48),
                                                  foregroundColor:
                                                      Colors.white,
                                                ),
                                                onPressed: () async {
                                                  Navigator.of(ctx).pop();
                                                  await CloudService.instance
                                                      .permanentDeletePothole(
                                                    docId,
                                                  );
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Hazard permanently deleted.',
                                                        ),
                                                        backgroundColor:
                                                            Color(0xFFE11D48),
                                                      ),
                                                    );
                                                  }
                                                },
                                                child: const Text(
                                                  'Delete Forever',
                                                ),
                                              ),
                                            ],
                                          ),
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
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// GIS Map & Inspector Canvas View
  /// Features a Floating Filter Control Bar for Approved, Pending, and All Hazards!
  Widget _buildGisMapView(List<QueryDocumentSnapshot> docs) {
    final isDark = AppSettings.instance.isDarkMode;
    // Calculate totals for filter badges
    final approvedCount = docs
        .where(
          (d) => (d.data() as Map<String, dynamic>)['status'] == 'approved',
        )
        .length;
    final pendingCount = docs
        .where((d) => (d.data() as Map<String, dynamic>)['status'] == 'pending')
        .length;

    // Filter map documents according to selected filter mode: 'approved', 'pending', or 'all'
    final mapDocs = docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final status = data['status'] as String? ?? 'pending';

      // Always show actively selected pothole for inspection if set
      if (doc.id == _selectedPotholeId) return true;

      if (_mapFilterMode == 'approved') {
        return status == 'approved';
      } else if (_mapFilterMode == 'pending') {
        return status == 'pending';
      } else {
        // 'all'
        return true;
      }
    }).toList();

    double currentZoom = 12.0;
    try {
      currentZoom = _mapController.camera.zoom;
    } catch (_) {}

    double baseMarkerSize = 36.0;
    if (currentZoom < 10) {
      baseMarkerSize = 14.0;
    } else if (currentZoom < 12) {
      baseMarkerSize = 20.0;
    } else if (currentZoom < 14) {
      baseMarkerSize = 28.0;
    } else if (currentZoom < 16) {
      baseMarkerSize = 36.0;
    } else {
      baseMarkerSize = 44.0;
    }

    final potholeItems = mapDocs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final lat = (data['latitude'] as num).toDouble();
      final lng = (data['longitude'] as num).toDouble();
      return AdminPotholeItem(
        id: doc.id,
        location: LatLng(lat, lng),
        data: data,
      );
    }).toList();

    final clusters = _clusterAdminPotholes(potholeItems, radiusMeters: 15.0);

    final List<Marker> markers = [];
    for (final cluster in clusters) {
      if (cluster.isSingle) {
        final item = cluster.singleItem;
        final isSelected = item.id == _selectedPotholeId;
        final markerSize = isSelected
            ? (baseMarkerSize * 1.35).clamp(24.0, 56.0)
            : baseMarkerSize;

        Color iconColor;
        IconData iconData;
        if (item.status == 'pending') {
          iconColor = const Color(0xFFD97706);
          iconData = Icons.warning_rounded;
        } else if (item.status == 'rejected') {
          iconColor = Colors.grey;
          iconData = Icons.block;
        } else {
          iconColor = const Color(0xFFDC2626);
          iconData = Icons.warning_amber_rounded;
        }

        final double iconInnerSize = (markerSize * 0.52).clamp(10.0, 26.0);
        final double borderWidth = isSelected ? 3.0 : 2.0;
        final double padding = markerSize < 28 ? 2.0 : 4.0;

        markers.add(
          Marker(
            key: ValueKey('admin_single_${item.id}'),
            point: item.location,
            width: markerSize,
            height: markerSize,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedPotholeId = item.id;
                  _selectedPotholeLocation = item.location;
                  _selectedPotholeData = item.data;
                  _expandedClusterId = null;
                });
                _animatedMapMove(item.location, 17.5);
              },
              child: Container(
                width: markerSize,
                height: markerSize,
                decoration: BoxDecoration(
                  color: _surface(isDark),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? (item.status == 'approved'
                              ? const Color(0xFF10B981)
                              : const Color(0xFFF59E0B))
                        : iconColor,
                    width: borderWidth,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: iconColor.withValues(alpha: isDark ? 0.35 : 0.2),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: EdgeInsets.all(padding),
                child: Center(
                  child: Icon(
                    iconData,
                    size: iconInnerSize,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        // Merged Cluster with multiple nearby potholes (e.g. approved + pending)
        final bool isExpanded = _expandedClusterId == cluster.id;
        if (isExpanded) {
          final count = cluster.items.length;
          final double radius = count <= 2 ? 46.0 : (count <= 4 ? 54.0 : 66.0);
          final double boxSize = (radius + 28.0) * 2;

          markers.add(
            Marker(
              key: ValueKey('admin_spider_${cluster.id}'),
              point: cluster.center,
              width: boxSize,
              height: boxSize,
              child: _buildAdminSpiderClusterMarker(cluster, isDark),
            ),
          );
        } else {
          final bool containsSelected =
              cluster.items.any((i) => i.id == _selectedPotholeId);
          final double clusterSize = (baseMarkerSize * 1.2).clamp(32.0, 54.0);

          markers.add(
            Marker(
              key: ValueKey('admin_cluster_${cluster.id}'),
              point: cluster.center,
              width: clusterSize,
              height: clusterSize,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _expandedClusterId = cluster.id;
                  });
                  _animatedMapMove(cluster.center, 17.5);
                },
                child: _buildMergedAdminClusterMarker(
                  cluster: cluster,
                  size: clusterSize,
                  isDark: isDark,
                  isSelected: containsSelected,
                ),
              ),
            ),
          );
        }
      }
    }

    LatLng initialCenter =
        _selectedPotholeLocation ?? const LatLng(14.5995, 120.9842);
    if (_selectedPotholeLocation == null && mapDocs.isNotEmpty) {
      final firstData = mapDocs.first.data() as Map<String, dynamic>;
      initialCenter = LatLng(
        (firstData['latitude'] as num).toDouble(),
        (firstData['longitude'] as num).toDouble(),
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: _selectedPotholeLocation != null ? 17.5 : 12.0,
            minZoom: 3.0,
            maxZoom: 19.0,
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture) setState(() {});
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.pothole_app',
              minZoom: 3,
              maxZoom: 19,
              maxNativeZoom: 19,
            ),
            MarkerLayer(markers: markers),
          ],
        ),

        // Floating Map Filter Control Bar (Approved, Pending, All)
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
          color: AppSettings.instance.isDarkMode ? const Color(0xFF111827) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
          border: Border.all(color: AppSettings.instance.isDarkMode ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildFilterSegment(
                  label: 'Approved Live',
                  modeKey: 'approved',
                  icon: Icons.check_circle_rounded,
                  color: const Color(0xFF10B981),
                  count: approvedCount,
                ),
                const SizedBox(width: 4),
                _buildFilterSegment(
                  label: 'Pending Review',
                  modeKey: 'pending',
                  icon: Icons.pending_actions_rounded,
                  color: const Color(0xFFF59E0B),
                  count: pendingCount,
                ),
                const SizedBox(width: 4),
                _buildFilterSegment(
                  label: 'Show All Hazards',
                  modeKey: 'all',
                  icon: Icons.layers_rounded,
                  color: const Color(0xFF2563EB),
                  count: docs.length,
                ),
              ],
            ),
          ),
        ),

        // Floating Inspector Details Overlay Card
        if (_selectedPotholeData != null && _selectedPotholeId != null)
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                constraints: const BoxConstraints(maxWidth: 640),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF475569)
                        : const Color(0xFFCBD5E1),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (_selectedPotholeData!['status'] == 'approved'
                              ? const Color(0xFF10B981)
                              : const Color(0xFFF59E0B))
                          .withValues(alpha: isDark ? 0.35 : 0.20),
                      blurRadius: 28,
                      spreadRadius: 2,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.16),
                      blurRadius: 32,
                      spreadRadius: 3,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(19),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Top Status Accent Stripe
                      Container(
                        height: 4,
                        width: double.infinity,
                        color: _selectedPotholeData!['status'] == 'approved'
                            ? const Color(0xFF10B981)
                            : const Color(0xFFF59E0B),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            if ((_selectedPotholeData!['imageUrl'] as String? ??
                                    '')
                                .startsWith('http'))
                              GestureDetector(
                                onTap: () => _openFullScreenImage(
                                  context: context,
                                  imageUrl: _selectedPotholeData!['imageUrl'],
                                  title: 'Hazard #${_selectedPotholeId!.length > 6 ? _selectedPotholeId!.substring(0, 6).toUpperCase() : _selectedPotholeId!.toUpperCase()}',
                                  subtitle: _selectedPotholeData!['address'] as String?,
                                  severity: _selectedPotholeData!['overallSeverity'] as String?,
                                  status: _selectedPotholeData!['status'] as String?,
                                ),
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(14),
                                        child: Image.network(
                                          _selectedPotholeData!['imageUrl'],
                                          width: 84,
                                          height: 84,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                      Positioned(
                                        bottom: 4,
                                        right: 4,
                                        child: Container(
                                          padding: const EdgeInsets.all(3),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.7),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: Colors.white24, width: 0.5),
                                          ),
                                          child: const Icon(
                                            Icons.fullscreen_rounded,
                                            color: Colors.white,
                                            size: 14,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              Container(
                                width: 84,
                                height: 84,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Icon(
                                  Icons.no_photography_rounded,
                                  color: isDark
                                      ? const Color(0xFF64748B)
                                      : const Color(0xFF94A3B8),
                                  size: 30,
                                ),
                              ),
                            const SizedBox(width: 16),

                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _selectedPotholeData![
                                                      'status'] ==
                                                  'approved'
                                              ? const Color(
                                                  0xFF10B981,
                                                ).withValues(alpha: 0.15)
                                              : const Color(
                                                  0xFFF59E0B,
                                                ).withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          border: Border.all(
                                            color: _selectedPotholeData![
                                                        'status'] ==
                                                    'approved'
                                                ? const Color(0xFF10B981)
                                                : const Color(0xFFF59E0B),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _selectedPotholeData!['status'] ==
                                                      'approved'
                                                  ? Icons.verified_rounded
                                                  : Icons
                                                      .pending_actions_rounded,
                                              color: _selectedPotholeData![
                                                          'status'] ==
                                                      'approved'
                                                  ? const Color(0xFF10B981)
                                                  : const Color(0xFFF59E0B),
                                              size: 12,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              (_selectedPotholeData!['status']
                                                          as String? ??
                                                      'pending')
                                                  .toUpperCase(),
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                                color: _selectedPotholeData![
                                                            'status'] ==
                                                        'approved'
                                                    ? const Color(0xFF10B981)
                                                    : const Color(0xFFF59E0B),
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Reporter: ${_selectedPotholeData!['reporterName'] ?? _selectedPotholeData!['reporterEmail'] ?? 'Surveyor'}',
                                          style: TextStyle(
                                            color: isDark
                                                ? const Color(0xFFCBD5E1)
                                                : const Color(0xFF475569),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.gps_fixed_rounded,
                                        color: Color(0xFF2563EB),
                                        size: 14,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        'GPS: ${(_selectedPotholeData!['latitude'] as num).toDouble().toStringAsFixed(5)}, ${(_selectedPotholeData!['longitude'] as num).toDouble().toStringAsFixed(5)}',
                                        style: TextStyle(
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A),
                                          fontWeight: FontWeight.bold,
                                          fontFamily: 'monospace',
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      if (_selectedPotholeData!['status'] ==
                                          'pending') ...[
                                        ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                const Color(0xFF10B981),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 7,
                                            ),
                                            minimumSize: Size.zero,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            tapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                          ),
                                          icon: const Icon(
                                            Icons.check_circle_rounded,
                                            size: 14,
                                          ),
                                          onPressed: () async {
                                            await CloudService.instance
                                                .updatePotholeStatus(
                                                  _selectedPotholeId!,
                                                  'approved',
                                                );
                                            setState(() {
                                              _selectedPotholeData!['status'] =
                                                  'approved';
                                              _mapFilterMode = 'approved';
                                            });
                                          },
                                          label: const Text(
                                            'Approve',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFFF43F5E),
                                            side: const BorderSide(
                                              color: Color(0xFFF43F5E),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 7,
                                            ),
                                            minimumSize: Size.zero,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            tapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                          ),
                                          icon: const Icon(
                                            Icons.cancel_rounded,
                                            size: 14,
                                          ),
                                          onPressed: () async {
                                            await CloudService.instance
                                                .updatePotholeStatus(
                                                  _selectedPotholeId!,
                                                  'rejected',
                                                );
                                            setState(() {
                                              _selectedPotholeData = null;
                                              _selectedPotholeId = null;
                                            });
                                          },
                                          label: const Text(
                                            'Reject',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ] else ...[
                                        OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFFF43F5E),
                                            side: const BorderSide(
                                              color: Color(0xFFF43F5E),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 7,
                                            ),
                                            minimumSize: Size.zero,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            tapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                          ),
                                          icon: const Icon(
                                            Icons.delete_forever_rounded,
                                            size: 14,
                                          ),
                                          onPressed: () async {
                                            final idToDelete = _selectedPotholeId!;
                                            final prevStatus = _selectedPotholeData?['status'] as String? ?? 'approved';
                                            setState(() {
                                              _selectedPotholeData = null;
                                              _selectedPotholeId = null;
                                            });
                                            await _handleDeletePothole(
                                              context: context,
                                              docId: idToDelete,
                                              previousStatus: prevStatus,
                                            );
                                          },
                                          label: const Text(
                                            'Remove Report',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFF2563EB),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 7,
                                          ),
                                          minimumSize: Size.zero,
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        icon: const Icon(
                                          Icons.assignment_rounded,
                                          size: 14,
                                        ),
                                        onPressed: () =>
                                            _showAdminPotholeDetails(
                                              docId: _selectedPotholeId!,
                                              data: _selectedPotholeData!,
                                            ),
                                        label: const Text(
                                          'Full Report',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedPotholeData = null;
                                    _selectedPotholeId = null;
                                    _selectedPotholeLocation = null;
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFE2E8F0),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.close_rounded,
                                    color: WebDesign.textPrimary(isDark),
                                    size: 16,
                                  ),
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
          ),
      ],
    );
  }

  /// Helper button for GIS map filter segment items
  Widget _buildFilterSegment({
    required String label,
    required String modeKey,
    required IconData icon,
    required Color color,
    required int count,
  }) {
    final isSelected = _mapFilterMode == modeKey;
    return InkWell(
      onTap: () {
        setState(() {
          _mapFilterMode = modeKey;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (AppSettings.instance.isDarkMode
                  ? const Color(0xFF111827)
                  : const Color(0xFFEFF6FF))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: color.withValues(alpha: 0.8))
              : Border.all(color: Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? color : WebDesign.textMuted(AppSettings.instance.isDarkMode),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected
                    ? WebDesign.textPrimary(AppSettings.instance.isDarkMode)
                    : WebDesign.textSecondary(AppSettings.instance.isDarkMode),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withValues(alpha: 0.2)
                    : (AppSettings.instance.isDarkMode
                        ? Colors.white10
                        : const Color(0xFFE2E8F0)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? color : WebDesign.textSecondary(AppSettings.instance.isDarkMode),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Super Admin User Role Management & Export Canvas View
  Widget _buildUserManagementView(List<QueryDocumentSnapshot> allPotholeDocs) {
    final isDark = AppSettings.instance.isDarkMode;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Data Export Section Box
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _surface(isDark),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border(isDark)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data Analytics & Thesis CSV Export',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: WebDesign.textPrimary(isDark),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Download complete dataset including GPS coordinates, timestamps, and status.',
                      style: TextStyle(fontSize: 11, color: WebDesign.textSecondary(isDark)),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text(
                    'Export Dataset to CSV',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  onPressed: () {
                    List<List<dynamic>> rows = [
                      [
                        'ID',
                        'Latitude',
                        'Longitude',
                        'Status',
                        'Reporter Name',
                        'Reporter Email',
                        'Timestamp',
                      ],
                    ];
                    for (var doc in allPotholeDocs) {
                      final data = doc.data() as Map<String, dynamic>;
                      rows.add([
                        doc.id,
                        data['latitude'],
                        data['longitude'],
                        data['status'],
                        data['reporterName'],
                        data['reporterEmail'],
                        data['timestamp'] != null
                            ? (data['timestamp'] as Timestamp)
                                  .toDate()
                                  .toIso8601String()
                            : '',
                      ]);
                    }
                    String csv = rows
                        .map((row) {
                          return row
                              .map((field) {
                                String val = field.toString();
                                if (val.contains(',') ||
                                    val.contains('"') ||
                                    val.contains('\n')) {
                                  return '"${val.replaceAll('"', '""')}"';
                                }
                                return val;
                              })
                              .join(',');
                        })
                        .join('\n');

                    final bytes = utf8.encode(csv);
                    final blob = html.Blob([bytes], 'text/csv');
                    final url = html.Url.createObjectUrlFromBlob(blob);
                    html.AnchorElement(href: url)
                      ..setAttribute('download', 'pothole_dataset_export.csv')
                      ..click();
                    html.Url.revokeObjectUrl(url);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // User Accounts Table Box
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _surface(isDark),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border(isDark)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Registered User Accounts & Access Control',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: WebDesign.textPrimary(isDark),
                  ),
                ),
                const SizedBox(height: 16),
                StreamBuilder<QuerySnapshot>(
                  stream: CloudService.instance.streamAllUsers(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(
                        'Error loading users: ${snapshot.error}',
                        style: TextStyle(color: WebDesign.textSecondary(isDark)),
                      );
                    }
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: Color(0xFF10B981)),
                      );
                    }

                    final users = snapshot.data?.docs ?? [];
                    if (users.isEmpty) {
                      return Text(
                        'No registered user accounts.',
                        style: TextStyle(color: WebDesign.textSecondary(isDark)),
                      );
                    }

                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: users.length,
                      separatorBuilder: (ctx, i) =>
                          Divider(color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                      itemBuilder: (context, index) {
                        final userDoc = users[index];
                        final data = userDoc.data() as Map<String, dynamic>;
                        final uid = data['uid'] as String? ?? userDoc.id;
                        final name = data['displayName'] as String? ?? 'User';
                        final email = data['email'] as String? ?? '';
                        final role = data['role'] as String? ?? 'user';

                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: role == 'super_admin'
                                ? Colors.purple
                                : (role == 'admin'
                                      ? const Color(0xFF2563EB)
                                      : const Color(0xFF059669)),
                            child: Text(
                              name[0].toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          title: Text(
                            name,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: WebDesign.textPrimary(isDark),
                            ),
                          ),
                          subtitle: Text(
                            email,
                            style: TextStyle(
                              fontSize: 11,
                              color: WebDesign.textSecondary(isDark),
                            ),
                          ),
                          trailing: DropdownButton<String>(
                            value: role,
                            dropdownColor: _surface(isDark),
                            underline: const SizedBox(),
                            style: TextStyle(
                              fontSize: 12,
                              color: WebDesign.textPrimary(isDark),
                              fontWeight: FontWeight.w600,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'user',
                                child: Text('User / Surveyor'),
                              ),
                              DropdownMenuItem(
                                value: 'admin',
                                child: Text('Admin'),
                              ),
                              DropdownMenuItem(
                                value: 'super_admin',
                                child: Text('Super Admin'),
                              ),
                            ],
                            onChanged: (newRole) async {
                              if (newRole != null) {
                                await CloudService.instance.updateUserRole(
                                  uid,
                                  newRole,
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Updated $name role to $newRole',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Danger Zone ──────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E0A0A) : const Color(0xFFFFF1F2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Danger Zone — Test Account Reset',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Deletes ALL user Firestore documents except jenardphil001@gmail.com and jenardphil111@gmail.com. '
                  'Firebase Auth accounts must be deleted manually in Firebase Console.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFFF87171) : const Color(0xFF991B1B),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.delete_forever_rounded, size: 16),
                  label: const Text(
                    'Reset Non-Admin User Accounts',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                  ),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: const Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 22),
                            SizedBox(width: 10),
                            Text(
                              'Confirm Reset',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        content: const Text(
                          'This will permanently delete all Firestore user documents except:\n\n'
                          '• jenardphil001@gmail.com\n'
                          '• jenardphil111@gmail.com\n\n'
                          'Firebase Auth accounts are NOT deleted here — do that in Firebase Console.\n\n'
                          'This action cannot be undone. Continue?',
                          style: TextStyle(fontSize: 13, height: 1.5),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('Yes, Reset', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    );

                    if (confirmed == true && context.mounted) {
                      try {
                        final count = await CloudService.instance.resetNonAdminUsers();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                count == 0
                                    ? 'No non-admin users found to delete.'
                                    : '\u2705 Deleted $count user Firestore document(s). Remember to delete Auth accounts in Firebase Console.',
                              ),
                              backgroundColor: count == 0 ? null : const Color(0xFF059669),
                              duration: const Duration(seconds: 6),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error: $e'),
                              backgroundColor: const Color(0xFFDC2626),
                            ),
                          );
                        }
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatAdminPotholeDate(dynamic rawTimestamp) {
    if (rawTimestamp == null) return 'Recent Survey';
    try {
      DateTime dt;
      if (rawTimestamp is Timestamp) {
        dt = rawTimestamp.toDate();
      } else if (rawTimestamp is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
      } else if (rawTimestamp is DateTime) {
        dt = rawTimestamp;
      } else {
        dt = DateTime.tryParse(rawTimestamp.toString()) ?? DateTime.now();
      }
      return '${_monthName(dt.month)} ${dt.day}, ${dt.year} • ${_formatTime12h(dt)}';
    } catch (_) {
      return 'Recent Survey';
    }
  }

  String _monthName(int month) {
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return (month >= 1 && month <= 12) ? m[month - 1] : '';
  }

  String _formatTime12h(DateTime dt) {
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    return '$hour:$min $period';
  }

  /// Opens a high-resolution, full-screen lightbox with pan & zoom capabilities
  void _openFullScreenImage({
    required BuildContext context,
    required String imageUrl,
    String? title,
    String? subtitle,
    String? severity,
    String? status,
  }) {
    if (imageUrl.isEmpty || !imageUrl.startsWith('http')) return;

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (dialogContext) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // 1. Interactive Full-Screen Image Pan & Zoom
              Positioned.fill(
                child: Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 6.0,
                    boundaryMargin: const EdgeInsets.all(100),
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (ctx, child, progress) {
                        if (progress == null) return child;
                        final total = progress.expectedTotalBytes;
                        final loaded = progress.cumulativeBytesLoaded;
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                value: total != null ? loaded / total : null,
                                color: const Color(0xFF38BDF8),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Loading High-Resolution Photo...',
                                style: TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ],
                          ),
                        );
                      },
                      errorBuilder: (_, _, _) => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.broken_image_rounded, color: Colors.white54, size: 64),
                            SizedBox(height: 12),
                            Text(
                              'Failed to load high-resolution photo.',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 2. Top Navigation & Info Header Bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    child: Row(
                      children: [
                        // Back / Close Button
                        Material(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => Navigator.of(dialogContext).pop(),
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),

                        // Title & Subtitle Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (title != null)
                                Text(
                                  title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (subtitle != null)
                                Text(
                                  subtitle,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),

                        // Severity badge if available
                        if (severity != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: (severity.toLowerCase() == 'high'
                                      ? const Color(0xFFEF4444)
                                      : severity.toLowerCase() == 'medium'
                                          ? const Color(0xFFF59E0B)
                                          : const Color(0xFF10B981))
                                  .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: severity.toLowerCase() == 'high'
                                    ? const Color(0xFFEF4444)
                                    : severity.toLowerCase() == 'medium'
                                        ? const Color(0xFFF59E0B)
                                        : const Color(0xFF10B981),
                              ),
                            ),
                            child: Text(
                              '${severity.toUpperCase()} SEVERITY',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: severity.toLowerCase() == 'high'
                                    ? const Color(0xFFFDA4AF)
                                    : severity.toLowerCase() == 'medium'
                                        ? const Color(0xFFFCD34D)
                                        : const Color(0xFF34D399),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],

                        // Close button
                        Material(
                          color: Colors.white.withValues(alpha: 0.15),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => Navigator.of(dialogContext).pop(),
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 3. Bottom Controls Helper Bar
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.zoom_in_rounded, color: Color(0xFF38BDF8), size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Pinch or Scroll wheel to Zoom • Drag to Pan',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAdminPotholeDetails({
    required String docId,
    required Map<String, dynamic> data,
  }) {
    final isDark = AppSettings.instance.isDarkMode;
    final shortId = docId.length > 6 ? docId.substring(0, 6).toUpperCase() : docId.toUpperCase();
    final address = data['address'] as String? ?? 'GPS: ${(data['latitude'] as num?)?.toStringAsFixed(5)}, ${(data['longitude'] as num?)?.toStringAsFixed(5)}';
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0.0;
    final status = (data['status'] as String? ?? 'pending').toLowerCase();
    final severity = (data['overallSeverity'] as String? ?? 'medium').toLowerCase();
    final imageUrl = (data['imageUrl'] as String? ??
            data['photoUrl'] as String? ??
            '')
        .trim();
    final reporterName =
        data['reporterName'] as String? ?? 'Anonymous Surveyor';
    final reporterEmail =
        data['reporterEmail'] as String? ?? 'No email provided';
    final dynamic rawTimestamp = data['timestamp'];
    final formattedDate = _formatAdminPotholeDate(rawTimestamp);

    final isApproved = status == 'approved';
    final isRejected = status == 'rejected';

    final Color statusColor = isApproved
        ? const Color(0xFF10B981)
        : (isRejected ? const Color(0xFFEF4444) : const Color(0xFFF59E0B));
    final IconData statusIcon = isApproved
        ? Icons.verified_rounded
        : (isRejected ? Icons.cancel_rounded : Icons.schedule_rounded);
    final String statusLabel = isApproved
        ? 'APPROVED LIVE'
        : (isRejected ? 'REJECTED' : 'PENDING REVIEW');

    final bool isHighSeverity = severity == 'high';
    final bool isMediumSeverity = severity == 'medium';

    final Color severityColor = isHighSeverity
        ? const Color(0xFFEF4444)
        : (isMediumSeverity
            ? const Color(0xFFF97316)
            : const Color(0xFFEAB308));

    final String severityLabel = isHighSeverity
        ? 'HIGH SEVERITY'
        : (isMediumSeverity ? 'MEDIUM SEVERITY' : 'LOW SEVERITY');

    final String docIdStr = docId.length > 8
        ? docId.substring(0, 8).toUpperCase()
        : docId.toUpperCase();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final isMobile = screenWidth < 600;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isMobile ? 14 : 24,
            vertical: isMobile ? 20 : 32,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 840),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFE2E8F0),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.2),
                  blurRadius: 32,
                  spreadRadius: 2,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 16, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.report_problem_rounded,
                          color: Color(0xFF2563EB),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Pothole Hazard Report',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
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
                                  ),
                                  child: Text(
                                    '#$docIdStr',
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Administrator Inspection & Road Surface Telemetry',
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusIcon, color: statusColor, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        tooltip: 'Close Inspection',
                      ),
                    ],
                  ),
                ),

                Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),

                // Scrollable Body Content
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Photo Section
                        if (imageUrl.startsWith('http'))
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Stack(
                              children: [
                                Container(
                                  height: 240,
                                  width: double.infinity,
                                  color: isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF1F5F9),
                                  child: GestureDetector(
                                    onTap: () => _openFullScreenImage(
                                      context: context,
                                      imageUrl: imageUrl,
                                      title: 'Hazard Report #$shortId',
                                      subtitle: address,
                                      severity: severity,
                                      status: status,
                                    ),
                                    child: InteractiveViewer(
                                      child: Image.network(
                                        imageUrl,
                                        fit: BoxFit.cover,
                                        loadingBuilder:
                                            (context, child, progress) {
                                          if (progress == null) return child;
                                          return const Center(
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                            ),
                                          );
                                        },
                                        errorBuilder: (context, error, stackTrace) => Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.broken_image_rounded,
                                                size: 40,
                                                color: isDark
                                                    ? const Color(0xFF64748B)
                                                    : const Color(0xFF94A3B8),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Image failed to load',
                                                style: TextStyle(
                                                  color: isDark
                                                      ? const Color(0xFF64748B)
                                                      : const Color(0xFF94A3B8),
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () => _openFullScreenImage(
                                        context: context,
                                        imageUrl: imageUrl,
                                        title: 'Hazard Report #$shortId',
                                        subtitle: address,
                                        severity: severity,
                                        status: status,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.75),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.white30, width: 1),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.fullscreen_rounded,
                                              color: Colors.white,
                                              size: 15,
                                            ),
                                            SizedBox(width: 5),
                                            Text(
                                              'Full Screen',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  bottom: 10,
                                  right: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.65,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.zoom_in_rounded,
                                          color: Colors.white,
                                          size: 13,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'Pinch / Scroll to Zoom HD',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Container(
                            height: 140,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF0F172A)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.no_photography_rounded,
                                    color: isDark
                                        ? const Color(0xFF64748B)
                                        : const Color(0xFF94A3B8),
                                    size: 36,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'No Inspection Photo Attached',
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        const SizedBox(height: 16),

                        // Severity Warning Banner
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: severityColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: severityColor.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isHighSeverity
                                    ? Icons.dangerous_rounded
                                    : (isMediumSeverity
                                        ? Icons.warning_rounded
                                        : Icons.warning_amber_rounded),
                                color: severityColor,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      severityLabel,
                                      style: TextStyle(
                                        color: severityColor,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      isHighSeverity
                                          ? 'Deep structural road defect requiring priority maintenance and cautionary driving.'
                                          : (isMediumSeverity
                                              ? 'Moderate surface degradation detected. Proceed with safety precautions.'
                                              : 'Minor road surface irregularity logged by optical telemetry survey.'),
                                      style: TextStyle(
                                        color: isDark
                                            ? const Color(0xFFCBD5E1)
                                            : const Color(0xFF475569),
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // 2x2 Telemetry Grid
                        Row(
                          children: [
                            // Card 1: GPS Coordinates
                            Expanded(
                              child: _buildAdminTelemetryTile(
                                icon: Icons.gps_fixed_rounded,
                                iconColor: const Color(0xFF2563EB),
                                title: 'GPS Location',
                                value:
                                    '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                                isDark: isDark,
                                trailing: InkWell(
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(text: '$lat, $lng'),
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
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF334155)
                                          : const Color(0xFFE2E8F0),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Icon(
                                      Icons.copy_rounded,
                                      size: 13,
                                      color: isDark
                                          ? Colors.white70
                                          : const Color(0xFF475569),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Card 2: Date Logged
                            Expanded(
                              child: _buildAdminTelemetryTile(
                                icon: Icons.calendar_today_rounded,
                                iconColor: const Color(0xFF10B981),
                                title: 'Date Logged',
                                value: formattedDate,
                                isDark: isDark,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        Row(
                          children: [
                            // Card 3: Surveyor
                            Expanded(
                              child: _buildAdminTelemetryTile(
                                icon: Icons.person_rounded,
                                iconColor: const Color(0xFF8B5CF6),
                                title: 'Surveyor / Reporter',
                                value: reporterName,
                                subtitle: reporterEmail,
                                isDark: isDark,
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Card 4: Status / Detection
                            Expanded(
                              child: _buildAdminTelemetryTile(
                                icon: Icons.insights_rounded,
                                iconColor: const Color(0xFF06B6D4),
                                title: 'Detection Status',
                                value: statusLabel,
                                subtitle: 'ID: $docId',
                                isDark: isDark,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),

                // Bottom Action Buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                  child: Row(
                    children: [
                      // View on GIS Map
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _locatePotholeOnMap(LatLng(lat, lng), docId, data);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2563EB),
                          side: const BorderSide(color: Color(0xFF2563EB)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.map_rounded, size: 16),
                        label: const Text(
                          'Locate on Map',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const Spacer(),

                      // Edit Report Details
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _showEditPotholeDialog(context, docId, data);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2563EB),
                          side: const BorderSide(color: Color(0xFF2563EB)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.edit_note_rounded, size: 16),
                        label: const Text(
                          'Edit Details',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      if (status == 'pending') ...[
                        OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            setState(() {
                              if (_selectedPotholeId == docId) {
                                _selectedPotholeData = null;
                                _selectedPotholeId = null;
                              }
                            });
                            await _handleDeletePothole(
                              context: context,
                              docId: docId,
                              previousStatus: 'pending',
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFEF4444),
                            side: const BorderSide(color: Color(0xFFEF4444)),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.cancel_rounded, size: 16),
                          label: const Text(
                            'Reject Report',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await CloudService.instance.updatePotholeStatus(
                              docId,
                              'approved',
                            );
                            setState(() {
                              if (_selectedPotholeId == docId &&
                                  _selectedPotholeData != null) {
                                _selectedPotholeData!['status'] = 'approved';
                              }
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.check_circle_rounded, size: 16),
                          label: const Text(
                            'Approve & Publish Live',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ] else if (status == 'approved') ...[
                        OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            setState(() {
                              if (_selectedPotholeId == docId) {
                                _selectedPotholeData = null;
                                _selectedPotholeId = null;
                              }
                            });
                            await _handleDeletePothole(
                              context: context,
                              docId: docId,
                              previousStatus: 'approved',
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFEF4444),
                            side: const BorderSide(color: Color(0xFFEF4444)),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.delete_outline_rounded, size: 16),
                          label: const Text(
                            'Move to Trash Bin',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ] else if (status == 'deleted') ...[
                        ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await CloudService.instance.restorePothole(docId);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Hazard restored successfully!'),
                                  backgroundColor: Color(0xFF059669),
                                ),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF059669),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.restore_from_trash_rounded, size: 16),
                          label: const Text(
                            'Restore Hazard',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ] else ...[
                        ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await CloudService.instance.updatePotholeStatus(
                              docId,
                              'approved',
                            );
                            setState(() {
                              if (_selectedPotholeId == docId &&
                                  _selectedPotholeData != null) {
                                _selectedPotholeData!['status'] = 'approved';
                              }
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.check_circle_rounded, size: 16),
                          label: const Text(
                            'Re-Approve',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
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

  void _showEditPotholeDialog(
    BuildContext context,
    String docId,
    Map<String, dynamic> data,
  ) {
    final isDark = AppSettings.instance.isDarkMode;
    String selectedSeverity =
        (data['overallSeverity'] as String? ?? 'medium').toLowerCase();
    int potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;
    final noteController =
        TextEditingController(text: data['note'] as String? ?? '');

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: _surface(isDark),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.edit_note_rounded,
                      color: Color(0xFF2563EB),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Edit Report Details',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 380,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hazard #${docId.length > 6 ? docId.substring(0, 6).toUpperCase() : docId.toUpperCase()}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Overall Severity',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: selectedSeverity,
                        dropdownColor: _surface(isDark),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'low',
                            child: Text('Low - Minor Surface Flaw'),
                          ),
                          DropdownMenuItem(
                            value: 'medium',
                            child: Text('Medium - Noticeable Hazard'),
                          ),
                          DropdownMenuItem(
                            value: 'high',
                            child: Text('High - Severe / Dangerous'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => selectedSeverity = val);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Pothole Count in Frame',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          IconButton.outlined(
                            icon: const Icon(Icons.remove, size: 16),
                            onPressed: potholeCount > 1
                                ? () => setDialogState(() => potholeCount--)
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            child: Text(
                              '$potholeCount',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton.outlined(
                            icon: const Icon(Icons.add, size: 16),
                            onPressed: () =>
                                setDialogState(() => potholeCount++),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Review / Maintenance Notes',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: noteController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Add notes or inspection details...',
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    try {
                      await CloudService.instance.editPothole(
                        docId,
                        overallSeverity: selectedSeverity,
                        potholeCount: potholeCount,
                        note: noteController.text.trim(),
                      );
                      if (mounted) {
                        setState(() {
                          if (_selectedPotholeId == docId &&
                              _selectedPotholeData != null) {
                            _selectedPotholeData!['overallSeverity'] =
                                selectedSeverity;
                            _selectedPotholeData!['potholeCount'] = potholeCount;
                            _selectedPotholeData!['note'] =
                                noteController.text.trim();
                          }
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Report details updated successfully.',
                            ),
                            backgroundColor: Color(0xFF10B981),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Update failed: $e'),
                            backgroundColor: const Color(0xFFEF4444),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildAdminTelemetryTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    String? subtitle,
    Widget? trailing,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isDark
                          ? const Color(0xFF64748B)
                          : const Color(0xFF94A3B8),
                      fontSize: 10.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Profile and sign-out tile pinned to the bottom of the sidebar.
class _AccountMenuTile extends StatelessWidget {
  final String displayName;
  final String email;
  final String role;
  final bool isDark;
  final VoidCallback onSignOut;

  const _AccountMenuTile({
    required this.displayName,
    required this.email,
    required this.role,
    required this.isDark,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isNotEmpty
        ? displayName[0].toUpperCase()
        : (email.isNotEmpty ? email[0].toUpperCase() : 'A');

    return Container(
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
                fontSize: 12,
                fontWeight: FontWeight.bold,
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
                  displayName.isNotEmpty ? displayName : 'Admin User',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  role.isNotEmpty ? role.toUpperCase() : 'ADMIN',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: WebDesign.textMuted(isDark),
                        fontSize: 10,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, size: WebDesign.iconSm),
            tooltip: 'Sign Out',
            onPressed: onSignOut,
            color: WebDesign.danger(isDark),
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


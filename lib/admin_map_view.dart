import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'admin_report_inspector.dart';
import 'admin_report_query.dart';
import 'admin_shared_widgets.dart';
import 'approval_priority.dart';
import 'dpwh_standards.dart';
import 'road_hazard_marker.dart';
import 'web_components.dart';
import 'web_design.dart';

class _MapCluster {
  final String id;
  final LatLng center;
  final List<AdminReportRow> items;

  const _MapCluster({
    required this.id,
    required this.center,
    required this.items,
  });

  bool get isSingle => items.length == 1;
}

/// Interactive admin GIS map with its own filters and selected-report inspector.
/// Avoids resetting user pan/zoom automatically when Firestore streams update.
class AdminMapView extends StatefulWidget {
  final List<AdminReportRow> activeRows;
  final Map<String, ReportPriority> priorities;
  final AdminReportFilter filter;
  final ValueChanged<AdminReportFilter> onFilterChanged;
  final String? selectedReportId;
  final ValueChanged<String?> onSelectReportId;
  final LatLng? requestedFocusLocation;
  final int focusRequestNonce;
  final Future<void> Function(AdminReportRow row) onSoftDelete;

  const AdminMapView({
    super.key,
    required this.activeRows,
    required this.priorities,
    required this.filter,
    required this.onFilterChanged,
    required this.selectedReportId,
    required this.onSelectReportId,
    required this.requestedFocusLocation,
    required this.focusRequestNonce,
    required this.onSoftDelete,
  });

  @override
  State<AdminMapView> createState() => _AdminMapViewState();
}

class _AdminMapViewState extends State<AdminMapView>
    with TickerProviderStateMixin {
  static const LatLng _santaMariaCenter = LatLng(14.8194, 120.9565);
  late final MapController _mapCtrl;

  String? _expandedClusterId;
  double _zoom = 13.0;
  int _handledFocusNonce = -1;
  bool _mapReady = false;
  bool _hasFittedReports = false;
  AnimationController? _cameraAnimation;

  @override
  void initState() {
    super.initState();
    _mapCtrl = MapController();
    _handledFocusNonce = widget.focusRequestNonce;
  }

  @override
  void didUpdateWidget(covariant AdminMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_hasFittedReports && widget.activeRows.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fitInitialReports();
      });
    }
    if (widget.focusRequestNonce != _handledFocusNonce &&
        widget.requestedFocusLocation != null) {
      _handledFocusNonce = widget.focusRequestNonce;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _animateTo(widget.requestedFocusLocation!, 17.0);
        }
      });
    }
  }

  void _fitInitialReports() {
    if (!_mapReady ||
        _hasFittedReports ||
        widget.requestedFocusLocation != null ||
        widget.selectedReportId != null) {
      return;
    }
    final rows = filterAndSortAdminRows(
      widget.activeRows,
      filter: widget.filter,
      priorities: widget.priorities,
    ).where((row) => row.hasValidCoordinates).toList();
    if (rows.isEmpty) return;
    _hasFittedReports = true;
    _fitToRows(rows);
  }

  @override
  void dispose() {
    _cameraAnimation?.dispose();
    _mapCtrl.dispose();
    super.dispose();
  }

  void _animateTo(LatLng target, double targetZoom) {
    _cameraAnimation?.dispose();
    _cameraAnimation = null;
    try {
      if (MediaQuery.disableAnimationsOf(context)) {
        _mapCtrl.move(target, targetZoom);
        return;
      }
      final startLat = _mapCtrl.camera.center.latitude;
      final startLng = _mapCtrl.camera.center.longitude;
      final startZoom = _mapCtrl.camera.zoom;

      final ctrl = AnimationController(
        duration: const Duration(milliseconds: 550),
        vsync: this,
      );
      _cameraAnimation = ctrl;
      ctrl.addListener(() {
        if (!mounted) return;
        final progress = Curves.easeOutCubic.transform(ctrl.value);
        _mapCtrl.move(
          LatLng(
            startLat + (target.latitude - startLat) * progress,
            startLng + (target.longitude - startLng) * progress,
          ),
          startZoom + (targetZoom - startZoom) * progress,
        );
      });
      ctrl.forward();
    } catch (_) {
      try {
        _mapCtrl.move(target, targetZoom);
      } catch (_) {}
    }
  }

  void _fitToRows(List<AdminReportRow> rows) {
    _cameraAnimation?.stop();
    final pts = rows
        .where((r) => r.hasValidCoordinates)
        .map((r) => r.location!)
        .toList();
    if (pts.isEmpty) {
      _animateTo(_santaMariaCenter, 13.0);
      return;
    }
    if (pts.length == 1) {
      _animateTo(pts.first, 17.0);
      return;
    }
    try {
      _mapCtrl.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(48, 146, 72, 110),
          maxZoom: 16.5,
        ),
      );
    } catch (_) {}
  }

  List<_MapCluster> _clusterRows(List<AdminReportRow> rows) {
    final valid = rows.where((r) => r.hasValidCoordinates).toList();
    if (valid.isEmpty) return const [];
    final visited = <String>{};
    final out = <_MapCluster>[];

    for (var i = 0; i < valid.length; i++) {
      final seed = valid[i];
      if (visited.contains(seed.id)) continue;
      final group = <AdminReportRow>[seed];
      visited.add(seed.id);

      for (var j = i + 1; j < valid.length; j++) {
        final cand = valid[j];
        if (visited.contains(cand.id)) continue;
        final dist = Geolocator.distanceBetween(
          seed.location!.latitude,
          seed.location!.longitude,
          cand.location!.latitude,
          cand.location!.longitude,
        );
        if (dist <= 18.0) {
          group.add(cand);
          visited.add(cand.id);
        }
      }

      final lat =
          group.fold<double>(0, (s, r) => s + r.location!.latitude) /
          group.length;
      final lng =
          group.fold<double>(0, (s, r) => s + r.location!.longitude) /
          group.length;
      out.add(
        _MapCluster(
          id: 'cluster_${group.first.id}',
          center: LatLng(lat, lng),
          items: group,
        ),
      );
    }
    return out;
  }

  Widget _buildExpandedCluster(
    _MapCluster cluster, {
    required double radius,
    required bool isDark,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, progress, _) {
        final offsets = [
          for (var i = 0; i < cluster.items.length; i++)
            Offset(
              math.cos(2 * math.pi * i / cluster.items.length - math.pi / 2) *
                  radius *
                  progress,
              math.sin(2 * math.pi * i / cluster.items.length - math.pi / 2) *
                  radius *
                  progress,
            ),
        ];
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ClusterLinksPainter(
                    offsets,
                    WebDesign.textSecondary(isDark),
                  ),
                ),
              ),
            ),
            SizedBox.square(
              dimension: 44,
              child: WebMapMarkerButton(
                label: 'Collapse nearby reports',
                onTap: () => setState(() => _expandedClusterId = null),
                child: Center(
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: WebDesign.surface(isDark),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF00796B),
                        width: 3.2,
                      ),
                    ),
                    child: const Icon(Icons.close_rounded, size: 14),
                  ),
                ),
              ),
            ),
            for (var i = 0; i < cluster.items.length; i++)
              Transform.translate(
                offset: offsets[i],
                child: SizedBox.square(
                  dimension: 48,
                  child: WebMapMarkerButton(
                    label:
                        'Report #${cluster.items[i].shortId}, ${cluster.items[i].status.label}, ${cluster.items[i].defectLabel}',
                    onTap: () => widget.onSelectReportId(cluster.items[i].id),
                    child: Center(
                      child: _reportMarker(
                        cluster.items[i],
                        size: 32,
                        selected:
                            cluster.items[i].id == widget.selectedReportId,
                        compact: true,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _reportMarker(
    AdminReportRow row, {
    required double size,
    bool selected = false,
    bool compact = false,
  }) {
    if (row.defectClass == null) {
      return Icon(
        Icons.help_outline_rounded,
        size: size,
        color: WebDesign.textSecondary(
          Theme.of(context).brightness == Brightness.dark,
        ),
      );
    }
    return RoadHazardMarker(
      primaryDefect: row.defectClass!.name,
      status: row.status.wireValue,
      count: row.potholeCount,
      size: size,
      isSelected: selected,
      compact: compact,
      showPendingOwnerBadge: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final viewportWidth = constraints.maxWidth;
        final isWide = viewportWidth >= 1150;

        final filtered = filterAndSortAdminRows(
          widget.activeRows,
          filter: widget.filter,
          priorities: widget.priorities,
        );

        AdminReportRow? selectedRow;
        if (widget.selectedReportId != null) {
          for (final r in widget.activeRows) {
            if (r.id == widget.selectedReportId) {
              selectedRow = r;
              break;
            }
          }
        }

        final displaySet = <AdminReportRow>[...filtered];
        if (selectedRow != null &&
            selectedRow.hasValidCoordinates &&
            !displaySet.any((r) => r.id == selectedRow!.id)) {
          displaySet.add(selectedRow);
        }

        final clusters = _clusterRows(displaySet);
        final baseSize = RoadHazardMarker.sizeForZoom(_zoom);
        final markers = <Marker>[];

        for (final cluster in clusters) {
          if (cluster.isSingle) {
            final item = cluster.items.first;
            final isSel = item.id == widget.selectedReportId;
            final sz = isSel ? baseSize * 1.28 : baseSize;

            markers.add(
              Marker(
                key: ValueKey('map_pin_${item.id}'),
                point: item.location!,
                width: math.max(48, sz),
                height: math.max(48, sz),
                child: WebMapMarkerButton(
                  label:
                      'Report #${item.shortId}, ${item.status.label}, ${item.defectLabel}',
                  onTap: () {
                    setState(() => _expandedClusterId = null);
                    widget.onSelectReportId(item.id);
                    _animateTo(item.location!, math.max(_zoom, 17));
                  },
                  child: Center(
                    child: _reportMarker(item, size: sz, selected: isSel),
                  ),
                ),
              ),
            );
          } else if (_expandedClusterId == cluster.id) {
            final radius = cluster.items.length <= 4 ? 52.0 : 66.0;
            final box = (radius + 26) * 2;
            markers.add(
              Marker(
                key: ValueKey('map_spider_${cluster.id}'),
                point: cluster.center,
                width: box,
                height: box,
                child: _buildExpandedCluster(
                  cluster,
                  radius: radius,
                  isDark: isDark,
                ),
              ),
            );
          } else {
            final containsSel = cluster.items.any(
              (r) => r.id == widget.selectedReportId,
            );
            final sz = (baseSize + 4).clamp(22.0, 34.0);
            markers.add(
              Marker(
                key: ValueKey('map_cluster_${cluster.id}'),
                point: cluster.center,
                width: math.max(48, sz),
                height: math.max(48, sz),
                child: WebMapMarkerButton(
                  label: 'Expand ${cluster.items.length} nearby reports',
                  onTap: () {
                    setState(() => _expandedClusterId = cluster.id);
                    _animateTo(cluster.center, math.max(_zoom, 17.0));
                  },
                  child: Center(
                    child: SizedBox.square(
                      dimension: sz,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF9333EA),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: containsSel
                                    ? const Color(0xFF10B981)
                                    : Colors.white,
                                width: 2.2,
                              ),
                              boxShadow: WebDesign.shadowMd(isDark),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.hub_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00796B),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                '${cluster.items.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
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
        }

        final initialCenter =
            widget.requestedFocusLocation ??
            (selectedRow?.location) ??
            (displaySet.isNotEmpty
                ? displaySet
                          .firstWhere(
                            (r) => r.hasValidCoordinates,
                            orElse: () => displaySet.first,
                          )
                          .location ??
                      _santaMariaCenter
                : _santaMariaCenter);

        final mapStack = Stack(
          children: [
            FlutterMap(
              mapController: _mapCtrl,
              options: MapOptions(
                initialCenter: initialCenter,
                initialZoom: widget.requestedFocusLocation != null
                    ? 16.5
                    : 13.0,
                minZoom: 4.0,
                maxZoom: 19.0,
                onMapReady: () {
                  _mapReady = true;
                  _fitInitialReports();
                },
                onPositionChanged: (camera, hasGesture) {
                  if (hasGesture) {
                    _hasFittedReports = true;
                    _cameraAnimation?.stop();
                  }
                  if ((camera.zoom - _zoom).abs() >= 0.05 && mounted) {
                    setState(() => _zoom = camera.zoom);
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.roadsense.admin_web',
                  minZoom: 4,
                  maxZoom: 19,
                ),
                MarkerLayer(markers: markers),
              ],
            ),

            // Top Synchronized Filter Bar
            Positioned(
              top: isWide ? 12 : 10,
              left: isWide ? 12 : 10,
              right: isWide ? 12 : 10,
              child: Align(
                alignment: Alignment.topLeft,
                child: WebCard(
                  padding: isWide
                      ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
                      : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Builder(
                    builder: (context) {
                      final chipDensity = isWide ? null : VisualDensity.compact;
                      final tapSize = isWide
                          ? null
                          : MaterialTapTargetSize.shrinkWrap;
                      final chips = <Widget>[
                        ChoiceChip(
                          visualDensity: chipDensity,
                          materialTapTargetSize: tapSize,
                          label: const Text('Pending'),
                          selected:
                              widget.filter.statuses.length == 1 &&
                              widget.filter.statuses.contains(
                                AdminReportStatus.pending,
                              ),
                          onSelected: (_) => widget.onFilterChanged(
                            widget.filter.copyWith(
                              statuses: {AdminReportStatus.pending},
                            ),
                          ),
                        ),
                        ChoiceChip(
                          visualDensity: chipDensity,
                          materialTapTargetSize: tapSize,
                          label: const Text('Approved'),
                          selected:
                              widget.filter.statuses.length == 1 &&
                              widget.filter.statuses.contains(
                                AdminReportStatus.approved,
                              ),
                          onSelected: (_) => widget.onFilterChanged(
                            widget.filter.copyWith(
                              statuses: {AdminReportStatus.approved},
                            ),
                          ),
                        ),
                        ChoiceChip(
                          visualDensity: chipDensity,
                          materialTapTargetSize: tapSize,
                          label: const Text('Rejected'),
                          selected:
                              widget.filter.statuses.length == 1 &&
                              widget.filter.statuses.contains(
                                AdminReportStatus.rejected,
                              ),
                          onSelected: (_) => widget.onFilterChanged(
                            widget.filter.copyWith(
                              statuses: {AdminReportStatus.rejected},
                            ),
                          ),
                        ),
                        ChoiceChip(
                          visualDensity: chipDensity,
                          materialTapTargetSize: tapSize,
                          label: Text(
                            'All active (${widget.activeRows.length})',
                          ),
                          selected: widget.filter.statuses.isEmpty,
                          onSelected: (_) => widget.onFilterChanged(
                            widget.filter.copyWith(statuses: {}),
                          ),
                        ),
                        if (widget.filter.barangayFilterKey != null &&
                            widget.filter.barangayFilterKey!.isNotEmpty)
                          InputChip(
                            visualDensity: chipDensity,
                            materialTapTargetSize: tapSize,
                            label: Text(
                              widget.filter.barangayDisplayLabel ??
                                  widget.filter.barangayFilterKey!,
                            ),
                            onDeleted: () => widget.onFilterChanged(
                              widget.filter.copyWith(clearBarangay: true),
                            ),
                          ),
                      ];

                      if (isWide) {
                        return Wrap(
                          spacing: WebDesign.space2,
                          runSpacing: WebDesign.space2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: chips,
                        );
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (int i = 0; i < chips.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              chips[i],
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // Bottom-Left Legend + Fit Bounds Controls
            Positioned(
              left: isWide ? 12 : 10,
              right: isWide ? 76 : 62,
              bottom: isWide ? 12 : 10,
              child: WebCard(
                padding: isWide
                    ? const EdgeInsets.symmetric(
                        horizontal: WebDesign.space3,
                        vertical: WebDesign.space2,
                      )
                    : const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Wrap(
                  spacing: isWide ? WebDesign.space3 : 8,
                  runSpacing: isWide ? 6 : 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${displaySet.length} pin(s) visible',
                      style: WebDesign.tabular(
                        (Theme.of(context).textTheme.labelMedium ??
                                const TextStyle())
                            .copyWith(fontSize: isWide ? null : 11.5),
                      ),
                    ),
                    ...[
                      _LegendPin(
                        color: WebDesign.textSecondary(isDark),
                        label: 'Approved: class color',
                      ),
                      _LegendPin(
                        color: WebDesign.pendingLight,
                        label: 'Pending',
                      ),
                      _LegendPin(
                        color: WebDesign.textSecondary(isDark),
                        label: 'Rejected',
                      ),
                    ],
                    for (final cls in DpwhStandards.allClasses)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RoadHazardMarker(
                            primaryDefect: cls.name,
                            size: isWide ? 18 : 16,
                            showPendingOwnerBadge: false,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            cls.name,
                            style: TextStyle(fontSize: isWide ? 11 : 10.5),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            // Bottom-Right Map Camera Controls
            Positioned(
              right: isWide ? 12 : 10,
              bottom: isWide ? 12 : 10,
              child: WebCard(
                padding: EdgeInsets.all(isWide ? 4 : 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Zoom in',
                      visualDensity: isWide ? null : VisualDensity.compact,
                      constraints: isWide
                          ? null
                          : const BoxConstraints.tightFor(
                              width: 38,
                              height: 38,
                            ),
                      iconSize: isWide ? 24 : 19,
                      onPressed: () {
                        try {
                          _animateTo(
                            _mapCtrl.camera.center,
                            (_mapCtrl.camera.zoom + 1.2).clamp(4, 19),
                          );
                        } catch (_) {}
                      },
                      icon: const Icon(Icons.add_rounded),
                    ),
                    IconButton(
                      tooltip: 'Zoom out',
                      visualDensity: isWide ? null : VisualDensity.compact,
                      constraints: isWide
                          ? null
                          : const BoxConstraints.tightFor(
                              width: 38,
                              height: 38,
                            ),
                      iconSize: isWide ? 24 : 19,
                      onPressed: () {
                        try {
                          _animateTo(
                            _mapCtrl.camera.center,
                            (_mapCtrl.camera.zoom - 1.2).clamp(4, 19),
                          );
                        } catch (_) {}
                      },
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    IconButton(
                      tooltip: 'Fit filtered pins',
                      visualDensity: isWide ? null : VisualDensity.compact,
                      constraints: isWide
                          ? null
                          : const BoxConstraints.tightFor(
                              width: 38,
                              height: 38,
                            ),
                      iconSize: isWide ? 24 : 19,
                      onPressed: () => _fitToRows(displaySet),
                      icon: const Icon(Icons.fit_screen_outlined),
                    ),
                    IconButton(
                      tooltip: 'Center Brgy. Poblacion, Santa Maria',
                      visualDensity: isWide ? null : VisualDensity.compact,
                      constraints: isWide
                          ? null
                          : const BoxConstraints.tightFor(
                              width: 38,
                              height: 38,
                            ),
                      iconSize: isWide ? 24 : 19,
                      onPressed: () => _animateTo(_santaMariaCenter, 13.0),
                      icon: const Icon(Icons.home_work_outlined),
                    ),
                  ],
                ),
              ),
            ),

            // Compact mobile bottom preview sheet when selected on narrow screen
            if (!isWide && selectedRow != null)
              Positioned(
                left: 12,
                right: 72,
                bottom: 148,
                child: WebCard(
                  padding: const EdgeInsets.all(WebDesign.space3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              spacing: 6,
                              children: [
                                Text(
                                  '#${selectedRow.shortId}',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                AdminStatusBadge(status: selectedRow.status),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              selectedRow.displayLocation,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () => showAdminReportInspectorModal(
                          context,
                          row: selectedRow!,
                          priority: widget.priorities[selectedRow.id],
                          onLocateOnMap: (loc, _) => _animateTo(loc, 17.5),
                          onSoftDelete: widget.onSoftDelete,
                        ),
                        child: const Text('Inspect'),
                      ),
                      IconButton(
                        tooltip: 'Clear selection',
                        onPressed: () => widget.onSelectReportId(null),
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );

        if (isWide && selectedRow != null) {
          return Row(
            children: [
              Expanded(child: mapStack),
              VerticalDivider(width: 1, color: WebDesign.border(isDark)),
              SizedBox(
                width: 396,
                child: Padding(
                  padding: const EdgeInsets.all(WebDesign.space3),
                  child: AdminReportInspectorPanel(
                    row: selectedRow,
                    priority: widget.priorities[selectedRow.id],
                    onClose: () => widget.onSelectReportId(null),
                    onLocateOnMap: (loc, _) => _animateTo(loc, 17.5),
                    onSoftDelete: widget.onSoftDelete,
                  ),
                ),
              ),
            ],
          );
        }

        return mapStack;
      },
    );
  }
}

class _LegendPin extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendPin({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _ClusterLinksPainter extends CustomPainter {
  final List<Offset> offsets;
  final Color color;
  const _ClusterLinksPainter(this.offsets, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color.withValues(alpha: .65)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    for (final offset in offsets) {
      canvas.drawLine(center, center + offset, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ClusterLinksPainter oldDelegate) =>
      oldDelegate.offsets != offsets || oldDelegate.color != color;
}

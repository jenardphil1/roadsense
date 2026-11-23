import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dpwh_standards.dart';

class DeveloperMarker {
  final String id;
  final LatLng location;
  final String defect;
  const DeveloperMarker(this.id, this.location, this.defect);
}

/// Device/browser-local developer data. This store never calls the cloud.
class DeveloperMarkers extends ChangeNotifier {
  static final instance = DeveloperMarkers();
  static const prefix = 'developer_local_';
  static const _key = 'roadsense_developer_markers_v1';
  final List<DeveloperMarker> _items = [];
  Future<void>? _loading;
  bool _loaded = false;
  List<DeveloperMarker> get items => List.unmodifiable(_items);
  static bool owns(String? id) => id?.startsWith(prefix) ?? false;

  Future<void> load() async {
    if (_loaded) return;
    await (_loading ??= _load().whenComplete(() {
      _loaded = true;
      _loading = null;
    }));
  }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final raw in prefs.getStringList(_key) ?? <String>[]) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final lat = (data['lat'] as num).toDouble();
        final lng = (data['lng'] as num).toDouble();
        final cls = DpwhStandards.tryClassify(data['defect'] as String?);
        final id = data['id'] as String;
        if (!owns(id) ||
            cls == null ||
            !lat.isFinite ||
            !lng.isFinite ||
            lat.abs() > 90 ||
            lng.abs() > 180) {
          continue;
        }
        _items.add(DeveloperMarker(id, LatLng(lat, lng), cls.name));
      } catch (_) {
        // A malformed developer entry must not hide valid entries or real reports.
      }
    }
    notifyListeners();
  }

  Future<void> save(DeveloperMarker marker) async {
    await load();
    if (!owns(marker.id) ||
        DpwhStandards.tryClassify(marker.defect) == null ||
        !marker.location.latitude.isFinite ||
        !marker.location.longitude.isFinite ||
        marker.location.latitude.abs() > 90 ||
        marker.location.longitude.abs() > 180) {
      throw ArgumentError('Invalid developer marker.');
    }
    await _persist([..._items.where((m) => m.id != marker.id), marker]);
  }

  Future<void> remove(String id) async {
    await load();
    await _persist(_items.where((m) => m.id != id).toList());
  }

  Future<void> _persist(List<DeveloperMarker> next) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setStringList(_key, [
      for (final m in next)
        jsonEncode({
          'id': m.id,
          'lat': m.location.latitude,
          'lng': m.location.longitude,
          'defect': m.defect,
        }),
    ]);
    if (!saved) {
      throw StateError('Could not save developer markers on this device.');
    }
    _items
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}

class _DeveloperMarkerEditorDraft {
  final String? markerId;
  final String defect;
  final LatLng location;

  const _DeveloperMarkerEditorDraft({
    required this.markerId,
    required this.defect,
    required this.location,
  });
}

Future<void> showDeveloperMarkerEditor(
  BuildContext context, {
  required LatLng location,
  String? markerId,
  String? initialDefect,
  Future<LatLng?> Function(LatLng initialLocation)? onPickLocationOnMap,
}) async {
  final store = DeveloperMarkers.instance;
  await store.load();
  if (!context.mounted) return;
  final lat = TextEditingController(text: location.latitude.toStringAsFixed(6));
  final lng = TextEditingController(
    text: location.longitude.toStringAsFixed(6),
  );
  String? selectedId = markerId;
  var defect =
      (initialDefect != null && DpwhStandards.tryClassify(initialDefect) != null)
      ? DpwhStandards.tryClassify(initialDefect)!.name
      : DpwhStandards.pothole.name;
  var initialLocation = location;
  if (selectedId != null && store.items.any((m) => m.id == selectedId)) {
    final marker = store.items.firstWhere((m) => m.id == selectedId);
    defect = marker.defect;
    initialLocation = marker.location;
    lat.text = marker.location.latitude.toStringAsFixed(6);
    lng.text = marker.location.longitude.toStringAsFixed(6);
  } else {
    selectedId = null;
  }

  void select(String? id) {
    selectedId = id;
    if (id == null) return;
    final marker = store.items.firstWhere((m) => m.id == id);
    defect = marker.defect;
    lat.text = marker.location.latitude.toStringAsFixed(6);
    lng.text = marker.location.longitude.toStringAsFixed(6);
  }

  final navigator = Navigator.of(context, rootNavigator: true);
  final errorColor = Theme.of(context).colorScheme.error;
  try {
    while (context.mounted) {
      var busy = false;
      String? error;
      final route = DialogRoute<_DeveloperMarkerEditorDraft?>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Developer custom markers'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Local to this device/browser. These are not submitted reports. Turn Developer mode off to hide them.',
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey('developer-marker-$selectedId'),
                      initialValue: selectedId ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Marker to edit',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Add a new marker'),
                        ),
                        for (var i = 0; i < store.items.length; i++)
                          DropdownMenuItem(
                            value: store.items[i].id,
                            child: Text('${i + 1}. ${store.items[i].defect}'),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (id) => setState(() => select(id == '' ? null : id)),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('developer-defect-$selectedId'),
                      initialValue: defect,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Road defect class',
                      ),
                      items: [
                        for (final cls in DpwhStandards.allClasses)
                          DropdownMenuItem(
                            value: cls.name,
                            child: Text(cls.name),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (value) {
                              if (value != null) defect = value;
                            },
                    ),
                    const SizedBox(height: 12),
                    if (onPickLocationOnMap != null) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () {
                                  final parsedLat = double.tryParse(
                                    lat.text.trim(),
                                  );
                                  final parsedLng = double.tryParse(
                                    lng.text.trim(),
                                  );
                                  final seed =
                                      parsedLat != null &&
                                          parsedLng != null &&
                                          parsedLat.isFinite &&
                                          parsedLng.isFinite &&
                                          parsedLat.abs() <= 90 &&
                                          parsedLng.abs() <= 180
                                      ? LatLng(parsedLat, parsedLng)
                                      : initialLocation;
                                  Navigator.pop(
                                    dialogContext,
                                    _DeveloperMarkerEditorDraft(
                                      markerId: selectedId,
                                      defect: defect,
                                      location: seed,
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.add_location_alt_rounded),
                          label: const Text('Choose location on map'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: lat,
                      enabled: !busy,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Latitude'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: lng,
                      enabled: !busy,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Longitude'),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: errorColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              if (selectedId != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            await store.remove(selectedId!);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } catch (_) {
                            if (dialogContext.mounted) {
                              setState(() {
                                busy = false;
                                error = 'Could not remove this local marker.';
                              });
                            }
                          }
                        },
                  child: const Text('Remove'),
                ),
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        final latitude = double.tryParse(lat.text.trim());
                        final longitude = double.tryParse(lng.text.trim());
                        if (latitude == null ||
                            longitude == null ||
                            !latitude.isFinite ||
                            !longitude.isFinite ||
                            latitude.abs() > 90 ||
                            longitude.abs() > 180) {
                          setState(
                            () => error =
                                'Enter valid latitude (-90 to 90) and longitude (-180 to 180).',
                          );
                          return;
                        }
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await store.save(
                            DeveloperMarker(
                              selectedId ??
                                  '${DeveloperMarkers.prefix}${DateTime.now().microsecondsSinceEpoch}',
                              LatLng(latitude, longitude),
                              defect,
                            ),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (_) {
                          if (dialogContext.mounted) {
                            setState(() {
                              busy = false;
                              error = 'Could not save this local marker.';
                            });
                          }
                        }
                      },
                child: Text(busy ? 'Saving…' : 'Save local marker'),
              ),
            ],
          ),
        ),
      );
      final draft = await navigator.push(route);
      // Keep controllers alive until the dialog's closing animation is removed.
      await route.completed;
      if (draft == null || onPickLocationOnMap == null) {
        break;
      }
      final picked = await onPickLocationOnMap(draft.location);
      if (!context.mounted) break;
      selectedId = draft.markerId;
      defect = draft.defect;
      initialLocation = picked ?? draft.location;
      lat.text = initialLocation.latitude.toStringAsFixed(6);
      lng.text = initialLocation.longitude.toStringAsFixed(6);
    }
  } finally {
    lat.dispose();
    lng.dispose();
  }
}

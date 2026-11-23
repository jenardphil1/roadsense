import 'dart:convert';

/// MapLibre GL style & GeoJSON builders for RoadSense AI.
///
/// Uses OpenFreeMap planet vector tiles (`https://tiles.openfreemap.org/planet`)
/// by default so the entire Philippines (and beyond) renders with 0 MB APK
/// bloat, while supporting an optional self-hosted/local `.pmtiles` URL.
class RoadSenseMapLibreStyle {
  RoadSenseMapLibreStyle._();

  static const String openFreeMapTileJsonUrl =
      'https://tiles.openfreemap.org/planet';
  static const String openFreeMapGlyphsUrl =
      'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';

  /// Approximate boundary polygon of Barangay Poblacion, Santa Maria, Bulacan
  /// (`[lng, lat]` pairs, closed ring) matching the municipal river & road borders.
  static const List<List<double>> poblacionBoundaryLngLat = <List<double>>[
    [120.9488, 14.8226], // NW near J.P. Rizal St / river bend
    [120.9522, 14.8240], // North river bend
    [120.9560, 14.8235], // North near Sacred Heart Academy / Dr. T. Santiago St
    [120.9605, 14.8242], // NE boundary near Norzagaray Rd
    [120.9632, 14.8236], // NE corner
    [120.9620, 14.8204], // East near P. Luciano St
    [120.9626, 14.8180], // East near R. Mercado St
    [120.9612, 14.8152], // SE boundary near Santa Maria River
    [120.9585, 14.8134], // South river bend
    [120.9548, 14.8132], // South Santa Maria River
    [120.9514, 14.8154], // SW near Gov. Fortunato Halili Rd
    [120.9492, 14.8188], // West near Meralco / Sta. Maria Town Center
    [120.9488, 14.8226], // Closed ring
  ];

  /// GeoJSON FeatureCollection for the Barangay Poblacion highlight polygon.
  static String buildPoblacionBoundaryGeoJson() {
    return jsonEncode(<String, Object?>{
      'type': 'FeatureCollection',
      'features': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'Feature',
          'geometry': <String, Object?>{
            'type': 'Polygon',
            'coordinates': <List<List<double>>>[poblacionBoundaryLngLat],
          },
          'properties': const <String, Object?>{
            'name': 'Brgy. Poblacion',
          },
        },
      ],
    });
  }

  /// Returns a MapLibre GL v8 style JSON string matching the SakayLaguna
  /// dark `#0f1115` 3D vector aesthetic (or a crisp Light mode equivalent).
  static String buildStyleJson({
    required bool isDark,
    String? customPmtilesUrl,
  }) {
    final bg = isDark ? '#0f1115' : '#f4f6f9';
    final landcover = isDark ? '#131720' : '#eaedf2';
    final park = isDark ? '#12211c' : '#dff0e4';
    final water = isDark ? '#0b1622' : '#cbe4f9';
    final building = isDark ? '#181c24' : '#e2e6ed';
    final buildingOutline = isDark ? '#232936' : '#cfd6e0';
    final roadMinor = isDark ? '#232834' : '#ffffff';
    final roadMajorCasing = isDark ? '#0b0d11' : '#cfd6e2';
    final roadSecondary = isDark ? '#2c3342' : '#fefefe';
    final roadPrimary = isDark ? '#384152' : '#fde68a';
    final roadMotorway = isDark ? '#475569' : '#fbbf24';
    final labelPrimary = isDark ? '#e2e8f0' : '#1e293b';
    final labelSecondary = isDark ? '#94a3b8' : '#475569';
    final labelHalo = isDark ? '#0f1115' : '#ffffff';

    final Map<String, Object?> sourceSpec =
        (customPmtilesUrl != null && customPmtilesUrl.trim().isNotEmpty)
        ? <String, Object?>{
            'type': 'vector',
            'url': customPmtilesUrl.trim(),
            'attribution': '© OpenStreetMap contributors',
          }
        : <String, Object?>{
            'type': 'vector',
            'url': openFreeMapTileJsonUrl,
            'attribution': '© OpenStreetMap contributors',
          };

    final style = <String, Object?>{
      'version': 8,
      'name': isDark ? 'RoadSense Dark 3D' : 'RoadSense Light 3D',
      'glyphs': openFreeMapGlyphsUrl,
      'sources': <String, Object?>{
        'openmaptiles': sourceSpec,
      },
      'layers': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'background',
          'type': 'background',
          'paint': <String, Object?>{'background-color': bg},
        },
        <String, Object?>{
          'id': 'landcover',
          'type': 'fill',
          'source': 'openmaptiles',
          'source-layer': 'landcover',
          'paint': <String, Object?>{
            'fill-color': landcover,
            'fill-opacity': 0.55,
          },
        },
        <String, Object?>{
          'id': 'park',
          'type': 'fill',
          'source': 'openmaptiles',
          'source-layer': 'park',
          'paint': <String, Object?>{
            'fill-color': park,
            'fill-opacity': 0.65,
          },
        },
        <String, Object?>{
          'id': 'water',
          'type': 'fill',
          'source': 'openmaptiles',
          'source-layer': 'water',
          'paint': <String, Object?>{'fill-color': water},
        },
        <String, Object?>{
          'id': 'waterway',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'waterway',
          'paint': <String, Object?>{
            'line-color': water,
            'line-width': 1.5,
          },
        },
        <String, Object?>{
          'id': 'building-3d',
          'type': 'fill-extrusion',
          'source': 'openmaptiles',
          'source-layer': 'building',
          'minzoom': 14,
          'paint': <String, Object?>{
            'fill-extrusion-color': building,
            'fill-extrusion-height': <Object?>[
              'coalesce',
              <Object?>['get', 'render_height'],
              8,
            ],
            'fill-extrusion-base': <Object?>[
              'coalesce',
              <Object?>['get', 'render_min_height'],
              0,
            ],
            'fill-extrusion-opacity': isDark ? 0.78 : 0.65,
          },
        },
        <String, Object?>{
          'id': 'building-outline',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'building',
          'minzoom': 14,
          'paint': <String, Object?>{
            'line-color': buildingOutline,
            'line-width': 0.6,
          },
        },
        <String, Object?>{
          'id': 'road-minor-casing',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'filter': <Object?>[
            'in',
            'class',
            'minor',
            'service',
            'track',
          ],
          'layout': <String, Object?>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          'paint': <String, Object?>{
            'line-color': roadMajorCasing,
            'line-width': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              12,
              1.0,
              16,
              5.5,
            ],
          },
        },
        <String, Object?>{
          'id': 'road-minor',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'filter': <Object?>[
            'in',
            'class',
            'minor',
            'service',
            'track',
          ],
          'layout': <String, Object?>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          'paint': <String, Object?>{
            'line-color': roadMinor,
            'line-width': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              12,
              0.7,
              16,
              4.0,
            ],
          },
        },
        <String, Object?>{
          'id': 'road-secondary',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'filter': <Object?>[
            'in',
            'class',
            'secondary',
            'tertiary',
          ],
          'layout': <String, Object?>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          'paint': <String, Object?>{
            'line-color': roadSecondary,
            'line-width': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              10,
              1.2,
              16,
              7.0,
            ],
          },
        },
        <String, Object?>{
          'id': 'road-primary',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'filter': <Object?>[
            'in',
            'class',
            'primary',
            'trunk',
          ],
          'layout': <String, Object?>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          'paint': <String, Object?>{
            'line-color': roadPrimary,
            'line-width': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              8,
              1.5,
              16,
              9.0,
            ],
          },
        },
        <String, Object?>{
          'id': 'road-motorway',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'filter': <Object?>['==', 'class', 'motorway'],
          'layout': <String, Object?>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          'paint': <String, Object?>{
            'line-color': roadMotorway,
            'line-width': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              7,
              1.8,
              16,
              10.5,
            ],
          },
        },
        <String, Object?>{
          'id': 'road-label',
          'type': 'symbol',
          'source': 'openmaptiles',
          'source-layer': 'transportation_name',
          'minzoom': 12,
          'layout': <String, Object?>{
            'symbol-placement': 'line',
            'text-field': <Object?>['get', 'name'],
            'text-font': <String>['Noto Sans Regular'],
            'text-size': 11,
          },
          'paint': <String, Object?>{
            'text-color': labelSecondary,
            'text-halo-color': labelHalo,
            'text-halo-width': 1.2,
          },
        },
        <String, Object?>{
          'id': 'place-label',
          'type': 'symbol',
          'source': 'openmaptiles',
          'source-layer': 'place',
          'layout': <String, Object?>{
            'text-field': <Object?>['get', 'name'],
            'text-font': <String>['Noto Sans Bold'],
            'text-size': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              6,
              11,
              14,
              14,
            ],
          },
          'paint': <String, Object?>{
            'text-color': labelPrimary,
            'text-halo-color': labelHalo,
            'text-halo-width': 1.5,
          },
        },
      ],
    };
    return jsonEncode(style);
  }

  /// Builds a GeoJSON FeatureCollection string for hazard points.
  static String buildHazardsGeoJson(Iterable<Map<String, Object?>> items) {
    final features = <Map<String, Object?>>[];
    for (final item in items) {
      final lat = (item['lat'] as num?)?.toDouble();
      final lng = (item['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      features.add(<String, Object?>{
        'type': 'Feature',
        'id': item['id'],
        'geometry': <String, Object?>{
          'type': 'Point',
          'coordinates': <double>[lng, lat],
        },
        'properties': <String, Object?>{
          'id': item['id'] ?? '',
          'defect': item['defect'] ?? 'Pothole',
          'color': item['color'] ?? '#EA580C',
          'status': item['status'] ?? 'approved',
        },
      });
    }
    return jsonEncode(<String, Object?>{
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  /// Builds a GeoJSON FeatureCollection string for OSRM routes.
  static String buildRoutesGeoJson(
    List<List<List<double>>> routes,
    int activeIndex,
  ) {
    final features = <Map<String, Object?>>[];
    for (int i = 0; i < routes.length; i++) {
      final pts = routes[i];
      if (pts.length < 2) continue;
      features.add(<String, Object?>{
        'type': 'Feature',
        'geometry': <String, Object?>{
          'type': 'LineString',
          'coordinates': pts,
        },
        'properties': <String, Object?>{
          'routeIndex': i,
          'isActive': i == activeIndex ? 1 : 0,
        },
      });
    }
    return jsonEncode(<String, Object?>{
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  /// Builds a single-point GeoJSON FeatureCollection string for the user puck.
  static String buildUserPuckGeoJson(double? lat, double? lng) {
    if (lat == null || lng == null) {
      return '{"type":"FeatureCollection","features":[]}';
    }
    return jsonEncode(<String, Object?>{
      'type': 'FeatureCollection',
      'features': <Map<String, Object?>>[
        <String, Object?>{
          'type': 'Feature',
          'geometry': <String, Object?>{
            'type': 'Point',
            'coordinates': <double>[lng, lat],
          },
          'properties': const <String, Object?>{},
        },
      ],
    });
  }
}

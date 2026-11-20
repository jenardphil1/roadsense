import 'package:latlong2/latlong.dart';

/// Doc ID prefix identifying in-memory sample Sta. Maria test markers so they
/// never attempt Firestore writes or moderation mutations.
const String kSampleStaMariaDocPrefix = 'sample_sta_maria_';

/// Returns true when [docId] belongs to the built-in Sta. Maria test dataset.
bool isSampleStaMariaMarkerId(String? docId) =>
    docId != null && docId.startsWith(kSampleStaMariaDocPrefix);

/// Specification for an in-memory road defect test marker in Santa Maria, Bulacan.
class StaMariaSamplePotholeSpec {
  final String docId;
  final LatLng location;
  final String barangay;
  final String formattedAddress;
  final String primaryDefect;
  final String primaryDpwhCode;
  final String overallSeverity;
  final int potholeCount;

  const StaMariaSamplePotholeSpec({
    required this.docId,
    required this.location,
    required this.barangay,
    required this.formattedAddress,
    required this.primaryDefect,
    required this.primaryDpwhCode,
    this.overallSeverity = 'medium',
    this.potholeCount = 1,
  });
}

/// Curated test markers placed directly on real OSRM road coordinates across
/// Santa Maria, Bulacan corridors and barangays so route pothole counting,
/// alternate route suggestions, and meter countdowns can be verified immediately.
const List<StaMariaSamplePotholeSpec> staMariaSamplePotholeSpecs = [
  // Primary Poblacion -> Caypombo -> Pulong Buhangin corridor (6 markers)
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}poblacion_jp_rizal',
    location: LatLng(14.823109, 120.956927),
    barangay: 'Poblacion',
    formattedAddress: 'J.P. Rizal St, Barangay Poblacion, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'high',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}guyong_junction',
    location: LatLng(14.830825, 120.964131),
    barangay: 'Guyong',
    formattedAddress:
        'Gov. Fortunato Halili Ave, Barangay Guyong, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'high',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}manggahan_caypombo_rd',
    location: LatLng(14.836903, 120.977089),
    barangay: 'Manggahan',
    formattedAddress:
        'Manggahan-Caypombo Rd, Barangay Manggahan, Santa Maria, Bulacan',
    primaryDefect: 'Alligator crack',
    primaryDpwhCode: 'CODE 02',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}caypombo_crossing',
    location: LatLng(14.850128, 120.982364),
    barangay: 'Caypombo',
    formattedAddress:
        'Santa Maria-Norzagaray Rd, Barangay Caypombo, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'high',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}pulong_buhangin_west',
    location: LatLng(14.859802, 120.990342),
    barangay: 'Pulong Buhangin',
    formattedAddress:
        'Norzagaray Rd Approach, Barangay Pulong Buhangin, Santa Maria, Bulacan',
    primaryDefect: 'Transverse crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}pulong_buhangin_proper',
    location: LatLng(14.861777, 120.997428),
    barangay: 'Pulong Buhangin',
    formattedAddress:
        'Km 38 Road Section, Barangay Pulong Buhangin, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'medium',
  ),

  // Alternate Caysio bypass corridor (kept lighter so Route 2 has fewer potholes)
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}caysio_bypass',
    location: LatLng(14.849710, 121.002619),
    barangay: 'Caysio',
    formattedAddress: 'Caysio Bypass Rd, Barangay Caysio, Santa Maria, Bulacan',
    primaryDefect: 'Longitudinal crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'low',
  ),

  // Additional barangays & arteries around Santa Maria, Bulacan
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}bagbaguin_halili',
    location: LatLng(14.814042, 120.956897),
    barangay: 'Bagbaguin',
    formattedAddress:
        'Gov. Fortunato Halili Ave, Barangay Bagbaguin, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'high',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}bagbaguin_south',
    location: LatLng(14.810987, 120.956854),
    barangay: 'Bagbaguin',
    formattedAddress:
        'Bagbaguin South Corridor, Barangay Bagbaguin, Santa Maria, Bulacan',
    primaryDefect: 'Longitudinal crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}parada_main',
    location: LatLng(14.801481, 120.960399),
    barangay: 'Parada',
    formattedAddress:
        'Parada-San Jose Rd, Barangay Parada, Santa Maria, Bulacan',
    primaryDefect: 'Alligator crack',
    primaryDpwhCode: 'CODE 02',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}santa_clara_bypass',
    location: LatLng(14.817471, 120.953611),
    barangay: 'Santa Clara',
    formattedAddress:
        'Santa Clara Bypass Rd, Barangay Santa Clara, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'high',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}san_gabriel_rd',
    location: LatLng(14.820524, 120.962766),
    barangay: 'San Gabriel',
    formattedAddress:
        'San Gabriel Rd, Barangay San Gabriel, Santa Maria, Bulacan',
    primaryDefect: 'Transverse crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'low',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}san_vicente_rd',
    location: LatLng(14.823045, 120.951994),
    barangay: 'San Vicente',
    formattedAddress:
        'San Vicente Rd, Barangay San Vicente, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}camangyanan_rd',
    location: LatLng(14.810701, 120.943830),
    barangay: 'Camangyanan',
    formattedAddress:
        'Camangyanan Main Rd, Barangay Camangyanan, Santa Maria, Bulacan',
    primaryDefect: 'Longitudinal crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'low',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}tumana_rd',
    location: LatLng(14.823928, 120.971540),
    barangay: 'Tumana',
    formattedAddress:
        'Tumana-Silangan Rd, Barangay Tumana, Santa Maria, Bulacan',
    primaryDefect: 'Alligator crack',
    primaryDpwhCode: 'CODE 02',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}catmon_rd',
    location: LatLng(14.826594, 120.983835),
    barangay: 'Catmon',
    formattedAddress: 'Catmon-Bulac Rd, Barangay Catmon, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}bulac_main',
    location: LatLng(14.849666, 121.001888),
    barangay: 'Bulac',
    formattedAddress: 'Bulac Main Rd, Barangay Bulac, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'high',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}balasing_north',
    location: LatLng(14.863822, 121.000951),
    barangay: 'Balasing',
    formattedAddress:
        'Balasing Main Rd, Barangay Balasing, Santa Maria, Bulacan',
    primaryDefect: 'Alligator crack',
    primaryDpwhCode: 'CODE 02',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}bulac_west',
    location: LatLng(14.854048, 120.990760),
    barangay: 'Bulac',
    formattedAddress: 'Bulac West Bypass, Barangay Bulac, Santa Maria, Bulacan',
    primaryDefect: 'Transverse crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'low',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}mag_asawang_sapa',
    location: LatLng(14.873061, 121.007050),
    barangay: 'Mag-asawang Sapa',
    formattedAddress:
        'Mag-asawang Sapa Rd, Barangay Mag-asawang Sapa, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'medium',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}silangan_rd',
    location: LatLng(14.834930, 121.011747),
    barangay: 'Silangan',
    formattedAddress: 'Silangan Rd, Barangay Silangan, Santa Maria, Bulacan',
    primaryDefect: 'Longitudinal crack',
    primaryDpwhCode: 'CODE 12',
    overallSeverity: 'low',
  ),
  StaMariaSamplePotholeSpec(
    docId: '${kSampleStaMariaDocPrefix}lalakhan_jct',
    location: LatLng(14.818596, 120.960743),
    barangay: 'Lalakhan',
    formattedAddress:
        'Lalakhan Junction, Barangay Lalakhan, Santa Maria, Bulacan',
    primaryDefect: 'Pothole',
    primaryDpwhCode: 'CODE 01',
    overallSeverity: 'medium',
  ),
];

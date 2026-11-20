import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Detections table: Local-first SQLite store for all road distress markers.
/// id is a UUID v4 serving as the unique sync idempotency key.
/// Active Package 6 class IDs: 0, 1, 3, 4. Slot 2 is untrained depression.
class Detections extends Table {
  TextColumn get id => text()(); // UUID v4 idempotency key
  IntColumn get classId =>
      integer()(); // Package 6: 0=Pothole, 1=Alligator, 3=Longitudinal, 4=Transverse
  RealColumn get confidence => real()(); // Model confidence 0.0 - 1.0
  RealColumn get lat => real()(); // Latitude
  RealColumn get lng => real()(); // Longitude
  RealColumn get accuracyM => real().named(
    'accuracy_m',
  )(); // GPS accuracy in meters (Position.accuracy)
  DateTimeColumn get capturedAt => dateTime()(); // Capture timestamp
  TextColumn get note => text().nullable()(); // Surveyor note or road name
  TextColumn get imagePath =>
      text().nullable()(); // Local image path or remote URL
  TextColumn get thumbPath =>
      text().nullable()(); // Local 96px thumbnail or remote URL
  TextColumn get remoteId =>
      text().named('remote_id').nullable()(); // Backend ID (Firestore doc ID)
  BoolColumn get pendingSync => boolean().withDefault(
    const Constant(true),
  )(); // Dirty flag for background sync
  BoolColumn get gpsPending => boolean()
      .named('gps_pending')
      .withDefault(const Constant(false))(); // Weak GPS pending refinement
  DateTimeColumn get deletedAt =>
      dateTime().named('deleted_at').nullable()(); // Tombstone for sync
  DateTimeColumn get updatedAt => dateTime().named('updated_at').nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Detections])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'roadsense_dpwh');
  }

  // ── Spatial Viewport Queries ─────────────────────────────────────────────

  /// Fetch detections inside the map viewport bounding box (lat/lng BETWEEN)
  /// with limit (default 500 per performance spec) and filters.
  /// Excludes soft-deleted items (tombstones).
  Future<List<Detection>> getDetectionsInViewport({
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
    Set<int>? allowedClassIds,
    DateTime? since,
    bool? pendingSyncOnly,
    int limit = 500,
  }) {
    final query = select(detections)
      ..where((tbl) {
        Expression<bool> predicate =
            tbl.deletedAt.isNull() &
            tbl.lat.isBiggerOrEqualValue(minLat) &
            tbl.lat.isSmallerOrEqualValue(maxLat) &
            tbl.lng.isBiggerOrEqualValue(minLng) &
            tbl.lng.isSmallerOrEqualValue(maxLng);

        if (allowedClassIds != null && allowedClassIds.isNotEmpty) {
          predicate = predicate & tbl.classId.isIn(allowedClassIds);
        }
        if (since != null) {
          predicate = predicate & tbl.capturedAt.isBiggerOrEqualValue(since);
        }
        if (pendingSyncOnly == true) {
          predicate = predicate & tbl.pendingSync.equals(true);
        }
        return predicate;
      })
      ..limit(limit);

    return query.get();
  }

  /// Watch detections inside the viewport as a reactive Stream
  Stream<List<Detection>> watchDetectionsInViewport({
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
    Set<int>? allowedClassIds,
    DateTime? since,
    bool? pendingSyncOnly,
    int limit = 500,
  }) {
    final query = select(detections)
      ..where((tbl) {
        Expression<bool> predicate =
            tbl.deletedAt.isNull() &
            tbl.lat.isBiggerOrEqualValue(minLat) &
            tbl.lat.isSmallerOrEqualValue(maxLat) &
            tbl.lng.isBiggerOrEqualValue(minLng) &
            tbl.lng.isSmallerOrEqualValue(maxLng);

        if (allowedClassIds != null && allowedClassIds.isNotEmpty) {
          predicate = predicate & tbl.classId.isIn(allowedClassIds);
        }
        if (since != null) {
          predicate = predicate & tbl.capturedAt.isBiggerOrEqualValue(since);
        }
        if (pendingSyncOnly == true) {
          predicate = predicate & tbl.pendingSync.equals(true);
        }
        return predicate;
      })
      ..limit(limit);

    return query.watch();
  }

  /// Instant local search by note or road name (offline-capable)
  Future<List<Detection>> searchDetections(String term, {int limit = 50}) {
    final cleanTerm = '%${term.trim()}%';
    return (select(detections)
          ..where((tbl) => tbl.deletedAt.isNull() & tbl.note.like(cleanTerm))
          ..limit(limit))
        .get();
  }

  // ── Sync & Mutation Operations ───────────────────────────────────────────

  /// Insert or replace a detection record (idempotent upsert by UUID)
  Future<void> upsertDetection(DetectionsCompanion entry) {
    return into(detections).insertOnConflictUpdate(entry);
  }

  /// Batch upsert from remote or local imports
  Future<void> batchUpsert(List<DetectionsCompanion> entries) {
    return batch((b) {
      b.insertAllOnConflictUpdate(detections, entries);
    });
  }

  /// Get pending unsynced records (for batch sync, ≤ 10 records per batch)
  Future<List<Detection>> getPendingSync({int limit = 10}) {
    return (select(detections)
          ..where((tbl) => tbl.pendingSync.equals(true))
          ..limit(limit))
        .get();
  }

  /// Watch count of pending sync records (for the top-of-map sync banner)
  Stream<int> watchPendingSyncCount() {
    final countExpr = detections.id.count();
    final query = selectOnly(detections)
      ..addColumns([countExpr])
      ..where(detections.pendingSync.equals(true));

    return query.map((row) => row.read(countExpr) ?? 0).watchSingle();
  }

  /// Mark detection as synced after server ACK
  Future<int> markSynced(String id, {String? remoteId}) {
    return (update(detections)..where((tbl) => tbl.id.equals(id))).write(
      DetectionsCompanion(
        pendingSync: const Value(false),
        remoteId: remoteId != null ? Value(remoteId) : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Soft delete: Mark tombstone and flag for sync deletion
  Future<int> softDelete(String id) {
    return (update(detections)..where((tbl) => tbl.id.equals(id))).write(
      DetectionsCompanion(
        deletedAt: Value(DateTime.now()),
        pendingSync: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Hard delete (after server confirms tombstone deletion or on test cleanup)
  Future<int> hardDelete(String id) {
    return (delete(detections)..where((tbl) => tbl.id.equals(id))).go();
  }

  /// Get total count of active defects (excluding deleted tombstones)
  Future<int> getActiveCount() {
    final countExpr = detections.id.count();
    final query = selectOnly(detections)
      ..addColumns([countExpr])
      ..where(detections.deletedAt.isNull());
    return query.map((row) => row.read(countExpr) ?? 0).getSingle();
  }

  /// Get defect counts grouped by class ID (0..4) for dashboard & legend
  Future<Map<int, int>> getClassDistribution() async {
    final countExpr = detections.id.count();
    final query = selectOnly(detections)
      ..addColumns([detections.classId, countExpr])
      ..where(detections.deletedAt.isNull())
      ..groupBy([detections.classId]);

    final rows = await query.get();
    final Map<int, int> result = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0};
    for (final row in rows) {
      final cls = row.read(detections.classId);
      final count = row.read(countExpr);
      if (cls != null && count != null && result.containsKey(cls)) {
        result[cls] = count;
      }
    }
    return result;
  }
}

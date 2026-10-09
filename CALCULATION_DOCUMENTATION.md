# Pothole Scanner and Route Calculation Documentation

This document explains how the system calculates scanner detections, pothole plotting, route pothole counts, warning distances, and ETA.

## 1. Scanner Calculation Flow

File references:
- Scanner pipeline: lib/main.dart
- Route and proximity logic: lib/map_screen.dart

### 1.1 Model input and inference
The app uses a YOLOv8 TFLite model loaded from assets.

- Realtime mode:
  - Captures camera frames periodically.
  - Runs YOLO on each frame.
  - Thresholds:
    - IoU threshold: 0.3
    - Confidence threshold: 0.20
    - Class threshold: 0.20
- Static photo mode:
  - Captures a still image.
  - Runs YOLO once on the image.
  - Thresholds:
    - IoU threshold: 0.5
    - Confidence threshold: 0.20
    - Class threshold: 0.20

Output from YOLO is a list of bounding boxes with class tag and confidence.

### 1.2 Detection to saved pothole marker
When user taps Send to Map:
1. Get current GPS position.
2. Render bounding boxes onto the image.
3. Save annotated image file.
4. Insert pothole record into SQLite with:
   - latitude
   - longitude
   - image path
   - timestamp

So one plotted pothole marker corresponds to one saved event with photo evidence.

## 2. Route Calculation Flow

### 2.1 Route generation
The app requests routes from OpenRouteService (driving-car profile) and asks for alternatives.

For each returned route:
- Decode polyline coordinates into route points.
- Read route duration from ORS response.

### 2.2 Pothole counting on a route (updated to reduce false positives)
Problem before:
- The system used a wide point-radius match, which could count potholes on nearby parallel lanes.

Current method:
- First, pothole coordinates are road-aligned using OpenRouteService Snap V2 (`/v2/snap/driving-car/json`).
  - Request body sends pothole locations as `[lon, lat]`.
  - Snap radius used by app: 35 meters.
  - If a point cannot be snapped (null/too far), system safely falls back to the original GPS point.
- Snapped results are cached in memory so repeated route recalculations do not keep calling Snap for the same marker.
- For each pothole and each route segment, compute point-to-segment distance in meters.
- If minimum distance to any segment is within tolerance, pothole is considered on-route.

Tolerances:
- Route count tolerance: 12.0 meters
- Route warning/on-route list tolerance: 14.0 meters

This is lane-aware and stricter than broad radius matching, reducing wrong counts from adjacent roads.
Road snapping further reduces misses caused by GPS drift and helps collision checks stay on the drivable network.

### 2.3 Point-to-segment distance model
Each lat/lon segment is converted to a local meter plane using:
- metersPerDegLat = 110540
- metersPerDegLon = 111320 * cos(latitude)

For point P and segment AB:
1. Project vector AP onto AB using parameter t.
2. Clamp t to [0, 1].
3. Compute distance from P to closest point on AB.

This gives a better geometric road-match than nearest-route-point radius checks.
The nearest point on each segment acts as the collision point used by route matching.

## 3. Proximity Warning Calculation

### 3.1 Immediate danger zone
System finds nearest pothole distance to current user GPS.

- If nearest distance <= 22 meters:
  - Proximity warning is active.
  - Warning chip appears.
  - TTS warning is triggered once per nearby pothole key.

### 3.2 Next pothole ahead in route mode
When a route is active:
- System uses potholes already filtered as on-route.
- Finds user closest route index.
- Computes forward driving distance to upcoming on-route potholes.
- Displays nearest upcoming pothole distance in the top card.

## 4. ETA Calculation

ORS provides base duration in seconds.

Displayed ETA uses a practical road-condition buffer:
- ETA minutes = round((durationSeconds * 1.35) / 60)

This avoids unrealistically optimistic ETA in local driving conditions.

## 5. Nearby Search Calculation

Search uses OpenRouteService geocoding with location bias and circle boundary:
- focus.point lat/lon = current user location
- boundary.circle lat/lon = current user location
- boundary.circle radius:
  - autocomplete: 12 km
  - final search: 15 km

This prioritizes nearby destinations for faster and more relevant route selection.

## 6. Notes on Accuracy and Limits

- Marker accuracy depends on phone GPS quality.
- Parallel roads very close together may still need tighter tolerance depending on area.
- If needed, route-match tolerances can be tuned per environment.
- Scanner confidence thresholds can be increased to reduce false positives, but this may miss weak pothole cases.

## 7. Approval Priority Calculation (Admin Review Queue)

This section explains how the admin dashboard decides which pending report to
approve first.

File references:
- Algorithm: lib/approval_priority.dart
- Queue integration: lib/admin_dashboard_screen.dart (`_buildPotholeList`)
- Report schema written by the app: lib/cloud_service.dart (`addPotholeToCloud`)

### 7.1 What the score means

The queue is not ordered by "which pothole is worst". It is ordered by the
**expected cost of leaving a decision pending**. A high-severity claim from a
reporter whose last eight submissions were all rejected costs little to delay,
because it probably is not real.

That gives the structure:

```
urgency = harm x credibility x exposure
score   = 100 x (0.75 x urgency + 0.25 x aging)
```

Urgency is **multiplicative** because the three factors gate each other: a
report nobody can verify has near-zero expected cost however severe the claim.
Additive weighting cannot express that.

Aging is **additive and uncapped**, which is what guarantees no starvation. It
can override the product instead of being scaled by it.

### 7.2 Inputs

All four factors are derived from fields the app already writes. No schema
change and no extra Firestore reads: the dashboard already streams the whole
collection, so reporter history and neighbour counts are free.

| Field | Used for |
| --- | --- |
| `overallSeverity` | Harm |
| `potholeCount` | Harm (scale) |
| `detections[].confidence` | Credibility (model confidence) |
| `status` of the reporter's other docs | Credibility (reporter trust) |
| `latitude`, `longitude`, `reporterUid` | Credibility (corroboration), Exposure |
| `imageUrl` | Credibility (photo multiplier) |
| `timestamp` | Aging |

Note: the report document has **no top-level `severity` field**. The scanner
writes `overallSeverity`. Reading `data['severity']` silently yields `'medium'`
for every report and flattens the ranking.

### 7.3 Harm — how bad if it is real

```
H     = 0.70 x sevW + 0.30 x scale
sevW  = high 1.0 | medium 0.6 | low 0.3
scale = clamp(ln(count) / ln(6), 0, 1)
```

The log saturates so a 40-pothole report cannot run away with the queue; beyond
6 the marginal danger of one more pothole is negligible.

| potholeCount | 1 | 2 | 3 | 4 | 5 | 6+ |
| --- | --- | --- | --- | --- | --- | --- |
| scale | 0.000 | 0.387 | 0.613 | 0.774 | 0.898 | 1.000 |

Resulting H:

| | count 1 | count 3 | count 6+ |
| --- | --- | --- | --- |
| low | 0.210 | 0.394 | 0.510 |
| medium | 0.420 | 0.604 | 0.720 |
| high | 0.700 | 0.884 | 1.000 |

**Range 0.21 to 1.00.** The 70/30 split keeps severity dominant: a single
high-severity pothole (0.700) still outranks a low-severity six-pack (0.510).

### 7.4 Credibility — will this survive review

```
C = clamp( (0.42 x modelConf + 0.33 x trust + 0.25 x corro) x photoMult, 0.15, 1.0 )
photoMult = imageUrl empty ? 0.5 : 1.0
```

**modelConf** = `0.5 x max(confidences) + 0.5 x mean(confidences)`, defaulting to
0.5 when `detections` is empty (legacy documents). Half-max because for danger
the single worst detection matters; half-mean because one lucky box on an
otherwise weak frame should not read as certainty. Since the scanner thresholds
at 0.20 confidence (section 1.1), this spans about 0.20 to 0.95 in practice.

**trust** = `(approved + 2) / (approved + rejected + 3)`, a Beta(2,1) prior:

| history | 0/0 (new) | 0 up 1 down | 0 up 6 down | 5 up 0 down | 12 up 1 down |
| --- | --- | --- | --- | --- | --- |
| trust | 0.667 | 0.500 | 0.222 | 0.875 | 0.875 |

The prior is what makes this usable. A raw ratio is undefined at 0/0 and gives a
first-time reporter with one rejection a flat 0.0, burying them permanently.
Here one bad report costs 0.167 and it takes six to fall to 0.222.

**corro** = `1 - 0.55^n`, where n counts **distinct** reporter UIDs within 25 m:

| n witnesses | 0 | 1 | 2 | 3 | 4 |
| --- | --- | --- | --- | --- | --- |
| corro | 0.000 | 0.450 | 0.698 | 0.834 | 0.909 |

Saturating, because the second independent witness is strong confirmation and
the fifth adds almost nothing. Counting distinct UIDs is what stops one user
self-corroborating by submitting the same pothole ten times.

**Weights 0.42 / 0.33 / 0.25 are ordered by availability, not by strength.**
Confidence exists on every report; trust accrues over weeks; corroboration is
the strongest evidence per unit but is exactly 0 for most reports, since most
potholes are only ever reported once. Giving corroboration the top weight would
flatten the ranking for typical single reports.

**Range 0.15 to 1.00.** The floor binds only in the worst case: a no-photo
report at 0.20 confidence from a 0-up/6-down reporter computes to 0.087 and is
lifted to 0.15. The floor is deliberate, so the multiplicative core never hits
exactly zero and the aging term always has something to lift.

### 7.5 Exposure — how many drivers are affected

```
E = 0.40 + 0.60 x min(1, k / 5)      k = distinct reporters within 300 m
```

| k | 0 | 1 | 2 | 3 | 4 | 5+ |
| --- | --- | --- | --- | --- | --- | --- |
| E | 0.40 | 0.52 | 0.64 | 0.76 | 0.88 | 1.00 |

**Range 0.40 to 1.00 — only 2.5x, deliberately.** This is the weakest-evidence
factor: reporter density is a proxy for traffic, not a measurement. It modulates
the score without ever nullifying it, so an isolated pothole on a quiet road
still scores.

This is the factor most worth upgrading. Sections 2.2 and 2.3 already implement
road-snapped point-to-segment matching at 12 to 14 m tolerance. If requested
routes are logged, exposure becomes *how many real journeys pass within 14 m of
this point*, which is the quantity actually wanted here.

### 7.6 Aging — the starvation guard

```
A = (waitHours / 48) ^ 1.5      uncapped
```

| wait | 6h | 12h | 24h | 48h | 72h | 96h | 7d |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | 0.044 | 0.125 | 0.354 | 1.000 | 1.837 | 2.828 | 6.548 |

The exponent is the tuning choice that matters. Linear (1.0) is too weak to
overcome the urgency term in a useful window. Quadratic (2.0) flips the queue to
near-FIFO as soon as a backlog builds, discarding the risk ranking. At 1.5,
sub-SLA items stay ordered by risk (at 24 h aging contributes only 0.354) while
post-SLA items accelerate hard (at 96 h it contributes 2.828, dominating
everything).

### 7.7 Composition and range

```
U     = H x C x E
score = 100 x (0.75 x U + 0.25 x A)

max U = 1.00 x 1.00 x 1.00 = 1.0000  ->  75.0 points
min U = 0.21 x 0.15 x 0.40 = 0.0126  ->   0.9 points
```

**Realistic scores land in roughly 2 to 50, not 0 to 100.** A perfect report
scores 75; a strong real case scores about 48 (example A below). Treat the band
thresholds as starting values and recalibrate on the real distribution.

### 7.8 Worked examples

**A. Corroborated high severity, trusted reporter, 5 h old.**
3 potholes, confidences [0.88, 0.71, 0.63], reporter 12 up / 1 down, 2 witnesses
within 25 m, 4 reporters within 300 m, photo present.

```
H  = 0.70 x 1.0 + 0.30 x 0.613                 = 0.8840
     modelConf = 0.5 x 0.88 + 0.5 x 0.740      = 0.8100
     trust     = (12+2) / (12+1+3) = 14/16     = 0.8750
     corro     = 1 - 0.55^2                    = 0.6975
C  = 0.42 x 0.810 + 0.33 x 0.875 + 0.25 x 0.6975 = 0.8033
E  = 0.40 + 0.60 x (4/5)                       = 0.8800
U  = 0.8840 x 0.8033 x 0.8800                  = 0.6249
A  = (5/48) ^ 1.5                              = 0.0336
score = 100 x (0.75 x 0.6249 + 0.25 x 0.0336)  = 47.7   -> Critical
```

**B. Thin single report, 30 h old.**
Medium severity, 1 pothole, confidence [0.55], brand-new reporter, no witnesses,
1 reporter within 300 m, photo present.

```
H  = 0.70 x 0.6 + 0                            = 0.4200
C  = 0.42 x 0.55 + 0.33 x 0.667 + 0            = 0.4510
E  = 0.40 + 0.60 x (1/5)                       = 0.5200
U  = 0.4200 x 0.4510 x 0.5200                  = 0.0985
A  = (30/48) ^ 1.5                             = 0.4941
score = 100 x (0.07387 + 0.12353)              = 19.7   -> Normal
```

12.4 of B's 19.7 points come from aging (63 percent). On a report this thin, age
is the reason to look at it.

**C. Probable junk, 3 h old.**
Low severity, 1 pothole, confidence [0.24], reporter 0 up / 6 down, no
witnesses, nothing within 300 m, no photo.

```
H  = 0.70 x 0.3 + 0                            = 0.2100
C  = (0.42 x 0.24 + 0.33 x 0.222) x 0.5 = 0.0871 -> floored 0.1500
E  = 0.40 + 0                                  = 0.4000
U  = 0.2100 x 0.1500 x 0.4000                  = 0.0126
A  = (3/48) ^ 1.5                              = 0.0156
score = 100 x (0.00945 + 0.00391)              =  1.3   -> Low
```

A and C separate by about 35x, which is the spread a triage score should
produce.

### 7.9 Bands and the hard override

| Band | Condition |
| --- | --- |
| Critical | `overallSeverity == high` AND at least 2 distinct witnesses within 25 m, OR score >= 45 |
| High | score >= 28 |
| Normal | score >= 12 |
| Low | below 12 |

The hard override exists because a corroborated high-severity hazard must never
be blurred into the middle of the queue by a weighted average. It is the one
combination that cannot be allowed to average out.

### 7.10 Starvation crossover times

Setting a zero-urgency item's score equal to a threshold T and solving for wait:

```
0.945 + 25 x (w/48)^1.5 = T   =>   w = 48 x ((T - 0.945) / 25)^(2/3)
```

- Junk reaches the **Critical** band (T=45) at `w = 48 x 1.762^0.667` = **70 h, about 2.9 days**.
- Junk outranks a **perfect fresh** report (T=75) at `w = 48 x 2.962^0.667` = **99 h, about 4.1 days**.

So nothing sits in the queue past about 3 days without surfacing, and past about
4 days it beats everything. The relation is `w proportional to (1/agingWeight)^(2/3)`,
so raising `agingWeight` from 0.25 to 0.35 pulls the 2.9-day figure down to
about 2.3 days.

### 7.11 Duplicate detection

Pending reports within 25 m of each other are very likely the same physical
pothole. Each ranked result carries `duplicateIds`, and the review card shows an
"N DUPLICATES" pill, so an admin can see that four queue entries are one
decision rather than four.

### 7.12 Complexity

Scoring is two passes over the collection:

1. Tally reporter approve/reject history and bucket every non-rejected report
   into a spatial grid.
2. Score each pending report, scanning only the 3x3 grid block around it.

The grid cell is 0.003 degrees latitude (about 332 m), chosen to be at least the
300 m exposure radius so a 3x3 scan is exhaustive. Longitude cell width is
divided by `cos(latitude)` (floored at 0.15) so cells stay at least 300 m wide
away from the equator. This makes the neighbour scan effectively O(n) instead of
the O(n^2) a naive all-pairs comparison would cost.

Distance uses the same local-plane approximation as section 2.3
(`metersPerDegLat = 110540`, `metersPerDegLon = 111320 x cos(latitude)`), with
the cosine taken at the midpoint latitude of the pair.

The score is computed once per dashboard build, not inside the sort comparator.
Recomputing inside the comparator would make sorting O(n^2 log n).

### 7.13 Limits and tuning

- **Exposure is a proxy**, not measured traffic. See 7.5 for the upgrade path.
- **Trust needs history to be meaningful.** Until reporters accumulate decisions
  everyone sits near the 0.667 prior, so early on the ranking is driven mostly
  by severity, confidence and age.
- **Band thresholds are provisional.** Recalibrate after observing a week of
  real scores; the constants live at the top of `ApprovalPriority`.
- **Ordering is display only.** The score is computed on the client and must
  never become an authorization input. Approval still goes through
  `CloudService.updatePotholeStatus`, which enforces admin role server-side.

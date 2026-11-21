# tools/generate_report.py
# -*- coding: utf-8 -*-
import os

def generate_report():
    out_path = os.path.join("docs", "thesis", "questionnaire_evaluation_report.md")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("""# Comprehensive Evaluation Report: RoadSense AI Thesis Research Instrument & System Alignment

**Study Title:** Visualizing Road Hazards: A YOLOv8-Powered Geospatial Mapping System for Pothole Navigation  
**Authors:** Aries S. Contado, Jenard Phil Tabudlo  
**Degree Program:** Bachelor of Science in Computer Science  
**Institution:** Immaculate Conception I-College of Arts and Technology (ICI-CAT), Sta. Maria, Bulacan  
**Adviser:** Mr. Emmanuel Sagayno | **Panel Chair:** Dr. Jovy Jay D. Cabrera  
**Target Locale:** Municipality of Santa Maria, Bulacan  
**Date of Assessment:** November 14, 2026  
**Document Evaluated:** `Questionnaire.docx` (Current 75-item draft located at `C:\\Users\\jenar\\Downloads\\Questionnaire.docx`)  
**Manuscript Evaluated:** `Thesis-Docu ReDef daw.docx` (Chapters 1 & 2 draft located at `C:\\Users\\jenar\\Downloads\\Thesis-Docu ReDef daw.docx`)  
**Repository & Codebase:** RoadSense AI Flutter Application (`lib/`, `assets/`, `test/`)  

---

## 1. Executive Summary & Overall Verdict

### Concise Overall Verdict: **SUBSTANTIALLY MISALIGNED**

The evaluated research instrument (`Questionnaire.docx`, containing 75 items across 14 statement-of-the-problem sections) cannot be administered in its current state for the academic defense and empirical evaluation of the RoadSense AI thesis. While several individual questions address genuine mobile features, the overall instrument suffers from fundamental methodological flaws, construct confusions, role mismatches, and platform omissions.

### Core Evidentiary Findings

1. **Methodological Category Mistake in SOP 2 (Model Performance):**
   * Items 21–25 ask human survey respondents to rate on a 5-point Likert scale whether the YOLOv8 model achieves *Precision, Recall, F1 Score, Mean Average Precision (mAP), and Severity Classification*.
   * In computer science and computer vision research, Precision ($TP / (TP + FP)$), Recall ($TP / (TP + FN)$), F1-Score ($2PR / (P + R)$), and mAP@0.50 are **objective mathematical metrics calculated from an annotated ground-truth test dataset**, not subjective human opinions.
   * Furthermore, Item 23 contains a severe conceptual error: it defines "F1 Score" as *"The system classifies hazard severity levels (low, medium, high) based on detected surface area."* F1-score is the harmonic mean of precision and recall, having nothing to do with surface-area tiering.
   * Crucially, the RoadSense AI project **already has the empirical ground-truth test metrics calculated** in `assets/thesis_results/thesis_test_metrics.csv` (Overall: Precision 0.6438, Recall 0.4697, F1 0.5395, mAP@0.50 0.4696 across 7,454 ground-truth instances). Subjecting these mathematical metrics to a subjective opinion poll invalidates the scientific rigor of Chapter 4.

2. **Instrument Purpose & Form Incoherence:**
   * The file header and instructions are written as an **Expert Content Validation Form**: *"Please carefully review each question provided and indicate your degree of agreement or disagreement regarding its alignment with the stated Statement of Problems. Your evaluation will directly inform the refinement or retention of each question within the instrument..."*
   * The response scale in the header is: *5 = The question demonstrates excellent alignment and is highly appropriate*, down to *1 = The question is not aligned and should be excluded*, ending with a *"Validator Name and Signature"* block.
   * However, the items inside the table are phrased as a hybrid of end-user experience queries (*"The app takes photos of road hazards directly inside the camera screen"*) and internal technical audit statements (*"Generated JSON data packets align directly with Firebase database schema specifications"*).
   * Handing this document to a motorist or an LGU official would result in total confusion: the instructions ask them to evaluate the *survey questions' alignment to thesis SOPs*, while the scale forces them to rate the *software features*.

3. **Unobservable "White-Box" Items Posed to Lay Motorists:**
   * In the ISO/IEC 25010 sections (SOP 4.2, 4.3, 4.5, 4.6, 4.7), respondents are asked to score properties completely invisible to a vehicle driver:
     * Item 37: *"The system synchronizes data using structured JSON packets to control network bandwidth consumption."*
     * Item 45: *"Generated JSON data packets align directly with Firebase database schema specifications."*
     * Item 56: *"Continuous location tracking data for proximity alerting is processed locally on the client device without cloud streaming."*
     * Item 57: *"Data exchanged between the application and cloud database is encrypted in transit."*
     * Item 60: *"The database rules are configured to prevent unauthorized users from tampering with or deleting verified hazard reports."*
     * Items 61–65 (Maintainability): *"Separation of local edge processing and cloud database allows independent debugging," "YOLOv8 model can be updated independently of core application codebase,"* and *"Codebase follows modular programming conventions."*
   * An end-user driver cannot observe database schemas, encryption handshakes, or edge-vs-cloud debugging. If forced to rate them, respondents will guess or default to "Neutral" (3) or "Strongly Agree" (5), generating fabricated data.

4. **Complete Omission of the Web Application and Admin/LGU Platform:**
   * The thesis manuscript specifically defines two respondent groups in Chapter 2: **50 End Users (motorists/commuters)** and **10 Admin respondents (IT professionals and Local Government Unit representatives)**. The manuscript explicitly highlights the Administrative Dashboard for municipal maintenance planning.
   * However, `Questionnaire.docx` contains **zero questions regarding the Web App or Admin Dashboard**. The DPWH Statutory Priority Triage Engine (`lib/approval_priority.dart`), the Review Queue, the 24-Barangay Insights and 30-Day Forecast Panel (`lib/lgu_forecast.dart`), the GIS Admin Map, the Trash Bin restoration, and the CSV Export are completely absent from the questionnaire. LGU respondents are given nothing relevant to evaluate.

5. **Phantom Feature Inclusion (Item 58 - PII Blurring):**
   * Item 58 asserts: *"Image processing routines crop or blur personally identifiable information (e.g., license plates, faces) prior to upload."*
   * Codebase inspection of `lib/main.dart`, `lib/map_screen.dart`, and `lib/cloud_service.dart` confirms that **no face or license plate blurring algorithm is implemented in the image pipeline**. The camera captures standard photos, performs 896px letterboxing for YOLOv8 inference, and uploads the raw image to Firebase Storage. Asking respondents to rate a non-existent feature exposes the research to immediate invalidation during oral defense.

6. **Model Class Scope Discrepancy:**
   * The questionnaire repeatedly refers only to *"potholes"*, whereas the actual trained Package 6 model (`assets/dpwh_thesis_package6/` and `docs/model-alignment-2026-10-29.md`) detects and classifies **four distinct DPWH road distress categories**:
     1. Bowl-shaped depression / Pothole (DPWH Code 01)
     2. Alligator crack (DPWH Code 02)
     3. Longitudinal crack (DPWH Code 12)
     4. Transverse crack (DPWH Code 12)
   * The questionnaire completely ignores crack detection in user-facing items, misrepresenting the true functional capability of the system.

7. **Severe Overlap and Redundancy:**
   * SOP 4.9 (Safety) almost completely duplicates SOP 1.4 (Proximity Alerting) and SOP 4.4 (Usability). Items 71, 72, and 73 are virtually identical to Items 16, 17, and 18.
   * Asking respondents the same question three times in different sections causes survey fatigue, response acquiescence, and inflated artificial reliability.

---

## 2. Research Materials & Context Verification

### 2.1 File Identification & Version Status
* **Current Questionnaire:** `C:\\Users\\jenar\\Downloads\\Questionnaire.docx` (75 items). This is the latest and only standalone survey document provided.
* **Current Thesis Manuscript:** `C:\\Users\\jenar\\Downloads\\Thesis-Docu ReDef daw.docx` (and `.docx.pdf`, 276 paragraphs covering Chapters 1 and 2).
* **Workspace Documentation:** Key architectural and technical reports in `docs/` (`docs/model-alignment-2026-10-29.md`, `docs/live-scanner-2026-11-13.md`, `docs/live-capture-consistency-2026-11-13.md`, `docs/detection-preprocessing-2026-11-13.md`), `SYSTEM_OVERVIEW.md`, `CALCULATION_DOCUMENTATION.md`, and `DPWH_TRIAGE_ALGORITHM_DOCUMENTATION.md`.

### 2.2 Alignment Between Manuscript SOPs and Research Instrument

| Thesis SOP (Manuscript) | Questionnaire Coverage | Status & Evidence-Based Assessment |
| :--- | :--- | :--- |
| **SOP 1.1: Data Preprocessing** | Items 1–5 | **Partly Aligned:** Focuses on camera photo capture; confuses internal letterboxing with manual user editing; vibration claims exceed software control. |
| **SOP 1.2: Edge-to-Cloud Sync** | Items 6–10 | **Partly Aligned:** Captures upload and offline queueing, but Item 6 misdescribes workflow (upload is manual confirmation, not instant on photo snap). |
| **SOP 1.3: Geospatial Mapping** | Items 11–15 | **Partly Aligned:** Captures map markers and colors; Item 11 uses absolute "exact location"; Item 15 asks unobservable battery drain. |
| **SOP 1.4: Proximity Alerting** | Items 16–20 | **Aligned with Minor Revisions:** Covers TTS audio and visual alerts; distance threshold in Item 18 (20–50m) conflicts with 20m code/manuscript threshold. |
| **SOP 2: YOLOv8 Accuracy (P, R, F1, mAP, Severity)** | Items 21–25 | **METHODOLOGICALLY INVALID:** Survey questions cannot measure mathematical computer vision metrics. F1 is misdefined. Must be moved to Chapter 4 Experimental Results. |
| **SOP 3: SDG 11 Target 11.2 Contribution** | Items 26–30 | **Aligned:** Evaluates perceived safety, road equity, accessibility for motorcyclists/tricyclists, and community impact. |
| **SOP 4.1: Functional Suitability** | Items 31–35 | **Partly Aligned:** Evaluates core feature execution; overlaps heavily with SOP 1. |
| **SOP 4.2: Performance Efficiency** | Items 36–40 | **Partly Aligned:** Items 37 (JSON packets) and 40 (multitasking consistency) are unobservable to users. Latency should be measured empirically. |
| **SOP 4.3: Compatibility** | Items 41–45 | **Substantially Misaligned:** Items 42 and 45 evaluate Firebase/OSM architecture and JSON schema alignment, which are unobservable to end-users. |
| **SOP 4.4: Usability** | Items 46–50 | **Aligned:** Standard UI/UX, color schemes, error handling, and simple reporting workflow. |
| **SOP 4.5: Reliability** | Items 51–55 | **Partly Aligned:** Covers crash-free operation, offline recovery, and system interrupts; Item 52 has a grammatical typo; Item 55 has a numbering error ("5. 5."). |
| **SOP 4.6: Security** | Items 56–60 | **Substantially Misaligned:** Items 56, 57, and 60 are white-box security audits (TLS encryption, Firestore rules). Item 58 evaluates a non-existent PII blurring feature. |
| **SOP 4.7: Maintainability** | Items 61–65 | **MISPLACED / UNOBSERVABLE:** All 5 items rate source code modularity, model decoupling, and database schema flexibility. Cannot be judged by drivers or general users. |
| **SOP 4.8: Portability** | Items 66–70 | **Partly Aligned:** Covers multi-device Android APK installation, network switching, and screen orientation changes. |
| **SOP 4.9: Safety** | Items 71–75 | **REDUNDANT:** Re-asks SOP 1.4 Items 16–18 and ISO 4.4 Usability items. Adds no distinct construct. |

---

## 3. RoadSense AI System Capability Inventory

The inventory below reflects the **actual implementation** determined by codebase inspection and test verification across `lib/`, `assets/`, `firestore.rules`, and automated test suites (85 passing unit/widget tests in `flutter test`).

| # | Capability Area | Platform | Intended User Role | Primary Source Files & Backend Rules | Status | Verification Method | Limitations Affecting Questionnaire Wording |
| :---: | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **User Registration & Login** | Mobile & Web | General Public, Admin | `lib/auth_screen.dart`, `lib/verified_auth_gate.dart`, Firebase Auth | Implemented | Source inspection & Widget tests (`ui_audit_test.dart`) | Email/password auth supported. Google Sign-In button is UI-only/secondary. |
| **2** | **Email Verification (6-Digit OTP)** | Mobile & Web | All Users | `lib/email_verification_view.dart`, `lib/email_verification_client.dart` | Implemented | Automated tests (`email_verification_test.dart`) | Uses 6-digit OTP code, not legacy email link confirmation. |
| **3** | **Role-Based Access Control** | Mobile, Web, Cloud | User, Admin, Super Admin | `firestore.rules`, `lib/cloud_service.dart`, `lib/admin_users_settings_view.dart` | Implemented | Security rule analysis & Firestore tests | Verified email is required for write/admin operations. Super Admin manages roles. |
| **4** | **Live Road-Defect Scanning** | Mobile | Motorists, Commuters | `lib/main.dart`, `lib/map_screen.dart`, `lib/live_detection_snapshot.dart` | Implemented | On-device field tests (`TECNO LH7n`) & regression tests | Runs YOLOv8 TFLite with GPU/CPU fallback. Preprocesses to 896x896 letterbox with RGB 114 padding. |
| **5** | **Still Camera Capture & Gallery** | Mobile | Motorists | `lib/main.dart`, `lib/map_screen.dart` | Implemented | Source inspection & automated tests | Dual-pass inference (full-frame + center-detail). Gallery analysis uses the same pipeline. |
| **6** | **Supported Defect Classes** | Mobile & Web | All Roles | `assets/labels.txt`, `assets/dpwh_metadata.json`, `docs/model-alignment-2026-10-29.md` | Implemented (4 Classes) | Model alignment tests (`model_alignment_test.dart`) | **Strictly 4 trained classes:** Pothole (01), Alligator crack (02), Longitudinal crack (12), Transverse crack (12). Slot 2 Depression is untrained and discarded. |
| **7** | **Detection Review & Submission** | Mobile | Motorists | `lib/map_screen.dart`, `lib/cloud_service.dart` | Implemented | Widget tests & manual inspection | Users review bounding boxes and confirm severity before upload; it is **not** an instantaneous background upload. |
| **8** | **Location Tracking & GPS Display** | Mobile & Web | Motorists, Public | `lib/map_screen.dart`, `lib/web_map_screen.dart`, `Geolocator` | Implemented | Field drive tests & integration tests | Uses standard smartphone GPS sensor (3–10m typical variance). OpenStreetMap tiles via `flutter_map`. |
| **9** | **Search, Filters & Clustering** | Mobile & Web | All Roles | `lib/web_map_side_panel.dart`, `lib/map_screen.dart`, Nominatim API | Implemented | Widget tests (`web_redesign_test.dart`) | Filters by DPWH defect class, status (approved, pending), and severity (low, medium, high). 24 Santa Maria barangay bounds. |
| **10** | **Route Planning & Proximity Alert** | Mobile | Motorists | `lib/map_screen.dart`, `lib/pothole_notifier.dart`, OpenRouteService | Implemented | Integration tests & field runs | OpenRouteService with `avoid_polygons` hazard avoidance. Master Control Button (Road 1, Road 2, Smart Route). TTS audio alert at **20–22 meters**. |
| **11** | **User Report Management** | Mobile & Web | General Users | `lib/profile_screen.dart`, `lib/web_profile_screen.dart`, `lib/web_components.dart` | Implemented | Widget tests (`web_redesign_test.dart`) | Users can view submission history, filter own reports, and edit/cancel their own **pending** reports only. |
| **12** | **Admin Review Queue & Triage** | Web | LGU / DPWH Admins | `lib/admin_dashboard_screen.dart`, `lib/admin_review_queue_view.dart`, `lib/approval_priority.dart` | Implemented | Unit & widget tests (`admin_dashboard_test.dart`) | Automated 4-pillar DPWH statutory triage priority scoring (Harm, Credibility, Exposure, SLA Aging). SLA breach flagging. Approve/Reject workflows. |
| **13** | **Barangay Insights & Forecast** | Web | LGU Engineers | `lib/admin_barangay_insights_view.dart`, `lib/lgu_forecast.dart`, `lib/admin_forecast_metrics.dart` | Implemented | Unit tests (`lgu_forecast_test.dart`) | Deterministic weighted least squares linear trend across 8 weeks with PAGASA wet-season multiplier and 332m spatial hotspot grid. |
| **14** | **Admin Trash & Restoration** | Web | Admins | `lib/admin_trash_view.dart`, `lib/cloud_service.dart` | Implemented | Unit tests (`admin_dashboard_test.dart`) | Soft-delete to Trash bin; full restore capability to prevent accidental data loss. |
| **15** | **LGU CSV Export** | Web | LGU Engineers | `lib/admin_overview_view.dart`, `lib/admin_shared_widgets.dart` | Implemented | Unit tests (`admin_dashboard_test.dart`) | Neutralizes spreadsheet formula injection triggers (`=`, `+`, `-`, `@`); masks reporter emails for PII compliance. |
| **16** | **Offline Queue & Resilient Sync** | Mobile | Motorists | `lib/pending_report_queue.dart`, `lib/database_helper.dart` | Implemented | Unit tests (`pending_report_queue_test.dart`) | Local SQLite queue stores pending submissions during network disconnects and retries upload upon reconnection. |
| **17** | **Automated PII Blurring** | Mobile | Motorists | N/A (Image capture pipeline) | **MISSING** | Codebase search & image pipeline audit | **Does not exist.** Photos are not blurred for faces or license plates before cloud upload. |
| **18** | **Accessibility & Onboarding** | Mobile & Web | All Users | `lib/onboarding_screen.dart`, `lib/mobile_tour.dart`, `lib/app_design.dart` | Implemented | UI audit tests (`ui_audit_test.dart`) | Supports dark/light mode, high-contrast text, 2x text size scaling, and interactive first-launch tour. |

---

## 4. Methodological Framework Analysis: ISO/IEC 25010

### 4.1 ISO/IEC 25010:2011 vs. ISO/IEC 25010:2023
The manuscript and questionnaire cite the **ISO/IEC 25010 Software Quality Model**.
* **ISO/IEC 25010:2011** defines eight product quality characteristics:
  1. *Functional Suitability* (Functional completeness, correctness, appropriateness)
  2. *Performance Efficiency* (Time behavior, resource utilization, capacity)
  3. *Compatibility* (Co-existence, interoperability)
  4. *Usability* (Appropriateness recognizability, learnability, operability, user error protection, user interface aesthetics, accessibility)
  5. *Reliability* (Maturity, availability, fault tolerance, recoverability)
  6. *Security* (Confidentiality, integrity, non-repudiation, accountability, authenticity)
  7. *Maintainability* (Modularity, reusability, analysability, modifiability, testability)
  8. *Portability* (Adaptability, installability, replaceability)
  * In the 2011 edition, **Safety** is NOT a product quality characteristic; it is a sub-characteristic of *Freedom from Risk* under the separate **Quality in Use Model** (Clause 4.3.2).
* **ISO/IEC 25010:2023** (revised in 2023 as *Systems and software Quality Requirements and Evaluation - Product Quality Model*) officially added **Safety** as the 9th Product Quality characteristic (defined as the degree to which software under specified conditions does not lead to a state in which human life, health, property, or environment is endangered).
* **Crucial Implication:** If the researchers evaluate 9 characteristics including Safety, they are referencing **ISO/IEC 25010:2023**. The manuscript should explicitly cite the 2023 revision.

### 4.2 Standardized Instrument Preservation vs. Custom Adaptation
* ISO/IEC 25010 provides a **conceptual quality model and taxonomy**, not a fixed, validated survey questionnaire like the System Usability Scale (SUS) or Technology Acceptance Model (TAM).
* Researchers commonly write custom Likert items mapping to the ISO characteristics. However:
  1. The custom questionnaire must **never claim to be a validated standardized instrument** without documented expert content validation and psychometric pilot testing.
  2. Characteristics such as **Maintainability, Security internals, and Compatibility packet schemas cannot be evaluated by end users**. They must be evaluated exclusively by IT experts or through empirical benchmarking.

---

## 5. Complete Item-by-Item Alignment Matrix (All 75 Items)

The table below evaluates every single item from `C:\\Users\\jenar\\Downloads\\Questionnaire.docx` against the implemented system, research objectives, observability criteria, and respondent roles.

| # | Original Wording | Intended Construct | Related SOP | Relevant Feature / Platform | Intended Respondent | Source Evidence | Alignment Judgment | Identified Problem | Recommended Action | Proposed Wording / Resolution |
| :---: | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **01** | The app takes photos of road hazards directly inside the camera screen. | Data Preprocessing / Photo Capture | SOP 1.1 | In-app Camera / Mobile | Motorists | `lib/main.dart:2170` | Partly Aligned | Trivial binary statement. Taking a photo is user input, not data preprocessing. | Revise | The camera interface makes it easy to capture road hazards directly within the application. |
| **02** | The app automatically resizes or crops the photo without requiring me to edit it manually. | Data Preprocessing / Image Formatting | SOP 1.1 | Letterbox Preprocessing / Mobile | Motorists | `docs/detection-preprocessing-2026-11-13.md` | Partly Aligned | Unobservable internal preprocessing (896x896 letterboxing). Users only observe that manual cropping is unnecessary. | Revise | The application automatically prepares captured road photos for analysis without requiring manual editing or cropping. |
| **03** | The photo remains clear even when taken from inside a moving or vibrating vehicle. | Image Acquisition Robustness | SOP 1.1 | In-vehicle Camera / Mobile | Motorists | Field drive tests | Misaligned | Software cannot alter vehicle vibration physics or optical camera blur. Uses absolute wording ("remains clear"). | Revise / Test Technically | The camera capture workflow is easy to operate while mounted inside a moving vehicle. *(Evaluate vibration blur technically).* |
| **04** | The camera captures clear images under different lighting (like bright sunlight or shadows). | Environmental Usability | SOP 1.1 | In-app Camera / Mobile | Motorists | `Thesis-Docu ReDef daw.docx` Scope | Partly Aligned | Mixed hardware dependency (camera sensor auto-exposure) and perception. | Revise | The camera capture functions effectively under typical daylight conditions, including bright sunlight and shaded road sections. |
| **05** | The camera feature runs smoothly without freezing or crashing my phone. | Perceived Stability / Performance | SOP 1.1 | Camera Stream / Mobile | Motorists | `docs/live-scanner-2026-11-13.md` | Partly Aligned | Belongs to Reliability / Usability rather than Preprocessing. Double-barreled ("freezing or crashing"). | Revise | The camera and scanning interface operate smoothly without noticeable stuttering or freezing. |
| **06** | The app uploads my pothole report to the map database right after I take the photo. | Synchronization Immediacy | SOP 1.2 | Report Review & Upload / Mobile | Motorists | `lib/map_screen.dart:4500` | Misaligned | **Factual error in workflow:** App does NOT auto-upload immediately; user reviews bounding boxes and taps Submit Report. | Revise | The application promptly uploads my road hazard report once I confirm and submit it. |
| **07** | Reports and photos upload smoothly without long loading screens or app delays. | Perceived Upload Speed | SOP 1.2 | Cloud Service / Mobile | Motorists | `lib/cloud_service.dart` | Aligned | Double-barreled ("long loading screens or app delays") and negative wording. | Revise | Hazard reports and photos upload within an acceptable timeframe without causing long delays. |
| **08** | Sending reports does not use an excessive amount of my mobile data. | Resource Utilization Perception | SOP 1.2 | Network Upload / Mobile | Motorists | Firebase Storage upload | Unobservable | End-users cannot gauge byte consumption during a road test without specialized network monitoring. | Move to Technical Testing | **Evaluate through technical testing:** Measure payload size (~250 KB compressed image + 1.5 KB JSON) vs cellular limits. |
| **09** | If internet connection drops, the app saves my report offline and sends it automatically when connected. | Offline Resiliency & Recoverability | SOP 1.2 | SQLite Queue / Mobile | Motorists | `lib/pending_report_queue.dart` | Aligned (Conditional) | Excellent feature alignment, but observable ONLY if the test script includes an offline simulation task. | Keep with Task Script | If network connectivity is lost, the application reliably saves reports offline and synchronizes them when reconnected. |
| **10** | The app displays a confirmation message on screen once my report is successfully sent. | System Feedback / User Guidance | SOP 1.2 | Submission SnackBar / Mobile | Motorists | `lib/map_screen.dart:4650` | Aligned | Clear, observable, and directly implemented. | Keep | The application displays a clear confirmation notice on screen once my report has been successfully submitted. |
| **11** | The app places warning pins on the map at the exact real-life location of the pothole. | Geospatial Accuracy | SOP 1.3 | Map Pins / Mobile & Web | Motorists, Public | GPS Sensor + `flutter_map` | Partly Aligned | Absolute wording ("exact real-life location"). Consumer GPS has 3–10m standard variance. | Revise | The map markers accurately reflect the real-world locations of reported road hazards. *(Compute MAE in Chapter 4).* |
| **12** | The map is easy to move, zoom in/out, and follow while traveling. | Map Usability | SOP 1.3 | Interactive Map / Mobile & Web | Motorists, Public | `flutter_map` implementation | Partly Aligned | Multi-barreled statement (pan, zoom, follow). | Revise | The interactive map is easy to pan, zoom, and follow during travel. |
| **13** | The map uses different pin colors to clearly show how severe each pothole is. | Information Clarity / Visual Design | SOP 1.3 | Severity Markers / Mobile & Web | Motorists, Public | `lib/web_hazard_marker.dart` | Aligned | Clear and implemented (Red=High, Orange=Med, Yellow=Low). Should refer to all road hazards, not only potholes. | Revise | The map uses distinct marker colors to clearly indicate the severity level of each reported road hazard. |
| **14** | The map updates to display pothole reports submitted by other users in the community. | Crowdsourced Sync Perception | SOP 1.3 | Real-time Firestore Stream | Motorists, Public | Firestore snapshots | Aligned (Conditional) | Observable if test script includes viewing seeded community reports. | Revise | The map displays verified road hazard reports submitted by other community users. |
| **15** | Using the map and location tracking does not drain my phone battery unusually fast. | Battery Efficiency Perception | SOP 1.3 | Location Stream / Mobile | Motorists | Background location | Unobservable | Cannot be evaluated in a 15-minute user test. Requires multi-hour battery profiling. | Move to Technical Testing | **Evaluate through technical testing:** Profile battery drain (% per hour) during active navigation. |
| **16** | The app plays a spoken voice warning out loud when I approach a reported pothole. | Auditory Proximity Alert | SOP 1.4 | TTS Engine / Mobile | Motorists | `lib/pothole_notifier.dart` | Aligned | Core salient feature. Directly observable during drive-testing. | Revise | The application plays a clear spoken voice alert (Text-to-Speech) when approaching a reported road hazard. |
| **17** | The visual warning box on the screen pops up without blocking the main navigation map and distracting me from driving. | Visual Alert Usability & Safety | SOP 1.4 | Alert Card Banner / Mobile | Motorists | `lib/map_screen.dart:7500` | Partly Aligned | Double-barreled ("without blocking map and distracting from driving"). | Revise | The on-screen visual warning appears clearly without obstructing essential navigation information. |
| **18** | Warnings sound early enough (about 20 to 50 meters before the pothole) so I have time to react. | Alert Timeliness | SOP 1.4 | Geofence Proximity / Mobile | Motorists | `lib/map_screen.dart` (22m threshold) | Partly Aligned | Distance claim ("20 to 50 meters") contradicts the system specification (20–22 meters) and is hard for drivers to estimate. | Revise | Proximity warnings are delivered early enough to provide adequate time to react safely to upcoming road hazards. |
| **19** | Spoken voice alerts inform me of hazards without forcing me to tap or look down at the screen. | Hands-Free Safety | SOP 1.4 | TTS Audio / Mobile | Motorists | `lib/pothole_notifier.dart` | Aligned | Strong usability and safety construct. | Keep | Spoken voice alerts inform me of upcoming hazards without requiring me to tap or look down at the screen. |
| **20** | The app continues tracking my location in the background to send warnings while I drive without glitching. | Tracking Continuity | SOP 1.4 | Background GPS / Mobile | Motorists | Geolocator service | Partly Aligned | Informal slang ("without glitching"). Double-barreled. | Revise | The application consistently maintains location tracking to deliver proximity alerts throughout the entire drive. |
| **21** | Precision: The YOLOv8 model differentiates actual potholes from non-hazard surface features (e.g., shadows, wet spots, or flat stains). | Objective Algorithmic Precision | SOP 2 | YOLOv8 Model / Mobile | **INVALID** (Model Benchmark) | `assets/thesis_results/thesis_test_metrics.csv` | **Methodologically Invalid** | Subjective user opinion cannot establish Precision ($TP / (TP+FP) = 0.6438$). Belongs in Chapter 4 experimental results. | Move to Chapter 4 Results | **Evaluate via test dataset benchmark.** For user perception survey, revise to: *"The system rarely misidentifies shadows, wet spots, or harmless pavement markings as road hazards."* |
| **22** | Recall: The detection algorithm detects visible potholes present within the camera frame during image capture. | Objective Algorithmic Recall | SOP 2 | YOLOv8 Model / Mobile | **INVALID** (Model Benchmark) | `assets/thesis_results/thesis_test_metrics.csv` | **Methodologically Invalid** | Subjective user opinion cannot establish Recall ($TP / (TP+FN) = 0.4697$). | Move to Chapter 4 Results | **Evaluate via test dataset benchmark.** For user perception survey, revise to: *"The system reliably detects visible road hazards present in the camera frame."* |
| **23** | F1 Score: The system classifies hazard severity levels (low, medium, high) based on detected surface area. | Objective Algorithmic F1-Score | SOP 2 | Model & Severity / Mobile | **INVALID** (Model Benchmark) | F1 formula vs. Area calculation | **Methodologically Invalid & Factual Error** | Gross conceptual error: F1 is the harmonic mean of Precision and Recall, NOT surface area classification! | Move to Chapter 4 Results | **Evaluate F1 in Chapter 4.** For user perception survey, revise to: *"The assigned severity ratings (Low, Medium, High) reasonably reflect the actual severity of the road defect."* |
| **24** | Mean Average Precision (mAP): The YOLOv8 model retains its mAP performance across varying lighting conditions, vehicle vibrations, and camera angles during field deployment. | Objective Algorithmic mAP | SOP 2 | YOLOv8 Model / Mobile | **INVALID** (Model Benchmark) | `assets/thesis_results/thesis_test_metrics.csv` | **Methodologically Invalid** | No human respondent can compute mAP in their head during a survey. | Move to Chapter 4 Results | **Evaluate mAP experimentally in Chapter 4** ($mAP@0.50 = 0.4696$). Remove from survey. |
| **25** | Severity Classification: The system categorizes detected potholes into defined risk tiers (low, medium, high) based on the calculated pixel surface area relative to physical hazard severity | Pixel-to-Severity Heuristic | SOP 2 | Severity Rules / Mobile & Web | Evaluators / IT Experts | `lib/severity_rules.dart` | Partly Aligned | Evaluates severity calculation logic. Valid user perception construct if rephrased without technical jargon. | Revise | The system provides clear and understandable severity classifications (Low, Medium, High) for detected road hazards. |
| **26** | Real-time warnings help drivers avoid potholes and adjust their driving path safely. | Road Safety Enhancement | SOP 3 | Proximity Alerts / Mobile | Motorists | Field drive observations | Aligned | Directly addresses SDG 11 Target 11.2 (safe transport systems). | Revise | Real-time proximity warnings help drivers anticipate road hazards and adjust their driving path safely. |
| **27** | The app gives everyday commuters an easy way to report road hazards to help the community. | Civic Crowdsourcing | SOP 3 | Reporting Flow / Mobile & Web | Motorists, Commuters | Community submissions | Aligned | Directly addresses participatory road maintenance. | Keep | The application provides everyday commuters with an accessible way to report road hazards to benefit the community. |
| **28** | The hazard map provides clear location data that local government officials can use for road repairs. | Municipal Utility | SOP 3 | Spatial Map / Web & Mobile | LGU Officers, Admins | `lib/admin_map_view.dart` | Partly Aligned | Lay motorists cannot speak authoritatively for LGU repair teams. Best answered by LGU/Admin respondents. | Route to LGU / Admins | The geospatial hazard map provides actionable location data that can assist municipal engineers in prioritizing road repairs. |
| **29** | The navigation screen helps drivers select safer, smoother routes across Sta. Maria, Bulacan. | Route Safety Optimization | SOP 3 | ORS Smart Route / Mobile | Motorists | `avoid_polygons` ORS routing | Aligned | Addresses safe route selection in Sta. Maria. | Keep | The navigation feature assists drivers in selecting safer, smoother routes across Santa Maria, Bulacan. |
| **30** | The warnings are helpful for vulnerable drivers, such as motorcycle and tricycle riders. | Vulnerable Road User Equity | SOP 3 | TTS & Visual Alerts / Mobile | Motorists, Commuters | Locale demographics | Aligned | Key aspect of SDG Target 11.2 (accessible and safe transport for vulnerable users). | Keep | The hazard alerts are especially helpful for vulnerable road users, such as motorcycle and tricycle riders. |
| **31** | The application accurately captures road images and automatically processes them for analysis. | Functional Suitability (Completeness) | SOP 4.1 | Camera Capture / Mobile | Motorists, IT Experts | `lib/main.dart` | Partly Aligned | "Accurately" is leading and unmeasurable by lay users. | Revise | The application reliably captures road hazard images and prepares them for defect analysis. |
| **32** | The YOLOv8 model identifies potholes while filtering out non-hazard road surface anomalies. | Functional Suitability (Correctness) | SOP 4.1 | YOLOv8 TFLite / Mobile | Motorists, IT Experts | `lib/model_detections.dart` | Partly Aligned | Mentions only potholes; system detects 4 defect classes. | Revise | The system effectively identifies supported road defects while ignoring non-hazard road surface variations. |
| **33** | The system calculates and assigns pothole severity levels (low, medium, high) based on surface area analysis. | Functional Suitability (Appropriateness) | SOP 4.1 | Severity Rules / Mobile & Web | Motorists, IT Experts | `test/severity_rules_test.dart` | Partly Aligned | User cannot verify surface area algorithm; can only evaluate output appropriateness. | Revise | The system assigns appropriate hazard severity levels (Low, Medium, High) based on detected road defect dimensions. |
| **34** | The system extracts GPS coordinates and maps verified hazards at their physical location on the map. | Functional Suitability (Geocoding) | SOP 4.1 | Geotagging / Mobile & Web | Motorists, IT Experts | `lib/map_screen.dart` | Aligned | Directly observable functional capability. | Revise | The system accurately geotags submitted reports and displays hazard markers at their corresponding locations on the map. |
| **35** | The system outputs real-time auditory (TTS) and visual proximity notifications upon entering the geofenced zone. | Functional Suitability (Alert Output) | SOP 4.1 | Alerts / Mobile | Motorists | `lib/pothole_notifier.dart` | Overlapping | Duplicates SOP 1.4 Items 16 & 17 verbatim. | Remove / Consolidate | *(Consolidate into SOP 1.4 to eliminate survey redundancy).* |
| **36** | The AI model processes images and detects potholes in real-time without lag on the mobile device. | Performance Efficiency (Time Behavior) | SOP 4.2 | On-Device TFLite / Mobile | Motorists, IT Experts | `docs/live-scanner-2026-11-13.md` | Partly Aligned | "Without lag" is subjective and absolute. Latency should be measured empirically ($17.00\text{ ms}$ on T4, $\sim 85\text{ ms}$ on Helio G99). | Revise | The on-device defect detection operates with acceptable speed during real-time use. *(Report benchmark in Chapter 4).* |
| **37** | The system synchronizes data using structured JSON packets to control network bandwidth consumption. | Performance Efficiency (Resource Utilization) | SOP 4.2 | Network Protocol | **INVALID** (End Users) | Firestore payload structure | **Unobservable** | General users have no access to network inspection tools. | Move to IT Architecture Audit | **Evaluate via IT Expert Review or Network Profiling.** Remove from general user questionnaire. |
| **38** | The application executes background GPS tracking without triggering thermal throttling or rapid battery exhaustion. | Performance Efficiency (Resource Utilization) | SOP 4.2 | Background Location / Mobile | Motorists, IT Experts | Geolocator service | Partly Aligned | Technical jargon ("thermal throttling"); double-barreled. | Revise | The application operates without causing the mobile device to overheat or excessively deplete battery during navigation. |
| **39** | The OpenStreetMap interface initializes and renders hazard pins upon app launch. | Performance Efficiency (Startup Time) | SOP 4.2 | Map Initialization / Mobile & Web | Motorists, Public | `lib/web_map_screen.dart` | Partly Aligned | Trivial binary statement. Better focused on load time. | Revise | The interactive map interface and hazard markers load within an acceptable timeframe upon launch. |
| **40** | The system maintains a consistent processing speed even when multiple background tasks are running on the smartphone. | Performance Efficiency (Capacity) | SOP 4.2 | Runtime Concurrency / Mobile | IT Experts | Field test observations | Unobservable | Uncontrolled multi-app testing condition for general motorists. | Move to IT Stress Testing | **Evaluate via technical stress testing.** Remove from end-user survey. |
| **41** | The application interfaces directly with device hardware, including the camera, GPS sensors, and audio speakers for TTS. | Compatibility (Co-existence / Interoperability) | SOP 4.3 | Device Hardware / Mobile | Motorists, IT Experts | Android permission bindings | Aligned | Observable through hardware feature operation. | Revise | The application integrates seamlessly with the smartphone's camera, GPS location, and audio systems. |
| **42** | The application exchanges data with external cloud backend databases (Firebase) and mapping APIs (OpenStreetMap). | Compatibility (Interoperability) | SOP 4.3 | Cloud & API Interfaces | **INVALID** (End Users) | Firebase & OSM APIs | Partly Unobservable | End-users do not observe API handshakes; they only see sync results. | Move to IT Architecture Audit | For IT Experts: *"The application effectively integrates with external cloud databases (Firebase) and map tile providers (OpenStreetMap)."* |
| **43** | The application runs concurrently alongside other active Android system services and background apps. | Compatibility (Co-existence) | SOP 4.3 | Android OS Concurrency | Motorists, IT Experts | Android background service | Aligned | Observable if navigation runs alongside music or messaging apps. | Keep | The application runs reliably alongside other everyday mobile apps and system services without conflict. |
| **44** | The UI layout adapts to different Android screen sizes, aspect ratios, and display resolutions. | Compatibility (Adaptability) | SOP 4.3 | Responsive UI / Mobile & Web | All Respondents | `test/ui_audit_test.dart` | Aligned | Core responsive design construct verified across 375px, 812px, 1024px, 1440px. | Keep | The user interface displays cleanly across different screen sizes and display orientations without clipping or distortion. |
| **45** | Generated JSON data packets align directly with Firebase database schema specifications. | Compatibility (Data Interchange) | SOP 4.3 | Database Schema | **INVALID** (End Users) | `firestore.rules` validation | **Unobservable** | Pure database engineering audit item. Lay drivers cannot evaluate schema specs. | Remove from Survey | **Evaluate through automated schema validation tests.** Do not ask in any survey. |
| **46** | Navigation and menu controls follow standard mobile application UI/UX layouts for everyday drivers. | Usability (Appropriateness Recognizability) | SOP 4.4 | Navigation UI / Mobile & Web | Motorists, Commuters | `lib/mobile_components.dart` | Aligned | Standard usability heuristic. | Keep | Navigation and menu controls are intuitive and follow familiar layouts for everyday drivers. |
| **47** | Map markers use distinct visual color schemes to indicate hazard severity levels. | Usability (Aesthetics / Clarity) | SOP 4.4 | Map Pins / Mobile & Web | Motorists, Public | `lib/web_hazard_marker.dart` | Overlapping | Identical to SOP 1.3 Item 13. | Consolidate | *(Consolidate into SOP 1.3 to avoid double-asking).* |
| **48** | Hands-free auditory notifications inform drivers of upcoming road conditions along their route. | Usability (Operability) | SOP 4.4 | TTS Audio / Mobile | Motorists | `lib/pothole_notifier.dart` | Overlapping | Identical to SOP 1.4 Item 16 & 19. | Consolidate | *(Consolidate into SOP 1.4).* |
| **49** | The hazard reporting workflow consists of a defined single-action sequence (capture to upload). | Usability (Simplicity / Operability) | SOP 4.4 | Report Submission / Mobile | Motorists | `lib/map_screen.dart` | Partly Aligned | Uses technical jargon ("single-action sequence"). Workflow has 2–3 steps (snap, review, submit). | Revise | The process of capturing, reviewing, and submitting a road defect report is straightforward and easy to complete. |
| **50** | System error notifications are displayed when hardware or network services (e.g., GPS signal, mobile data) fail. | Usability (User Error Protection) | SOP 4.4 | Error Dialogs & SnackBar | Motorists, All Roles | `lib/mobile_components.dart` | Aligned | Observable error feedback construct. | Keep | The application provides clear error notifications when hardware or network connectivity issues occur. |
| **51** | The application operates without app crashes, or system freezes during extended field testing. | Reliability (Maturity / Stability) | SOP 4.5 | Stability / Mobile & Web | Motorists, Admins | Extended drive runs | Aligned | Punctuation typo in original (comma after "crashes"). Good construct. | Revise | The application operates reliably without unexpected crashes or system freezes during use. |
| **52** | The proximity alerts and edge AI detection independently of active internet connectivity. | Reliability (Fault Tolerance) | SOP 4.5 | Offline Inference & Alerts | Motorists | `lib/main.dart` | Broken Syntax | **Grammatically broken in original** (missing verb: "detection [operates] independently"). | Revise | The on-device hazard detection and proximity alerts function reliably even without an active internet connection. |
| **53** | Pending hazard reports store locally during network offline states and upload automatically upon connection recovery. | Reliability (Recoverability) | SOP 4.5 | SQLite Queue / Mobile | Motorists | `pending_report_queue.dart` | Overlapping | Duplicates SOP 1.2 Item 9. | Consolidate | *(Retain single robust item under Edge-to-Cloud Sync / Reliability).* |
| **54** | The application resumes previous state execution following system interrupts (e.g., incoming calls, notifications). | Reliability (Recoverability) | SOP 4.5 | App Lifecycle State | Motorists | Android lifecycle handlers | Aligned | Excellent resilience item. | Keep | The application resumes its previous state smoothly after interruptions such as incoming phone calls or notifications. |
| **55** | 5. 5. GPS tracking log’s location data within acceptable variance margins without coordinate jumping or severe mapping placement errors. | Reliability (Data Integrity) | SOP 4.5 | GPS Map Tracking | Motorists, IT Experts | Geolocator stream | Typo & Jargon | Original has typo ("5. 5. GPS tracking log's..."). "Variance margins" is technical jargon. | Revise | The GPS location tracking follows movement smoothly without erratic marker jumping or mapping errors. |
| **56** | Continuous location tracking data for proximity alerting is processed locally on the client device without cloud streaming. | Security (Privacy / Confidentiality) | SOP 4.6 | Local Geolocation / Mobile | **INVALID** (End Users) | `lib/pothole_notifier.dart` | **Unobservable** | Privacy claim cannot be verified by motorists looking at the screen. | Move to IT Architecture Audit | **Evaluate via IT Security Audit:** Verify that continuous background coordinates are kept in volatile memory and not streamed to cloud logs. |
| **57** | Data exchanged between the application and cloud database is encrypted in transit. | Security (Confidentiality & Integrity) | SOP 4.6 | Cloud Transport Security | **INVALID** (End Users) | Firebase HTTPS / TLS 1.3 | **Unobservable** | Motorists cannot inspect TLS certificates or encrypted network streams. | Move to IT Architecture Audit | **Evaluate via Technical Security Assessment:** Document Firebase REST TLS 1.3 encryption. |
| **58** | Image processing routines crop or blur personally identifiable information (e.g., license plates, faces) prior to upload. | Security & Privacy (PII Protection) | SOP 4.6 | Image Pipeline / Mobile | All Respondents | `lib/main.dart`, `lib/cloud_service.dart` | **FACTUAL MISMATCH (PHANTOM FEATURE)** | **Critical finding:** Feature is NOT implemented in code. Asking users to rate it will generate false data. | REMOVE / FLAG | **REMOVE FROM SURVEY.** Do not present to respondents until automated face/plate blurring is actually coded and verified. |
| **59** | Device permission requests are limited to functional necessities (Camera, Location) with displayed system justifications. | Security (Access Control / Transparency) | SOP 4.6 | Android Permissions | Motorists, All Roles | Android Manifest | Aligned | Directly observable when app prompts for Camera/Location permissions. | Keep | The application requests only necessary permissions (such as Camera and Location) with clear explanations. |
| **60** | The database rules are configured to prevent unauthorized users from tampering with or deleting verified hazard reports. | Security (Authorization & Integrity) | SOP 4.6 | Firestore Security Rules | **INVALID** (End Users) | `firestore.rules:45-80` | **Unobservable** | General users do not see database rule configurations or test authorization breaches. | Move to IT Security Testing | **Evaluate via automated Strix/Firebase rule unit tests** (`test/firebase_workflows.cjs`). |
| **61** | The separation of the local edge processing and the cloud database allows independent debugging of local and remote components. | Maintainability (Modularity) | SOP 4.7 | Architecture Separation | **INVALID** (End Users) | Codebase architecture | **Misplaced** | General users and motorists have zero access to source code or debugging workflows. | Move to IT Expert Review | Route exclusively to IT Experts evaluating repository architecture. |
| **62** | The backend data structure (Firebase/Supabase) is organized efficiently for future updates and data retrieval. | Maintainability (Modifiability) | SOP 4.7 | Cloud Database Schema | **INVALID** (End Users) | Firestore collections | **Misplaced & Inaccurate** | Motorists cannot see backend DB. Mentions "Supabase" while app strictly uses Firebase Firestore! | Move to IT Expert Review | Route to IT Experts; remove reference to Supabase: *"The Firebase database structure is logically organized for efficient maintenance and data retrieval."* |
| **63** | The YOLOv8 model can be updated independently of the core application codebase. | Maintainability (Modifiability / Decoupling) | SOP 4.7 | TFLite Asset Decoupling | **INVALID** (End Users) | `assets/best_saved_model/` | **Misplaced** | Only software developers and AI engineers know how the model is bundled. | Move to IT Expert Review | Route to IT Experts: *"The TFLite model weights can be updated or replaced without requiring significant architectural refactoring."* |
| **64** | The codebase follows modular programming conventions and standard documentation practices. | Maintainability (Analysability) | SOP 4.7 | Dart Code Structure | **INVALID** (End Users) | Repository documentation | **Misplaced** | Pure software engineering code-review metric. | Move to IT Expert Review | Route to IT Experts: *"The application codebase adheres to modular programming conventions, clean architecture, and standard documentation."* |
| **65** | The mapping module and AI detection engine operate as independent software components. | Maintainability (Modularity / Reusability) | SOP 4.7 | Component Decoupling | **INVALID** (End Users) | `lib/model_detections.dart` | **Misplaced** | Architectural attribute unobservable from the mobile UI. | Move to IT Expert Review | Route to IT Experts: *"The computer vision inference pipeline and the GIS mapping modules function as decoupled software components."* |
| **66** | The application package (APK) installs and runs across standard Android device hardware configurations. | Portability (Installability) | SOP 4.8 | Android APK Deployment | Motorists, IT Experts | Android 10+ devices | Aligned | Observable installability construct. | Keep | The application installs and runs properly on standard Android smartphone hardware. |
| **67** | The application adapts smoothly when transitioning between different network connections (e.g., Wi-Fi to Mobile Data). | Portability (Adaptability) | SOP 4.8 | Network Transition | Motorists, IT Experts | Connectivity streams | Aligned | Observable during road testing when switching from home Wi-Fi to cellular data. | Keep | The application transitions smoothly between different network connections (such as Wi-Fi and mobile data) without crashing. |
| **68** | The application package (APK) file size conforms to low-to-mid-range Android device storage limits. | Portability (Resource Footprint) | SOP 4.8 | APK Size | Motorists, IT Experts | Debug APK ~246MB, Release ~65MB | Partly Aligned | Vague standard ("conforms to storage limits"). File size is better reported as an empirical metric. | Revise / Report Size | The application download and storage footprint is reasonable for everyday smartphone devices. *(Report exact APK size in MB).* |
| **69** | The optimized TensorFlow Lite (.tflite) model file is compatible across alternative hardware runtimes. | Portability (Hardware Adaptability) | SOP 4.8 | TFLite Runtime Compatibility | **INVALID** (End Users) | CPU/GPU delegates | Unobservable | End-users do not test alternative hardware runtimes (NNAPI, GPU, CPU). | Move to Technical Testing | **Evaluate via runtime benchmarking:** Report GPU vs CPU inference speed on different test devices. |
| **70** | Interface rendering re-aligns appropriately during screen orientation changes (portrait and landscape modes). | Portability (Adaptability) | SOP 4.8 | Responsive Orientation | Motorists, Commuters | Screen orientation tests | Aligned | Directly observable by rotating the device. | Keep | The interface layout re-aligns appropriately when switching between portrait and landscape screen orientations. |
| **71** | The Text-to-Speech (TTS) audio alert system delivers proximity warnings without requiring the driver to view the screen. | Safety (Freedom from Risk) | SOP 4.9 | Audio Alerts / Mobile | Motorists | `lib/pothole_notifier.dart` | Overlapping | 100% duplicate of Item 16 & 19. | Consolidate | *(Consolidate into SOP 1.4 / Usability to eliminate triple-counting).* |
| **72** | Proximity alerts trigger at the predefined distance threshold (e.g., 20 meters) upon approach. | Safety (Alert Timeliness) | SOP 4.9 | 20m Geofence / Mobile | Motorists | `lib/map_screen.dart` | Overlapping | 100% duplicate of Item 18. | Consolidate | *(Consolidate into SOP 1.4).* |
| **73** | The visual display renders hazard notifications while maintaining visibility of core navigation elements. | Safety (Visual Distraction Mitigation) | SOP 4.9 | Overlay UI / Mobile | Motorists | `lib/map_screen.dart` | Overlapping | 100% duplicate of Item 17. | Consolidate | *(Consolidate into SOP 1.4).* |
| **74** | The system manages temporary GPS signal loss without outputting erroneous route commands. | Safety (Fail-Safe Navigation) | SOP 4.9 | GPS Fallback | Motorists | Location service | Aligned | Valid safety resilience construct. | Keep | The system safely handles temporary GPS signal loss without giving sudden or dangerous route commands. |
| **75** | The application executes image capture and background auto-preprocessing within the user workflow while in transit. | Safety (In-Transit Workflow) | SOP 4.9 | In-Transit Capture | Motorists | Scanner workflow | Vague & Overlapping | Vague phrasing; overlaps with Item 1 and Item 3. Encourages active phone manipulation while driving. | Revise / Caution | When safely mounted, the application allows straightforward hazard logging without creating hazardous driver distraction. |

---

## 6. Alignment Summary & Statistics

To ensure methodological clarity, the evaluation of the 75 original items is categorized below:

* **Directly Aligned / Kept with minor polish:** 18 items (24.0%)
* **Partly Aligned / Revised for clarity, neutrality, and observability:** 22 items (29.3%)
* **Methodologically Invalid (Model Metrics forced into survey):** 5 items (6.7%) — *Must be reported in Chapter 4 experimental tables.*
* **Unobservable to End-Users / White-Box Code & Schema Audits:** 13 items (17.3%) — *Must be routed to IT Expert checklist or technical assessment.*
* **Factual Mismatch / Phantom Feature:** 1 item (1.3%) — *Item 58 (automated PII blurring does not exist in code; must be removed).*
* **Redundant / Overlapping:** 12 items (16.0%) — *SOP 4.9 duplicates SOP 1.4 and Usability.*
* **Factual Syntax / Broken Grammar:** 4 items (5.3%) — *Items 23, 52, 55, and 62.*

> [!IMPORTANT]
> **Total Actionable User Survey Items Extracted:** By removing the 5 invalid model-metric items, eliminating the 12 redundant duplicate items, dropping the phantom PII item, and routing the 13 white-box code/database items to an IT Expert Technical Audit, the core end-user instrument is streamlined from an exhausting, confusing 75 items down to a focused, psychometrically sound instrument of **25 core motorist items, 10 LGU administrator items, and 12 IT expert quality items**.

---

## 7. Distinguishing User Perception from Technical Performance

A central requirement for the computer science thesis is maintaining strict demarcation between **subjective user perception** and **objective technical benchmarks**.

```mermaid
flowchart TD
    subgraph Subjective Evaluation [User Perception Survey]
        A1[Driver Perceived Usability]
        A2[Clarity of Visual Hazard Markers]
        A3[Timeliness of Auditory TTS Alerts]
        A4[Ease of Report Submission Workflow]
        A5[LGU Administrative Dashboard Utility]
        A6[Perceived Contribution to SDG 11.2]
    end

    subgraph Objective Evaluation [Empirical Technical Benchmarks]
        B1[YOLOv8 Confusion Matrix]
        B2[Precision, Recall, F1-Score, mAP@0.5]
        B3[Inference Latency & FPS Profiling]
        B4[Euclidean GPS Mean Absolute Error]
        B5[Bandwidth Consumption & Storage KB]
        B6[Firestore Security Rule Test Suite]
    end
```

### Table of Methodological Placement

| Claimed Characteristic | What the Questionnaire Can Measure | What Requires Empirical Technical Testing (Chapter 4) |
| :--- | :--- | :--- |
| **Pothole & Crack Detection** | Do drivers find the visual detection boxes clear, believable, and non-distracting? | Precision (0.6438), Recall (0.4697), F1-Score (0.5395), and mAP@0.50 (0.4696) across ground-truth test images. |
| **Inference Speed & Responsiveness** | Do users feel the scanning interface runs smoothly without annoying freezes? | Measured frame latency ($17.00\text{ ms}$ on T4, on-device frame processing time in ms) and throughput ($58.81\text{ FPS}$). |
| **Geospatial Pin Placement** | Does the map marker appear where the user expects to see the hazard? | GPS Mean Absolute Error (MAE) in meters calculated using Universal Transverse Mercator (UTM) Euclidean distance against ground truth. |
| **Offline Synchronization** | Did the user observe the report upload after reconnecting to Wi-Fi? | Network intercept testing: verification that SQLite records survive app kill and execute atomic upload retries. |
| **Data Bandwidth & Battery** | Did the device overheat noticeably or feel drained during the trial? | Automated Android profiler logging: exact megabytes transferred and battery percentage drop per 60 minutes of active tracking. |
| **Database & System Security** | Did the user see standard permission prompts for Camera and Location? | Firebase security rule testing (`test/firebase_workflows.cjs`): proof that unauthorized write, update, and delete calls are rejected. |
| **LGU Deterioration Forecast** | Do LGU officers find the 24-barangay charts and risk badges useful for scheduling? | Deterministic weighted least squares mathematical formulation, Pagasa wet-season weighting verification, and 332m spatial grid unit tests. |

---

## 8. Role-Based Respondent Group Segmentation

To prevent asking respondents questions they cannot possibly answer, the evaluation must be segmented into three distinct respondent profiles:

```
                          ┌──────────────────────────────────────────────┐
                          │         RoadSense AI Evaluation Base         │
                          └──────────────────────┬───────────────────────┘
                                                 │
         ┌───────────────────────────────────────┼──────────────────────────────────────┐
         ▼                                       ▼                                      ▼
┌─────────────────────────────────┐   ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
│   Group A: Motorists & Users    │   │     Group B: LGU & DPWH Admins   │   │    Group C: IT & AI Experts      │
│     (Target: 50 Respondents)    │   │      (Target: 10 Respondents)    │   │     (Target: 5–10 Experts)       │
├─────────────────────────────────┤   ├──────────────────────────────────┤   ├──────────────────────────────────┤
│ • Mobile driving assistant      │   │ • Web Admin Dashboard            │   │ • ISO/IEC 25010 Quality Model    │
│ • Camera capture & detection    │   │ • Review Queue & DPWH Triage     │   │ • Architecture & Code Modularity │
│ • TTS & visual proximity alerts │   │ • 24-Barangay Insights & Risk    │   │ • Firebase Security Rules        │
│ • Navigation & hazard avoidance │   │ • 30-Day Maintenance Forecasts   │   │ • Edge TFLite Portability        │
│ • Community reporting workflow  │   │ • Neutralized CSV Report Export  │   │ • Hardware-Software Integration  │
│ • SDG 11.2 perceived impact     │   │ • Trash Bin & Report Restore     │   │ • Offline SQLite Data Integrity  │
└─────────────────────────────────┘   └──────────────────────────────────┘   └──────────────────────────────────┘
```

1. **Group A: Licensed Motorists & Daily Commuters (N = 50)**
   * **Target:** Tricycle drivers, motorcycle commuters, private car owners, and jeepney drivers active in Sta. Maria, Bulacan.
   * **Assigned Sections:** Part II (Mobile Driving Assistant & Road Hazard Reporting) and Part III (SDG 11 Target 11.2 Contribution).
   * **Exclusions:** Must NEVER be asked to rate Firebase database schemas, JSON payloads, or code maintainability.

2. **Group B: Local Government Unit Representatives & Road Engineers (N = 5–10)**
   * **Target:** Municipal Engineering Office (MEO) personnel, DPWH District representatives, disaster risk reduction officers (MDRRMO), and barangay officials.
   * **Assigned Sections:** Part III (SDG 11 Target 11.2 Contribution) and Part IV (Web GIS & Municipal Road Maintenance Dashboard).
   * **Focus:** Moderation workflow, DPWH statutory triage priority, 24-barangay spatial analytics, 30-day forecast planning, and export compliance.

3. **Group C: IT Professionals & Software/AI Engineers (N = 5–10)**
   * **Target:** Senior software developers, computer science faculty, systems analysts, and machine learning practitioners.
   * **Assigned Sections:** Part V (ISO/IEC 25010 Software Quality Assessment across Compatibility, Reliability, Security, Maintainability, and Portability).
   * **Prerequisite:** Provided with access to the GitHub source repository, `firestore.rules`, test suites, and architecture documentation.

---

## 9. Recommended Evaluation Procedure & Standardized Task Script

To ensure valid and comparable survey responses, participants must not answer the questionnaire cold. They must complete a standardized task walkthrough before rating the software.

### 9.1 Standardized 8-Task Evaluation Script

| Task ID | Task Description | Platform | Target User Group | Questionnaire Items Supported |
| :---: | :--- | :--- | :--- | :--- |
| **TASK-01** | **System Setup & Map Orientation**<br>Launch the RoadSense mobile app, observe GPS marker acquisition, pan and zoom the map across Santa Maria, Bulacan, and toggle between Dark and Light display modes. | Mobile | Motorists, Commuters | Part II: Items 1, 2, 4 |
| **TASK-02** | **Simulated Hazard Scanning**<br>Open the camera scanner, point the phone toward a sample road distress photograph (pothole or alligator crack), and observe real-time bounding box detection and class labeling. | Mobile | Motorists, Commuters | Part II: Items 5, 6, 7 |
| **TASK-03** | **Defect Report Submission**<br>Capture a defect image, review the detected bounding box and severity badge in the confirmation dialog, and tap "Submit Report" to synchronize with the cloud database. | Mobile | Motorists, Commuters | Part II: Items 8, 9, 10 |
| **TASK-04** | **Offline Queue Simulation**<br>Enable Airplane Mode (disconnect cellular data and Wi-Fi), capture a defect, confirm the report is saved to the local offline queue, re-enable connectivity, and observe automated synchronization. | Mobile | Motorists, Commuters | Part II: Item 11 |
| **TASK-05** | **Navigation & Proximity Alert Drive Test**<br>Mount the smartphone on a vehicle dashboard, initiate navigation toward a destination in Sta. Maria with known hazard markers, approach within 20 meters, and listen for the hands-free TTS audio alert. | Mobile | Motorists, Commuters | Part II: Items 12, 13, 14, 15, 16 |
| **TASK-06** | **Hazard Avoidance Route Optimization**<br>Request a route in the app and tap the Master Control Button to switch between "Road 1", "Road 2", and "Smart Route", observing the avoidance of dense pothole clusters. | Mobile | Motorists, Commuters | Part II: Item 17 |
| **TASK-07** | **LGU Admin Triage & Review (Admin Session)**<br>Log into the Web Admin Dashboard, filter the Review Queue by DPWH priority score, inspect a pending submission, adjust defect classification, and approve/reject the report. | Web | LGU / DPWH Admins | Part IV: Items 23, 24, 25, 26, 27 |
| **TASK-08** | **Barangay Analytics & Export (Admin Session)**<br>Navigate to Barangay Insights, inspect the 24-barangay hotspot cluster map, examine the 30-day forecast panel, and trigger a CSV export of maintenance reports. | Web | LGU / DPWH Admins | Part IV: Items 28, 29, 30, 31, 32 |

### 9.2 Evaluation Session Control Protocol
1. **No Researcher Coaching:** The facilitator must never say *"Notice how fast and accurate the AI is."* Instructions must be neutral: *"Please perform Task 2 and observe the screen."*
2. **Device Standard:** Tests should be run on standardized test devices (e.g., the primary Tecno Pova 5 test hardware documented in Chapter 2) or the participant's personal Android phone (recording brand, model, and Android version).
3. **Session Logging:** The facilitator records:
   * Participant ID, Role, Date, Vehicle Type (Motorcycle, Tricycle, Car, Commuter, Admin).
   * Tasks successfully completed without assistance.
   * Features unavailable or interrupted (e.g., cloudy GPS signal, zero cellular data).

---

## 10. Required Empirical Technical Evaluations (Chapter 4)

The following claims from the original questionnaire **cannot be established by survey questions** and must be supported by empirical testing documented in Chapter 4:

1. **YOLOv8 Detection Accuracy (SOP 2 Benchmark):**
   * Report the finalized test metrics from `assets/thesis_results/thesis_test_metrics.csv`:
     * Pothole (Code 01): Precision 77.97%, Recall 64.76%, F1 70.75%, mAP@0.50 69.46%
     * Alligator Crack (Code 02): Precision 66.52%, Recall 50.84%, F1 57.63%, mAP@0.50 52.43%
     * Longitudinal Crack (Code 12): Precision 56.52%, Recall 29.31%, F1 38.60%, mAP@0.50 27.42%
     * Transverse Crack (Code 12): Precision 56.53%, Recall 42.98%, F1 48.83%, mAP@0.50 38.52%
     * Macro Average: Precision 64.38%, Recall 46.97%, F1 53.95%, mAP@0.50 46.96%
   * Present the Confusion Matrix normalized figure (`assets/thesis_results/confusion_matrix_normalized.png`).

2. **Inference Latency & Frame Rate (SOP 1.1 / 4.2):**
   * Present the hardware benchmark results from `assets/thesis_results/thesis_speed_benchmark.txt`:
     * Average Latency: $17.00\text{ ms} \pm 0.28\text{ ms}$ on GPU (Tesla T4) / $\sim 85\text{ ms}$ on mobile MediaTek Helio G99.
     * Throughput: $58.81\text{ FPS}$ (exceeding real-time 30 FPS threshold).

3. **Geospatial Location Error (Mean Absolute Error) (SOP 1.3 / 4.1):**
   * Drive-test ground truth validation across 10 sample potholes in Sta. Maria, Bulacan.
   * Calculate Euclidean distance offset in meters using projected UTM coordinates:
     $$MAE = \\frac{1}{n} \\sum_{i=1}^{n} |d_i|$$

4. **Security & Access Control Verification (SOP 4.6):**
   * Document automated rule verification using the local Firebase emulator test suite (`test/firebase_workflows.cjs`, 17 passed checks):
     * Unauthenticated writes rejected.
     * Non-admin role escalation blocked.
     * Trashed reports inaccessible to general queries.

---

## 11. Remaining Questions for the Thesis Adviser & Researchers

Before deploying the revised questionnaire, the authors should clarify the following points with Mr. Emmanuel Sagayno (Adviser) and Dr. Jovy Jay D. Cabrera (Panel Chair):

1. **Separation of SOP 2:** Will the thesis committee confirm that SOP 2 (*Performance Accuracy: Precision, Recall, F1, mAP*) will be answered purely through Chapter 4's experimental data tables rather than Likert survey questions?
2. **Target ISO 25010 Edition:** Does the panel prefer citing **ISO/IEC 25010:2023** (which includes *Safety* as a product quality characteristic) or **ISO/IEC 25010:2011** (where Safety is treated under *Quality in Use - Freedom from Risk*)?
3. **Admin Dashboard Evaluation Logistics:** How will LGU representatives from Santa Maria participate? Will researchers conduct a guided demonstration of the Web Dashboard and Admin Triage queue before administering Part IV of the questionnaire?
4. **PII Blurring Scope:** Since automated face/license-plate blurring is not implemented in the current mobile code, should the researchers remove the claim from the manuscript's Ethical Considerations section or add it as a documented *delimitation / future enhancement*?
5. **Pilot Testing Schedule:** Will the panel approve a 10-respondent pilot administration to establish Cronbach's alpha reliability before the full 60-participant rollout?

---
*Report prepared for RoadSense AI Thesis Documentation Repository.*
""")
    print(f"Generated {out_path}")

if __name__ == "__main__":
    generate_report()

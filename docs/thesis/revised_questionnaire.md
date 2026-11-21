# RoadSense AI: Research Instrument & Evaluation Questionnaire (Revised)

**Study Title:** Visualizing Road Hazards: A YOLOv8-Powered Geospatial Mapping System for Pothole Navigation  
**Researchers:** Aries S. Contado, Jenard Phil Tabudlo  
**Degree Program:** Bachelor of Science in Computer Science  
**Institution:** Immaculate Conception I-College of Arts and Technology (ICI-CAT), Santa Maria, Bulacan  
**Adviser:** Mr. Emmanuel Sagayno | **Panel Chair:** Dr. Jovy Jay D. Cabrera  
**Target Locale:** Municipality of Santa Maria, Bulacan  

---

## Participant Informed Consent & Privacy Notice

**Dear Participant,**

Thank you for participating in the evaluation of **RoadSense AI**, a mobile-and-web intelligent transportation system designed to enhance road safety and municipal maintenance planning in Santa Maria, Bulacan. This system combines on-device YOLOv8 computer vision for road defect detection (potholes and pavement cracks), an interactive geospatial hazard map, hands-free Text-to-Speech (TTS) proximity alerts, and an administrative dashboard for local government units (LGU).

### Ethical & Privacy Safeguards (RA 10173 - Data Privacy Act of 2012)
1. **Voluntary Participation:** Your participation is completely voluntary. You may withdraw at any time without penalty.
2. **Confidentiality:** All responses collected will be kept strictly confidential and used solely for academic research and statistical evaluation.
3. **Location Privacy:** Live GPS tracking is processed strictly on your local mobile device during active navigation and is never broadcast or streamed to external tracking servers.
4. **Data Handling:** No personally identifiable information (PII) will be published in the thesis manuscript.

---

## Response Rating Scale & Interpretation

Please evaluate each statement based on your direct experience using the application during the field evaluation session. Indicate your level of agreement using the 5-point scale below. If you did not test or experience a particular feature, please select **N/A (Not Applicable / Not Experienced)** rather than guessing.

| Score | Rating | Score Range | Verbal Interpretation | Operational Meaning |
| :---: | :--- | :---: | :--- | :--- |
| **5** | **Strongly Agree (SA)** | 4.21 – 5.00 | Excellent / Highly Acceptable | The feature performed exceptionally well and fully met expectations. |
| **4** | **Agree (A)** | 3.41 – 4.20 | Good / Acceptable | The feature performed satisfactorily with only minor limitations. |
| **3** | **Neutral (N)** | 2.61 – 3.40 | Moderate / Undecided | The feature performed adequately, or the effect was neither positive nor negative. |
| **2** | **Disagree (D)** | 1.81 – 2.60 | Poor / Unacceptable | The feature did not perform well and requires noticeable improvement. |
| **1** | **Strongly Disagree (SD)** | 1.00 – 1.80 | Very Poor / Completely Unacceptable | The feature failed to work or was completely unsatisfactory. |
| **N/A** | **Not Applicable / Not Tested** | — | Not Experienced | The respondent did not test, view, or experience this specific feature. |

---

## Part I: Respondent Profile & Demographics

**1. Participant Name (Optional):** _________________________________________________  
**2. Evaluation Date:** ________________________  
**3. Primary Respondent Role (Select one):**  
* [ ] **Group A: Motorist / Commuter** (Proceed to Part II, Part III, and Part VI)  
* [ ] **Group B: LGU Representative / Municipal Road Engineer** (Proceed to Part III, Part IV, and Part VI)  
* [ ] **Group C: IT Professional / Software & AI Expert** (Proceed to Part III, Part V, and Part VI)  

**4. Vehicle Type Regularly Operated (For Motorists only):**  
* [ ] Motorcycle  
* [ ] Tricycle  
* [ ] Private Car / SUV  
* [ ] Public Utility Vehicle (Jeepney / Van)  
* [ ] Daily Commuter (Non-driver)  

**5. Test Device Information:**  
* Smartphone Brand & Model: ________________________________  
* Android Version: [ ] Android 10 or below  [ ] Android 11–12  [ ] Android 13–14+  

---

## Part II: Mobile Driving Assistant & Road Hazard Reporting
*(To be completed by **Group A: Motorists, Commuters, and All Field Testers**)*

### Section A: In-App Camera & Defect Detection Usability (SOP 1.1)

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **A1** | The camera interface makes it easy to capture road hazards directly within the application. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **A2** | The application automatically prepares captured photos for AI analysis without requiring manual cropping or editing. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **A3** | The camera and scanning interface operate smoothly without noticeable stuttering or device freezing. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **A4** | The camera capture functions adequately under typical daytime lighting conditions (e.g., bright sunlight and tree shadows). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **A5** | The detected bounding box overlays clearly indicate the location and boundary of road defects. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **A6** | The system rarely misidentifies shadows, wet pavement patches, or painted road markings as hazards. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Section B: Report Submission, Sync & Offline Resiliency (SOP 1.2)

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **B1** | The report review dialog allows me to verify defect details and severity before submitting. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B2** | Hazard reports and photos upload within an acceptable timeframe without causing long delays. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B3** | The application displays a clear confirmation notice on screen once a report has been successfully submitted. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B4** | When internet connectivity drops, the app saves my report offline and uploads it automatically when reconnected. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B5** | The app allows me to view my past submitted reports and track their review status. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Section C: Geospatial Map & Hazard Visualization (SOP 1.3)

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **C1** | The interactive map is easy to pan, zoom, and follow while traveling. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **C2** | The map markers accurately reflect the real-world locations of reported road hazards. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **C3** | The map uses distinct marker colors (Red, Orange, Yellow) to clearly show hazard severity levels. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **C4** | The map displays verified road hazard reports submitted by other community users. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **C5** | The map filter controls make it easy to view specific hazard types (potholes vs. cracks). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Section D: Proximity Alerts & Navigation Safety (SOP 1.4)

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **D1** | The application plays a clear spoken voice warning (Text-to-Speech) when approaching a reported road hazard. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **D2** | The on-screen visual alert banner appears clearly without obstructing essential map navigation. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **D3** | Proximity warnings are delivered early enough (about 20 meters before the hazard) to provide adequate reaction time. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **D4** | Spoken voice alerts keep me informed of upcoming road defects without forcing me to tap or look down at the phone. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **D5** | The application maintains steady location tracking in the background throughout the navigation journey. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **D6** | The route planning feature helps drivers choose smoother paths by avoiding dense road hazard areas. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

---

## Part III: Contribution to Sustainable Development Goal 11 (SOP 3)
*(To be completed by **ALL RESPONDENTS: Motorists, LGU Staff, and IT Experts**)*

**SDG 11 - Target 11.2:** *"Provide access to safe, affordable, accessible, and sustainable transport systems for all, improving road safety, notably by expanding public transport, with special attention to the needs of those in vulnerable situations, women, children, persons with disabilities, and older persons."*

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **S1** | Real-time proximity alerts help drivers anticipate road defects and navigate more safely. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **S2** | The application empowers everyday citizens to actively contribute to municipal road maintenance through crowdsourcing. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **S3** | The hazard map provides actionable data that can help local authorities prioritize road repairs in Santa Maria. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **S4** | The navigation and hazard warnings help reduce vehicle wear-and-tear and potential road accident risks. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **S5** | The system is particularly beneficial for vulnerable road users, such as motorcycle and tricycle riders. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

---

## Part IV: Web GIS & Municipal Road Maintenance Dashboard
*(To be completed by **Group B: Local Government Unit (LGU) Officials, DPWH Representatives, and Admins**)*

### Section A: Admin Moderation & DPWH Statutory Triage Workflow

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **M1** | The Admin Review Queue organizes submitted reports logically according to DPWH statutory urgency and priority. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **M2** | The priority score breakdown (Harm, Credibility, Exposure, SLA Aging) provides clear justification for prioritizing inspections. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **M3** | The system clearly flags reports that exceed DPWH statutory response time limits (SLA breach warnings). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **M4** | The report inspection panel allows administrators to easily review photos, adjust defect classifications, and verify severity. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **M5** | The one-click Approve and Reject workflows function smoothly with immediate feedback. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **M6** | The Trash Bin feature safely archives deleted reports and allows accidental deletions to be restored. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Section B: 24-Barangay Analytics, Hotspots & Forecasting

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **B1** | The Barangay Insights panel provides clear summaries of total, approved, and pending hazards across Santa Maria's 24 barangays. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B2** | The 30-day deterioration forecast estimates are easy to interpret and support municipal maintenance scheduling. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B3** | The spatial hotspot map effectively identifies dense defect clusters requiring urgent engineering intervention. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **B4** | The CSV export feature generates clean maintenance spreadsheets suitable for official DPWH or municipal reporting. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

---

## Part V: ISO/IEC 25010 Software Quality Assessment
*(To be completed by **Group C: IT Professionals, Software Engineers, and Systems Evaluators**)*

*Note: Evaluators in this section should have inspected the system architecture, codebase, and API configurations.*

### Characteristic 1: Functional Suitability

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **FS1** | The system provides all stated functions required for mobile road hazard reporting and administrative review. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **FS2** | The on-device inference pipeline accurately classifies supported DPWH defect types (potholes and pavement cracks). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **FS3** | The assigned severity ratings (Low, Medium, High) logically correspond to detected defect surface area and DPWH criteria. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Characteristic 2: Performance Efficiency

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **PE1** | On-device YOLOv8 inference operates with acceptable latency on standard smartphone hardware (MediaTek Helio G99 / Snapdragon). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **PE2** | The interactive map and geospatial markers initialize and render within acceptable response time thresholds. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **PE3** | The background location tracking service executes without causing abnormal device battery depletion or thermal throttling. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Characteristic 3: Compatibility & Interoperability

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **CO1** | The application communicates reliably with external cloud databases (Firebase) and geospatial APIs (OpenStreetMap, ORS). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **CO2** | The mobile client co-exists cleanly alongside standard Android system background processes and concurrent services. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Characteristic 4: Reliability & Fault Tolerance

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **RE1** | The mobile and web applications operate without unexpected crashes, exceptions, or memory leaks during extended testing. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **RE2** | The offline SQLite queue reliably persists pending submissions and executes atomic synchronization upon network recovery. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **RE3** | The application recovers gracefully from system interruptions (e.g., incoming phone calls or screen lockouts). | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Characteristic 5: Security & Data Integrity

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **SE1** | Firestore security rules effectively enforce role-based access control, preventing unauthorized data modification or deletion. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **SE2** | Continuous background GPS coordinates used for proximity alerts remain in local volatile memory and are not uploaded to servers. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **SE3** | The CSV export pipeline neutralizes formula injection triggers (`=`, `+`, `-`, `@`) and protects reporter email privacy. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Characteristic 6: Maintainability & Modularity

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **MA1** | The Flutter codebase exhibits clean modular architecture, separating UI presentation, domain rules, and cloud services. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **MA2** | The TFLite model weights and label metadata are cleanly decoupled, allowing model re-training without altering core UI code. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

### Characteristic 7: Portability & Responsive Design

| # | Statement | 1<br>(SD) | 2<br>(D) | 3<br>(N) | 4<br>(A) | 5<br>(SA) | N/A |
| :-: | :--- | :-: | :-: | :-: | :-: | :-: | :-: |
| **PO1** | The application builds and deploys consistently across different Android screen densities and hardware specifications. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| **PO2** | The Web GIS and Admin Dashboard scale responsively across desktop, tablet, and mobile web viewports. | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

---

## Part VI: Qualitative Feedback & Recommendations
*(Optional for all respondents)*

1. **What features or aspects of RoadSense AI did you find most useful or effective?**  
   _________________________________________________________________________________________________________________  
   _________________________________________________________________________________________________________________  

2. **Did you encounter any difficulties, bugs, or confusing screens during your evaluation session?**  
   _________________________________________________________________________________________________________________  
   _________________________________________________________________________________________________________________  

3. **What specific suggestions do you have to improve RoadSense AI for daily motorists or local government road engineers?**  
   _________________________________________________________________________________________________________________  
   _________________________________________________________________________________________________________________  

---

## Respondent Certification

I hereby certify that I have personally evaluated the **RoadSense AI** system and that my ratings reflect my honest and independent judgment based on direct testing.

_______________________________________________                 _____________________________  
**Signature over Printed Name**                                  **Date**

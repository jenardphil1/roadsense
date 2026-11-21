# Local markers and admin map

The user web map and mobile map use the previous mobile circular class icons.
Visible diameter is `clamp(14 + (zoom - 10) * 1.8, 14, 30)` logical pixels.
The maps rebuild the marker layer after zoom changes of at least 0.05 levels.
Web pins are centered inside their larger touch area so that layout constraints
do not enlarge the artwork. Clusters also scale with zoom, from 22 to 34 pixels.

Settings → Developer options reveals the Custom markers map button. The local
editor offers Pothole, Alligator crack, Longitudinal crack and Transverse crack,
latitude/longitude, saved-marker selection, editing and deletion. New markers
start at the map center. Tapping a local marker opens its editor, including an
expanded cluster child. Data is stored in SharedPreferences under
`roadsense_developer_markers_v1`; disabling Developer options hides these markers
without deleting them. The editor never invokes report submission or Firestore.
Local markers belong only to that device or browser and are labelled as developer
data. They are not synchronized with another device.

Built-in Santa Maria sample pins are no longer injected by either live map.
Known sample IDs are excluded from admin records and live-map input. Sample data
definitions remain available as test fixtures. The sign-in map has no artificial
hazard pins or fabricated active-hazard/latency values. Existing real reports are
preserved.

Review Queue uses its actual available width after the application sidebar.
Its inspector docks only at 1380+ pixels of queue space; otherwise inspection
opens in a dialog. The table uses the remaining width, with Actions immediately
after Report, an exposed horizontal scrollbar and a return to the first columns
when selection changes. Narrow layouts use report cards.

The admin map uses its actual pane width, scales pins with zoom, fits the first
available reports once, preserves subsequent manual panning, and reserves space
for overlays when fitting bounds. Its legend wraps within the map width and the
compact selection card leaves room for map controls.

Validation: the 92-test focused suite passed; after the final layout corrections,
all 30 map/editor/admin tests passed again. These include actual rendered marker
sizes at zoom 14, 14.25 and 15 in both map widgets, all four class glyphs,
sample exclusion, developer toggle/button interaction, no submission callback,
persistence, editing/deletion, invalid coordinates, dialog disposal, admin table
actions beside an inspector and constrained admin map layouts. Required mobile
and web analysis reported no errors or warnings; informational lints remain.
Both web and Android profile builds completed successfully. The Android profile
APK was installed using `adb install -r`, preserving app data. Its installed
SHA-256 matches the local artifact:
`2094119824dca5266bfecb9fe6e7f942028a42e6280ec6be4dd6e5708ec61bc4`.
On the TECNO LH7n, Settings → Developer options revealed the map button; the editor
showed all four class options. A local Alligator crack was saved, appeared in the
cluster, was selected again for editing, and was deleted. The saved-marker list
was then empty and the cluster returned to its original count. Zooming the map
changed marker size. No report was submitted. Full field editing was covered in
widget tests; no road/driving validation was performed for this UI change.

The rebuilt local web preview loaded in headless Edge. The user then requested
skipping further tests and publishing the completed web build to Firebase
Hosting. `firebase deploy --only hosting --project pothole-app-b277b
--non-interactive` completed successfully: Firebase confirmed version finalized,
release complete and deploy complete at https://pothole-app-b277b.web.app.
No additional tests were run after the user's skip request. Backend functions
and Firestore rules were not deployed by this hosting-only command.

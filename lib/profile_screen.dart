import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'cloud_service.dart';
import 'dpwh_standards.dart';
import 'mobile_components.dart';
import 'pending_report_queue.dart';
import 'settings_dialog.dart';
import 'app_settings.dart';
import 'app_design.dart';
import 'email_verification_view.dart';
import 'onboarding_screen.dart';
import 'upload_error.dart';
import 'user_reports_model.dart';

/// Controls which top-level section [ProfileScreen] emphasizes.
enum ProfileScreenSection { all, reports, profile }

/// Mobile & shared Profile / Submitted Reports screen.
class ProfileScreen extends StatefulWidget {
  final VoidCallback? onSwitchToMap;
  final Function(LatLng location, String? docId, Map<String, dynamic>? data)?
  onLocateOnMap;
  final Function(List<LatLng> locations, {String filterLabel})?
  onLocateAllOnMap;
  final ProfileScreenSection section;
  final VoidCallback? onReplayTour;
  final Map<String, GlobalKey> tourTargets;
  final VoidCallback? onOpenScan;
  final PendingReportQueue? pendingQueue;
  final Future<void> Function({String? targetId})? onRetryPendingReports;
  final String? currentUidOverride;
  final Stream<List<CloudReportRecord>>? userReportsStreamOverride;
  final bool? isVerifiedOverride;

  const ProfileScreen({
    super.key,
    this.onSwitchToMap,
    this.onLocateOnMap,
    this.onLocateAllOnMap,
    this.section = ProfileScreenSection.all,
    this.onReplayTour,
    this.tourTargets = const {},
    this.onOpenScan,
    this.pendingQueue,
    this.onRetryPendingReports,
    this.currentUidOverride,
    this.userReportsStreamOverride,
    this.isVerifiedOverride,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _phoneController;
  late TextEditingController _reportSearchController;
  String _savedFirstName = '';
  String _savedLastName = '';
  String _savedPhone = '';
  bool _isSaving = false;
  bool _isSendingReset = false;
  bool _showTrashBin = false;
  String _reportSearchQuery = '';
  String _statusFilter = 'all';
  String? _defectFilter;
  bool _isOffline = false;
  StreamSubscription<dynamic>? _connectivitySubscription;
  PendingReportQueue? _activeQueue;
  List<PendingReportRecord> _localRecords = const [];
  bool _localRecordsLoaded = false;
  bool _isRetryingQueue = false;

  bool get _isProfileDirty =>
      _firstNameController.text.trim() != _savedFirstName ||
      _lastNameController.text.trim() != _savedLastName ||
      _phoneController.text.trim() != _savedPhone;

  void _onProfileFieldEdited() {
    if (mounted) setState(() {});
  }

  void _discardProfileChanges() {
    setState(() {
      _firstNameController.text = _savedFirstName;
      _lastNameController.text = _savedLastName;
      _phoneController.text = _savedPhone;
    });
  }

  String? get _effectiveUid =>
      widget.currentUidOverride ?? CloudService.instance.currentUser?.uid;

  void _attachQueue(PendingReportQueue? queue, {bool notify = true}) {
    if (identical(_activeQueue, queue)) return;
    _activeQueue?.changes.removeListener(_onQueueChanged);
    _activeQueue = queue;
    _activeQueue?.changes.addListener(_onQueueChanged);
    _reloadLocalRecords(notify: notify);
  }

  void _onQueueChanged() {
    _reloadLocalRecords();
  }

  void _reloadLocalRecords({bool notify = true}) {
    final queue = _activeQueue;
    final uid = _effectiveUid;
    final nextRecords = (queue == null || uid == null || uid.trim().isEmpty)
        ? const <PendingReportRecord>[]
        : queue.listForUserSync(uid);
    if (notify && mounted) {
      setState(() {
        _localRecords = nextRecords;
        _localRecordsLoaded = true;
      });
    } else {
      _localRecords = nextRecords;
      _localRecordsLoaded = true;
    }
  }

  Future<void> _triggerPendingRetry({String? targetId}) async {
    if (_isRetryingQueue) return;
    setState(() => _isRetryingQueue = true);
    try {
      if (widget.onRetryPendingReports != null) {
        await widget.onRetryPendingReports!(targetId: targetId);
      }
      _reloadLocalRecords();
    } finally {
      if (mounted) {
        setState(() => _isRetryingQueue = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _reportSearchController = TextEditingController();
    if (widget.userReportsStreamOverride == null &&
        widget.currentUidOverride == null) {
      _connectivitySubscription = watchSafeOfflineState((offline) {
        if (mounted && _isOffline != offline) {
          setState(() => _isOffline = offline);
        }
      });
    }

    if (widget.pendingQueue != null) {
      _attachQueue(widget.pendingQueue, notify: false);
    } else if (!kIsWeb && widget.userReportsStreamOverride == null) {
      getApplicationDocumentsDirectory().then((dir) {
        if (!mounted || widget.pendingQueue != null) return;
        _attachQueue(
          PendingReportQueue(Directory(p.join(dir.path, 'pending_reports'))),
        );
      });
    } else {
      _localRecordsLoaded = true;
    }

    final user = widget.currentUidOverride == null
        ? CloudService.instance.currentUser
        : null;
    final nameParts = (user?.displayName ?? '').split(' ');
    final initialFirst = nameParts.isNotEmpty ? nameParts.first : '';
    final initialLast = nameParts.length > 1
        ? nameParts.sublist(1).join(' ')
        : '';
    final initialPhone = user?.phoneNumber ?? '';

    _savedFirstName = initialFirst;
    _savedLastName = initialLast;
    _savedPhone = initialPhone;

    _firstNameController = TextEditingController(text: initialFirst);
    _lastNameController = TextEditingController(text: initialLast);
    _phoneController = TextEditingController(text: initialPhone);

    _firstNameController.addListener(_onProfileFieldEdited);
    _lastNameController.addListener(_onProfileFieldEdited);
    _phoneController.addListener(_onProfileFieldEdited);

    // Fetch stored Firestore user profile fields
    if (user != null) {
      FirebaseFirestore.instance.collection('users').doc(user.uid).get().then((
        doc,
      ) {
        if (doc.exists && doc.data() != null && mounted) {
          final data = doc.data()!;
          final bool hadEdits = _isProfileDirty;
          final fetchedFirst = data['firstName']?.toString().trim() ?? '';
          final fetchedLast = data['lastName']?.toString().trim() ?? '';
          final fetchedPhone = data['phoneNumber']?.toString().trim() ?? '';
          setState(() {
            if (fetchedFirst.isNotEmpty) {
              _savedFirstName = fetchedFirst;
              if (!hadEdits) _firstNameController.text = fetchedFirst;
            }
            if (fetchedLast.isNotEmpty) {
              _savedLastName = fetchedLast;
              if (!hadEdits) _lastNameController.text = fetchedLast;
            }
            if (fetchedPhone.isNotEmpty) {
              _savedPhone = fetchedPhone;
              if (!hadEdits) _phoneController.text = fetchedPhone;
            }
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingQueue != null &&
        !identical(widget.pendingQueue, _activeQueue)) {
      _attachQueue(widget.pendingQueue);
    }
    if (widget.currentUidOverride != oldWidget.currentUidOverride) {
      _reloadLocalRecords();
    }
  }

  @override
  void dispose() {
    _activeQueue?.changes.removeListener(_onQueueChanged);
    _connectivitySubscription?.cancel();
    _reportSearchController.dispose();
    _firstNameController
      ..removeListener(_onProfileFieldEdited)
      ..dispose();
    _lastNameController
      ..removeListener(_onProfileFieldEdited)
      ..dispose();
    _phoneController
      ..removeListener(_onProfileFieldEdited)
      ..dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final user = CloudService.instance.currentUser;
    if (user == null) return;
    final isDark = AppSettings.instance.isDarkMode;
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final phone = _phoneController.text.trim();

    setState(() => _isSaving = true);
    try {
      await CloudService.instance.updateUserProfileDetails(
        uid: user.uid,
        firstName: firstName,
        lastName: lastName,
        phoneNumber: phone,
      );
      if (mounted) {
        setState(() {
          _savedFirstName = firstName;
          _savedLastName = lastName;
          _savedPhone = phone;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Profile information updated successfully.'),
            backgroundColor: isDark ? AppDesign.brandHover : AppDesign.brand,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update profile: $e'),
            backgroundColor: AppDesign.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmAndSendPasswordReset(
    BuildContext context,
    String email,
    bool isDark,
  ) async {
    if (email.trim().isEmpty) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppDesign.surface(isDark),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Send password reset email?'),
        content: Text(
          'We will send password recovery instructions to $email.',
          style: TextStyle(color: AppDesign.textSecondary(isDark), height: 1.4),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(76, 48)),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: AppDesign.primaryButtonStyle(isDark: isDark),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Send Email'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isSendingReset = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Password reset email sent to $email.'),
            backgroundColor: AppDesign.brand,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not send reset email: $e'),
            backgroundColor: AppDesign.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSendingReset = false);
    }
  }

  Future<void> _confirmAndMoveToTrash(
    BuildContext context,
    String docId,
  ) async {
    final isDark = AppSettings.instance.isDarkMode;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppDesign.surface(isDark),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFF59E0B),
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Move to Trash?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppDesign.textPrimary(isDark),
              ),
            ),
          ],
        ),
        content: Text(
          'Move this pending report to your Trash Bin? You can restore or permanently clean it up anytime.',
          style: TextStyle(
            fontSize: 13,
            color: AppDesign.textSecondary(isDark),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: AppDesign.textSecondary(isDark),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Move to Trash',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CloudService.instance.userSoftDeletePothole(docId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Report moved to Trash Bin.'),
              backgroundColor: Color(0xFFF59E0B),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: $e'),
              backgroundColor: AppDesign.danger,
            ),
          );
        }
      }
    }
  }

  Future<void> _showEditReportDialog(
    BuildContext context,
    String docId,
    Map<String, dynamic> data,
  ) async {
    final isDark = AppSettings.instance.isDarkMode;
    int potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppDesign.surface(isDark),
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
                  Text(
                    'Edit Report',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppDesign.textPrimary(isDark),
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
                      const SizedBox(height: 6),

                      const SizedBox(height: 16),
                      Text(
                        'Defects in Frame',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppDesign.textPrimary(isDark),
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
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              '$potholeCount',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppDesign.textPrimary(isDark),
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

                      const SizedBox(height: 6),
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

                        potholeCount: potholeCount,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Report updated successfully.'),
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

  Future<void> _restoreReport(BuildContext context, String docId) async {
    try {
      await CloudService.instance.userRestorePothole(docId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Report restored to active submissions.'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to restore: $e'),
            backgroundColor: AppDesign.danger,
          ),
        );
      }
    }
  }

  Future<void> _confirmAndPermanentDelete(
    BuildContext context,
    String docId,
  ) async {
    final isDark = AppSettings.instance.isDarkMode;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppDesign.surface(isDark),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppDesign.danger.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.delete_forever_rounded,
                color: AppDesign.danger,
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Delete Forever?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppDesign.textPrimary(isDark),
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to permanently delete this report? This action CANNOT be undone.',
          style: TextStyle(
            fontSize: 13,
            color: AppDesign.textSecondary(isDark),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: AppDesign.textSecondary(isDark),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppDesign.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Delete Forever',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CloudService.instance.permanentDeleteUserPothole(docId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Report permanently deleted.'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: AppDesign.danger,
            ),
          );
        }
      }
    }
  }

  Future<void> _confirmAndEmptyTrash(
    BuildContext context,
    List<String> docIds,
  ) async {
    if (docIds.isEmpty) return;
    final isDark = AppSettings.instance.isDarkMode;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppDesign.surface(isDark),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppDesign.danger.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.delete_sweep_rounded,
                color: AppDesign.danger,
                size: 24,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Clean Up All in Trash?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppDesign.textPrimary(isDark),
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to permanently delete all ${docIds.length} item(s) from your trash bin? This action CANNOT be undone.',
          style: TextStyle(
            fontSize: 13,
            color: AppDesign.textSecondary(isDark),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: AppDesign.textSecondary(isDark),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppDesign.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Clean Up All',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final count = await CloudService.instance.userEmptyTrash(docIds);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$count trashed item(s) permanently cleaned up.'),
              backgroundColor: const Color(0xFF10B981),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to clean up trash: $e'),
              backgroundColor: AppDesign.danger,
            ),
          );
        }
      }
    }
  }

  void _showVerificationDialog(String uid) async {
    final user = CloudService.instance.currentUser;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppDesign.surface(AppSettings.instance.isDarkMode),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: EmailVerificationView(
              backend: CloudService.instance.emailVerificationBackend,
              initialEmail: user?.email ?? '',
              fetchStatusOnMount: true,
              autoSendIfMissing: true,
              isDark: AppSettings.instance.isDarkMode,
              onVerified: () {
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Account verified successfully!'),
                    ),
                  );
                }
              },
              onSignOut: () async {
                if (ctx.mounted) Navigator.of(ctx).pop();
                await CloudService.instance.signOut();
              },
            ),
          ),
        ),
      ),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MobileSettingsSheet(
        onSettingsChanged: () {
          if (mounted) setState(() {});
        },
        onReplayTour: widget.onReplayTour,
      ),
    );
  }

  void _triggerHelpOrTour() {
    if (widget.onReplayTour != null) {
      widget.onReplayTour!.call();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => OnboardingScreen(
          isReviewMode: true,
          onComplete: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, bool isDark) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppDesign.surface(isDark),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Sign out of RoadSense AI?'),
        content: Text(
          'Any queued offline reports remain saved locally until you sign back in and sync.',
          style: TextStyle(color: AppDesign.textSecondary(isDark), height: 1.4),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(76, 48)),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(96, 48),
              backgroundColor: AppDesign.danger,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await CloudService.instance.signOut();
    }
  }

  void _resetReportFilters() {
    setState(() {
      _reportSearchController.clear();
      _reportSearchQuery = '';
      _statusFilter = 'all';
      _defectFilter = null;
    });
  }

  String _formatReportTimestamp(dynamic rawTs) {
    DateTime? dt;
    if (rawTs is Timestamp) {
      dt = rawTs.toDate().toLocal();
    } else if (rawTs is String) {
      dt = DateTime.tryParse(rawTs)?.toLocal();
    }
    if (dt == null) return 'Timestamp unavailable';
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final minStr = dt.minute.toString().padLeft(2, '0');
    const months = [
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
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} • $hour12:$minStr $amPm';
  }

  @override
  Widget build(BuildContext context) {
    final overrideUid = widget.currentUidOverride;
    final user = overrideUid == null ? CloudService.instance.currentUser : null;
    final effectiveUid = overrideUid ?? user?.uid;
    if (effectiveUid == null || effectiveUid.trim().isEmpty) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }

    final isGoogleAuth =
        user != null && CloudService.instance.isGoogleAuthUser(user);
    final bool showProfile =
        overrideUid == null &&
        (widget.section == ProfileScreenSection.all ||
            widget.section == ProfileScreenSection.profile);
    final bool showReports =
        widget.section == ProfileScreenSection.all ||
        widget.section == ProfileScreenSection.reports;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        final isDark = currentThemeMode == ThemeMode.system
            ? (MediaQuery.platformBrightnessOf(context) == Brightness.dark)
            : (currentThemeMode == ThemeMode.dark);
        final Color bgColor = AppDesign.bg(isDark);
        final Color cardBg = AppDesign.surface(isDark);
        final Color cardBorder = AppDesign.border(isDark);
        final Color textColor = AppDesign.textPrimary(isDark);
        final Color subtextColor = AppDesign.textSecondary(isDark);
        final Color accentColor = AppDesign.accent(isDark);

        final String appBarTitle =
            widget.section == ProfileScreenSection.reports
            ? 'My Reports'
            : (widget.section == ProfileScreenSection.profile
                  ? 'Profile & Settings'
                  : 'Account & Reports');
        final IconData appBarIcon =
            widget.section == ProfileScreenSection.reports
            ? Icons.assignment_rounded
            : Icons.person_rounded;

        return PopScope(
          canPop: !_isProfileDirty,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop || !_isProfileDirty) return;
            final bool? discard = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppDesign.surface(isDark),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                title: const Text('Discard unsaved profile changes?'),
                content: Text(
                  'You have unsaved edits to your profile details. Leaving now will discard them.',
                  style: TextStyle(
                    color: AppDesign.textSecondary(isDark),
                    height: 1.4,
                  ),
                ),
                actions: [
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(76, 48),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Keep Editing'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(88, 48),
                      backgroundColor: AppDesign.danger,
                      foregroundColor: Colors.white,
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Discard'),
                  ),
                ],
              ),
            );
            if (discard == true && context.mounted) {
              _discardProfileChanges();
              Navigator.of(context).maybePop();
            }
          },
          child: Scaffold(
            backgroundColor: bgColor,
            appBar: PreferredSize(
              preferredSize: const Size.fromHeight(68),
              child: Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  border: Border(
                    bottom: BorderSide(color: cardBorder, width: 1),
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                    child: Row(
                      children: [
                        RoadSenseLogo(size: 28, isDarkOverride: isDark),
                        const SizedBox(width: 10),
                        Icon(appBarIcon, color: accentColor, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            appBarTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                        ),
                        if (kIsWeb && widget.onSwitchToMap != null) ...[
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: widget.onSwitchToMap,
                            icon: const Icon(Icons.map_rounded, size: 18),
                            label: const Text('Map'),
                          ),
                          const SizedBox(width: 4),
                        ],
                        MobileTouchIconButton(
                          icon: Icons.help_outline_rounded,
                          tooltip: 'Help and app tour',
                          foregroundColor: textColor,
                          onPressed: _triggerHelpOrTour,
                        ),
                        const SizedBox(width: 8),
                        MobileTouchIconButton(
                          icon: Icons.settings_rounded,
                          tooltip: 'App settings',
                          foregroundColor: textColor,
                          onPressed: _openSettingsSheet,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            body: overrideUid != null
                ? Builder(
                    builder: (context) {
                      final media = MediaQuery.of(context);
                      final bool isMobile = media.size.width < 680;
                      final double bottomScrollPad = media.padding.bottom + 112;
                      return SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          isMobile ? 16 : 24,
                          isMobile ? 16 : 24,
                          isMobile ? 16 : 24,
                          bottomScrollPad,
                        ),
                        child: Center(
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 960),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_isOffline) ...[
                                  const MobileOfflineBanner(),
                                  const SizedBox(height: 14),
                                ],
                                if (showReports)
                                  _buildReportsSection(
                                    context: context,
                                    uid: effectiveUid,
                                    isDark: isDark,
                                    isMobile: isMobile,
                                    textColor: textColor,
                                    subtextColor: subtextColor,
                                    accentColor: accentColor,
                                    cardBg: cardBg,
                                    cardBorder: cardBorder,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(user!.uid)
                        .snapshots(),
                    builder: (context, userDocSnapshot) {
                      final userData =
                          userDocSnapshot.data?.data()
                              as Map<String, dynamic>? ??
                          {};
                      final isVerified =
                          widget.isVerifiedOverride ??
                          (isGoogleAuth || (user.emailVerified == true));
                      final docFirst =
                          userData['firstName']?.toString().trim() ?? '';
                      final docLast =
                          userData['lastName']?.toString().trim() ?? '';
                      final docPhone =
                          userData['phoneNumber']?.toString().trim() ?? '';
                      if (!_isProfileDirty &&
                          ((docFirst.isNotEmpty &&
                                  docFirst != _savedFirstName) ||
                              (docLast.isNotEmpty &&
                                  docLast != _savedLastName) ||
                              (docPhone.isNotEmpty &&
                                  docPhone != _savedPhone))) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || _isProfileDirty) return;
                          setState(() {
                            if (docFirst.isNotEmpty) {
                              _savedFirstName = docFirst;
                              _firstNameController.text = docFirst;
                            }
                            if (docLast.isNotEmpty) {
                              _savedLastName = docLast;
                              _lastNameController.text = docLast;
                            }
                            if (docPhone.isNotEmpty) {
                              _savedPhone = docPhone;
                              _phoneController.text = docPhone;
                            }
                          });
                        });
                      }

                      final media = MediaQuery.of(context);
                      final bool isMobile = media.size.width < 680;
                      final double bottomScrollPad = media.padding.bottom + 112;

                      return SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          isMobile ? 16 : 24,
                          isMobile ? 16 : 24,
                          isMobile ? 16 : 24,
                          bottomScrollPad,
                        ),
                        child: Center(
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 960),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_isOffline) ...[
                                  const MobileOfflineBanner(),
                                  const SizedBox(height: 14),
                                ],
                                if (showProfile) ...[
                                  _buildProfileSection(
                                    context: context,
                                    user: user,
                                    isDark: isDark,
                                    isMobile: isMobile,
                                    isVerified: isVerified,
                                    textColor: textColor,
                                    subtextColor: subtextColor,
                                    accentColor: accentColor,
                                    cardBorder: cardBorder,
                                  ),
                                  if (showReports) const SizedBox(height: 24),
                                ],
                                if (showReports)
                                  _buildReportsSection(
                                    context: context,
                                    uid: user.uid,
                                    isDark: isDark,
                                    isMobile: isMobile,
                                    textColor: textColor,
                                    subtextColor: subtextColor,
                                    accentColor: accentColor,
                                    cardBg: cardBg,
                                    cardBorder: cardBorder,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _buildProfileSection({
    required BuildContext context,
    required dynamic user,
    required bool isDark,
    required bool isMobile,
    required bool isVerified,
    required Color textColor,
    required Color subtextColor,
    required Color accentColor,
    required Color cardBorder,
  }) {
    final displayName = (user.displayName as String?)?.trim();
    final email = (user.email as String?)?.trim() ?? '';
    final photoUrl = user.photoURL as String?;
    final isGoogleAuth =
        (user is User) &&
        user.providerData.any((p) => p.providerId == 'google.com');
    final initialsSource = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (email.isNotEmpty ? email : 'U');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Account Overview Card
        MobileSectionCard(
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: accentColor,
                    backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                        ? NetworkImage(photoUrl)
                        : null,
                    child: (photoUrl == null || photoUrl.isEmpty)
                        ? Text(
                            initialsSource[0].toUpperCase(),
                            style: const TextStyle(
                              fontSize: 26,
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (displayName != null && displayName.isNotEmpty)
                              ? displayName
                              : 'RoadSense Contributor',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                        if (email.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            email,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: subtextColor,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        MobileStatusPill(
                          label: isVerified
                              ? 'Verified Account'
                              : 'Verification Needed',
                          icon: isVerified
                              ? Icons.verified_user_rounded
                              : Icons.gpp_maybe_rounded,
                          color: isVerified
                              ? AppDesign.success
                              : AppDesign.warning,
                          compact: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!isVerified) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppDesign.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppDesign.warning.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Verify your account email',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Verify your email address via the link sent to your inbox before sending pothole reports.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: subtextColor,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 48),
                            backgroundColor: AppDesign.warning,
                            foregroundColor: Colors.white,
                            elevation: 0,
                          ),
                          icon: const Icon(Icons.verified_user_rounded),
                          label: const Text('Verify Email'),
                          onPressed: () =>
                              _showVerificationDialog(user.uid as String),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. Personal Information Form
        MobileSectionCard(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.badge_rounded, color: accentColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Personal Details',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Keep your contact profile up to date for your reports.',
                  style: TextStyle(fontSize: 13, color: subtextColor),
                ),
                const SizedBox(height: 16),
                if (isMobile) ...[
                  TextFormField(
                    key: widget.tourTargets['details'],
                    controller: _firstNameController,
                    style: TextStyle(fontSize: 14.5, color: textColor),
                    decoration: _inputDecoration(
                      'First Name',
                      Icons.person_outline,
                      isDark: isDark,
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Enter first name'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _lastNameController,
                    style: TextStyle(fontSize: 14.5, color: textColor),
                    decoration: _inputDecoration(
                      'Last Name',
                      Icons.person_outline,
                      isDark: isDark,
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Enter last name'
                        : null,
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _firstNameController,
                          style: TextStyle(fontSize: 14.5, color: textColor),
                          decoration: _inputDecoration(
                            'First Name',
                            Icons.person_outline,
                            isDark: isDark,
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter first name'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextFormField(
                          controller: _lastNameController,
                          style: TextStyle(fontSize: 14.5, color: textColor),
                          decoration: _inputDecoration(
                            'Last Name',
                            Icons.person_outline,
                            isDark: isDark,
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter last name'
                              : null,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: email,
                  readOnly: true,
                  style: TextStyle(fontSize: 14.5, color: subtextColor),
                  decoration: _inputDecoration(
                    'Email Address',
                    Icons.email_outlined,
                    isDark: isDark,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  style: TextStyle(fontSize: 14.5, color: textColor),
                  decoration: _inputDecoration(
                    'Phone Number',
                    Icons.phone_outlined,
                    isDark: isDark,
                  ),
                ),
                const SizedBox(height: 16),
                if (_isProfileDirty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppDesign.brandWash(isDark),
                      borderRadius: BorderRadius.circular(AppDesign.radiusMd),
                      border: Border.all(color: AppDesign.brandBorder(isDark)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_note_rounded,
                          size: 18,
                          color: accentColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'You have unsaved changes.',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    if (_isProfileDirty) ...[
                      Expanded(
                        child: OutlinedButton(
                          style: AppDesign.outlinedButtonStyle(isDark: isDark),
                          onPressed: _isSaving ? null : _discardProfileChanges,
                          child: const Text('Discard'),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        style: AppDesign.primaryButtonStyle(isDark: isDark)
                            .copyWith(
                              minimumSize: const WidgetStatePropertyAll(
                                Size.fromHeight(48),
                              ),
                            ),
                        icon: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save_rounded, size: 18),
                        label: Text(
                          _isSaving ? 'Saving...' : 'Save Profile Details',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        onPressed: _isSaving
                            ? null
                            : () {
                                if (_formKey.currentState!.validate()) {
                                  _saveProfile();
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 3. Preferences, Tour & Account Actions
        MobileSectionCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              ListTile(
                key: widget.tourTargets['settings'],
                minTileHeight: 56,
                leading: Icon(Icons.tune_rounded, color: accentColor),
                title: Text(
                  'App Settings & Display',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
                subtitle: Text(
                  'Theme, high-contrast B&W, and map layers',
                  style: TextStyle(color: subtextColor, fontSize: 13),
                ),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  color: subtextColor,
                ),
                onTap: _openSettingsSheet,
              ),
              Divider(color: cardBorder, height: 1),
              ListTile(
                key: widget.tourTargets['help'],
                minTileHeight: 56,
                leading: Icon(Icons.explore_rounded, color: accentColor),
                title: Text(
                  'Help & app tour',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
                subtitle: Text(
                  'Replay interactive spotlight guide for all app tools',
                  style: TextStyle(color: subtextColor, fontSize: 13),
                ),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  color: subtextColor,
                ),
                onTap: _triggerHelpOrTour,
              ),
              if (!isGoogleAuth && email.isNotEmpty) ...[
                Divider(color: cardBorder, height: 1),
                ListTile(
                  minTileHeight: 56,
                  leading: Icon(Icons.lock_reset_rounded, color: accentColor),
                  title: Text(
                    'Reset Password',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  subtitle: Text(
                    'Send a password recovery link to $email',
                    style: TextStyle(color: subtextColor, fontSize: 13),
                  ),
                  trailing: _isSendingReset
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.chevron_right_rounded, color: subtextColor),
                  onTap: _isSendingReset
                      ? null
                      : () => _confirmAndSendPasswordReset(
                          context,
                          email,
                          isDark,
                        ),
                ),
              ],
              Divider(color: cardBorder, height: 1),
              ListTile(
                key: widget.tourTargets['signout'],
                minTileHeight: 56,
                leading: Icon(Icons.logout_rounded, color: AppDesign.danger),
                title: Text(
                  'Sign Out',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppDesign.danger,
                  ),
                ),
                subtitle: Text(
                  'Sign out on this device',
                  style: TextStyle(color: subtextColor, fontSize: 13),
                ),
                onTap: () => _confirmSignOut(context, isDark),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReportsSection({
    required BuildContext context,
    required String uid,
    required bool isDark,
    required bool isMobile,
    required Color textColor,
    required Color subtextColor,
    required Color accentColor,
    required Color cardBg,
    required Color cardBorder,
  }) {
    final Stream<List<CloudReportRecord>> cloudStream =
        widget.userReportsStreamOverride ??
        CloudService.instance
            .streamUserPotholes(uid)
            .map(
              (snapshot) =>
                  snapshot.docs.map(CloudReportRecord.fromSnapshot).toList(),
            );

    return StreamBuilder<List<CloudReportRecord>>(
      stream: cloudStream,
      builder: (context, snapshot) {
        final hasCloudError = snapshot.hasError;
        final isWaitingCloud =
            snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;

        if (hasCloudError && _localRecords.isEmpty) {
          return MobileStateCard(
            icon: Icons.error_outline_rounded,
            iconColor: AppDesign.danger,
            title: 'Unable to Load Reports',
            message:
                'Your submitted reports could not be loaded right now. Check your connection and try again.',
          );
        }
        if (isWaitingCloud && (!_localRecordsLoaded || _localRecords.isEmpty)) {
          if (_localRecords.isEmpty) {
            return MobileStateCard(
              isLoading: true,
              icon: Icons.sync_rounded,
              iconColor: accentColor,
              title: 'Loading Your Reports',
              message:
                  'Fetching your road defect submissions and review status...',
            );
          }
        }

        final cloudRecords = snapshot.data ?? const <CloudReportRecord>[];
        final merged = mergeUserReports(
          uid: uid,
          localRecords: _localRecords,
          cloudRecords: cloudRecords,
        );
        final activeItems = merged.activeItems;
        final trashedItems = merged.trashedItems;
        final filteredActiveItems = filterActiveUserReports(
          activeItems,
          statusFilter: _statusFilter,
          defectFilter: _defectFilter,
          query: _reportSearchQuery,
        );

        final bool hasFilters =
            _reportSearchQuery.trim().isNotEmpty ||
            _statusFilter != 'all' ||
            _defectFilter != null;

        final approvedCount = merged.approvedCount;
        final pendingCount = merged.pendingReviewCount;
        PendingReportRecord? firstFailed;
        for (final rec in _localRecords) {
          if (rec.uid == uid &&
              rec.syncState == PendingSyncState.failed &&
              !cloudRecords.any((c) => c.id == rec.id)) {
            firstFailed = rec;
            break;
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasCloudError && _localRecords.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppDesign.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppDesign.warning.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 18,
                      color: AppDesign.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Cloud sync unavailable right now. Showing reports saved on this device.',
                        style: TextStyle(fontSize: 12.5, color: textColor),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (merged.localQueuedCount > 0) ...[
              _buildLocalOutboxBanner(
                isDark: isDark,
                textColor: textColor,
                subtextColor: subtextColor,
                accentColor: accentColor,
                merged: merged,
                firstFailed: firstFailed,
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: AppDesign.cardDecoration(
                      isDark: isDark,
                      radius: AppDesign.radiusMd,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: subtextColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${merged.totalActiveCount}',
                          style: AppDesign.tabular(
                            TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: AppDesign.cardDecoration(
                      isDark: isDark,
                      radius: AppDesign.radiusMd,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Approved',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: subtextColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$approvedCount',
                          style: AppDesign.tabular(
                            TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: AppDesign.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: AppDesign.cardDecoration(
                      isDark: isDark,
                      radius: AppDesign.radiusMd,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pending review',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: subtextColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$pendingCount',
                          style: AppDesign.tabular(
                            TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: AppDesign.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cardBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _showTrashBin = false),
                      borderRadius: BorderRadius.circular(10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: !_showTrashBin
                                ? AppDesign.brand
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Active (${activeItems.length})',
                            key: widget.tourTargets['active'],
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: !_showTrashBin ? Colors.white : textColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _showTrashBin = true),
                      borderRadius: BorderRadius.circular(10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: _showTrashBin
                                ? AppDesign.danger
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Trash (${trashedItems.length})',
                            key: widget.tourTargets['trash'],
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: _showTrashBin ? Colors.white : textColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            if (_showTrashBin) ...[
              if (trashedItems.isEmpty)
                MobileStateCard(
                  icon: Icons.auto_delete_outlined,
                  iconColor: subtextColor,
                  title: 'Trash Bin is Empty',
                  message:
                      'Pending or rejected reports you remove appear here until permanently deleted.',
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppDesign.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppDesign.danger.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${trashedItems.length} trashed report${trashedItems.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(120, 48),
                          backgroundColor: AppDesign.danger,
                          foregroundColor: Colors.white,
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: const Text('Empty Trash'),
                        onPressed: () => _confirmAndEmptyTrash(
                          context,
                          trashedItems.map((d) => d.id).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                for (final item in trashedItems) ...[
                  _buildTrashedReportCard(
                    context: context,
                    item: item,
                    isDark: isDark,
                    textColor: textColor,
                    subtextColor: subtextColor,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ] else ...[
              TextField(
                key: widget.tourTargets['search'],
                controller: _reportSearchController,
                style: TextStyle(fontSize: 14.5, color: textColor),
                decoration: InputDecoration(
                  hintText: 'Search defect type or barangay...',
                  prefixIcon: Icon(Icons.search_rounded, color: accentColor),
                  suffixIcon: _reportSearchQuery.isNotEmpty
                      ? IconButton(
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () => setState(() {
                            _reportSearchController.clear();
                            _reportSearchQuery = '';
                          }),
                        )
                      : null,
                ),
                onChanged: (v) => setState(() => _reportSearchQuery = v),
              ),
              const SizedBox(height: 10),

              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in [
                      ('all', 'All Status'),
                      if (merged.localQueuedCount > 0 ||
                          _statusFilter == 'local')
                        ('local', 'On Device (${merged.localQueuedCount})'),
                      ('pending', 'Pending Review'),
                      ('approved', 'Approved Live'),
                      ('rejected', 'Rejected'),
                    ]) ...[
                      ChoiceChip(
                        key: entry.$1 == 'all'
                            ? widget.tourTargets['status']
                            : null,
                        selected: _statusFilter == entry.$1,
                        label: Text(entry.$2),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected: (_) =>
                            setState(() => _statusFilter = entry.$1),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 6),

              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      selected: _defectFilter == null,
                      label: const Text('All Defects'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (_) => setState(() => _defectFilter = null),
                    ),
                    const SizedBox(width: 8),
                    for (final cls in DpwhStandards.allClasses) ...[
                      ChoiceChip(
                        selected: _defectFilter == cls.name,
                        avatar: Icon(
                          MobileDefectHelper.iconForClass(cls),
                          size: 16,
                          color: MobileDefectHelper.foregroundColor(
                            cls,
                            isDark,
                          ),
                        ),
                        label: Text(cls.name),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected: (selected) => setState(
                          () => _defectFilter = selected ? cls.name : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),

              if (activeItems.isEmpty)
                MobileStateCard(
                  icon: Icons.add_a_photo_rounded,
                  iconColor: accentColor,
                  title: 'No Submitted Reports Yet',
                  message:
                      'Scan roads for potholes, alligator cracks, longitudinal cracks, or transverse cracks and submit a report for review.',
                  primaryLabel: widget.onOpenScan != null
                      ? 'Open Road Scanner'
                      : null,
                  onPrimaryPressed: widget.onOpenScan,
                )
              else if (filteredActiveItems.isEmpty && hasFilters)
                MobileStateCard(
                  icon: Icons.filter_alt_off_rounded,
                  iconColor: accentColor,
                  title: 'No Matching Reports',
                  message:
                      'No submitted reports match your search or selected status/defect filters.',
                  primaryLabel: 'Reset Filters',
                  onPrimaryPressed: _resetReportFilters,
                )
              else
                for (final item in filteredActiveItems) ...[
                  if (item.isLocal)
                    _buildLocalReportCard(
                      context: context,
                      record: item.localRecord!,
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                    )
                  else
                    _buildActiveReportCard(
                      context: context,
                      item: item,
                      isDark: isDark,
                      textColor: textColor,
                      subtextColor: subtextColor,
                      accentColor: accentColor,
                    ),
                  const SizedBox(height: 12),
                ],
            ],
          ],
        );
      },
    );
  }

  Widget _buildLocalOutboxBanner({
    required bool isDark,
    required Color textColor,
    required Color subtextColor,
    required Color accentColor,
    required MergedUserReports merged,
    required PendingReportRecord? firstFailed,
  }) {
    final hasFailure = merged.localFailedCount > 0;
    final tint = hasFailure ? AppDesign.danger : accentColor;
    final title = hasFailure
        ? '${merged.localFailedCount} report${merged.localFailedCount == 1 ? '' : 's'} failed to upload'
        : merged.localUploadingCount > 0
        ? 'Uploading ${merged.localUploadingCount} queued report${merged.localUploadingCount == 1 ? '' : 's'}...'
        : '${merged.localQueuedCount} report${merged.localQueuedCount == 1 ? '' : 's'} waiting to upload';
    final detail = hasFailure
        ? (firstFailed?.errorMessage ??
              'Retry once connectivity or backend configuration is ready.')
        : 'Saved safely on this device and queued for submission.';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: isDark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tint.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            hasFailure
                ? Icons.cloud_off_rounded
                : merged.localUploadingCount > 0
                ? Icons.cloud_upload_rounded
                : Icons.schedule_send_rounded,
            color: tint,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(fontSize: 12.5, color: subtextColor),
                ),
              ],
            ),
          ),
          if (widget.onRetryPendingReports != null) ...[
            const SizedBox(width: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(88, 44),
                backgroundColor: tint,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              icon: _isRetryingQueue
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 17),
              label: Text(_isRetryingQueue ? 'Retrying' : 'Retry'),
              onPressed: _isRetryingQueue ? null : () => _triggerPendingRetry(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReportThumbnail(
    String imageUrl,
    bool isDark, {
    String? localImagePath,
  }) {
    final hasLocalFile =
        !kIsWeb &&
        localImagePath != null &&
        localImagePath.isNotEmpty &&
        File(localImagePath).existsSync();

    return Container(
      width: 86,
      height: 86,
      decoration: BoxDecoration(
        color: AppDesign.bg(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppDesign.border(isDark)),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasLocalFile
          ? Image.file(
              File(localImagePath),
              fit: BoxFit.cover,
              cacheWidth: 280,
              errorBuilder: (_, _, _) => Icon(
                Icons.broken_image_outlined,
                color: AppDesign.textMuted(isDark),
              ),
            )
          : imageUrl.startsWith('http')
          ? Image.network(
              imageUrl,
              fit: BoxFit.cover,
              cacheWidth: 280,
              errorBuilder: (_, _, _) => Icon(
                Icons.broken_image_outlined,
                color: AppDesign.textMuted(isDark),
              ),
            )
          : Icon(
              Icons.photo_camera_back_rounded,
              color: AppDesign.textMuted(isDark),
            ),
    );
  }

  Widget _buildLocalReportCard({
    required BuildContext context,
    required PendingReportRecord record,
    required bool isDark,
    required Color textColor,
    required Color subtextColor,
  }) {
    final data = record.report;
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0.0;
    final defectName = DpwhStandards.reportDefectName(data);
    final cls = DpwhStandards.classify(defectName);
    final count = (data['potholeCount'] as num?)?.toInt() ?? 1;

    final address = [
      data['barangay'] as String? ?? '',
      data['city'] as String? ?? '',
    ].where((s) => s.trim().isNotEmpty).join(', ');
    final timestampLabel = _formatReportTimestamp(record.createdAt);
    final statusMeta = MobileStatusMeta.forLocalSyncState(
      record.syncState,
      isDark,
    );
    final isFailed = record.syncState == PendingSyncState.failed;
    final isUploading = record.syncState == PendingSyncState.uploading;
    final isMissingPhoto =
        record.errorCategory == ReportUploadErrorCategory.missingImage ||
        (!record.hasLocalImage && record.uploadedImageUrl == null);

    return MobileSectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _showReportDetailsSheet(
                  context: context,
                  docId: record.id,
                  data: {
                    ...data,
                    'status': record.syncState.name,
                    if (record.uploadedImageUrl != null)
                      'imageUrl': record.uploadedImageUrl,
                  },
                  localRecord: record,
                ),
                child: _buildReportThumbnail(
                  record.uploadedImageUrl ?? '',
                  isDark,
                  localImagePath: record.imagePath,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        MobileDefectPill(defectClass: cls, showCode: true),
                        MobileStatusPill(
                          label: statusMeta.label,
                          icon: statusMeta.icon,
                          color: statusMeta.color,
                          backgroundColor: statusMeta.backgroundColor,
                          borderColor: statusMeta.borderColor,
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      address.isNotEmpty
                          ? address
                          : '${lat.toStringAsFixed(5)}°, ${lng.toStringAsFixed(5)}°',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$count ${count == 1 ? 'defect' : 'defects'} • $timestampLabel',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: subtextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isFailed || isUploading) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: statusMeta.backgroundColor ?? AppDesign.sunken(isDark),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: statusMeta.borderColor ?? AppDesign.border(isDark),
                ),
              ),
              child: Text(
                isUploading
                    ? 'Uploading report photo and saving to review queue...'
                    : '${record.errorCategory?.title ?? 'Upload failed'}: ${record.errorMessage ?? 'Tap Retry to upload.'}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: statusMeta.color,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppDesign.brand,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(110, 48),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.info_outline_rounded, size: 17),
                label: const Text('Details'),
                onPressed: () => _showReportDetailsSheet(
                  context: context,
                  docId: record.id,
                  data: {
                    ...data,
                    'status': record.syncState.name,
                    if (record.uploadedImageUrl != null)
                      'imageUrl': record.uploadedImageUrl,
                  },
                  localRecord: record,
                ),
              ),
              if (widget.onRetryPendingReports != null && !isMissingPhoto)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(112, 48),
                    foregroundColor: isFailed
                        ? AppDesign.danger
                        : AppDesign.brand,
                    side: BorderSide(
                      color: (isFailed ? AppDesign.danger : AppDesign.brand)
                          .withValues(alpha: 0.6),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: isUploading || _isRetryingQueue
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(isFailed ? 'Retry' : 'Upload Now'),
                  onPressed: isUploading || _isRetryingQueue
                      ? null
                      : () => _triggerPendingRetry(targetId: record.id),
                )
              else if (isMissingPhoto && widget.onOpenScan != null)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(124, 48),
                    foregroundColor: AppDesign.warning,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.add_a_photo_rounded, size: 17),
                  label: const Text('New Scan'),
                  onPressed: widget.onOpenScan,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActiveReportCard({
    required BuildContext context,
    required UserReportListItem item,
    required bool isDark,
    required Color textColor,
    required Color subtextColor,
    required Color accentColor,
  }) {
    final data = item.data;
    final imageUrl = data['imageUrl'] as String? ?? '';
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0.0;
    final status = (data['status'] as String? ?? 'pending').toLowerCase();
    final isApproved = status == 'approved';
    final defectName = DpwhStandards.reportDefectName(data);
    final cls = DpwhStandards.classify(defectName);
    final count = (data['potholeCount'] as num?)?.toInt() ?? 1;

    final address = [
      data['barangay'] as String? ?? '',
      data['city'] as String? ?? '',
    ].where((s) => s.trim().isNotEmpty).join(', ');
    final timestampLabel = _formatReportTimestamp(data['timestamp']);

    return MobileSectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _showReportDetailsSheet(
                  context: context,
                  docId: item.id,
                  data: data,
                ),
                child: _buildReportThumbnail(imageUrl, isDark),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        MobileDefectPill(defectClass: cls, showCode: true),
                        MobileStatusPill.forReportStatus(
                          status,
                          isDark: isDark,
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      address.isNotEmpty
                          ? address
                          : '${lat.toStringAsFixed(5)}°, ${lng.toStringAsFixed(5)}°',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$count ${count == 1 ? 'defect' : 'defects'} • $timestampLabel',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: subtextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppDesign.brand,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(110, 48),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.info_outline_rounded, size: 17),
                label: const Text('Details'),
                onPressed: () => _showReportDetailsSheet(
                  context: context,
                  docId: item.id,
                  data: data,
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(124, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.map_rounded, size: 17),
                label: const Text('On Map'),
                onPressed: () {
                  if (widget.onLocateOnMap != null) {
                    widget.onLocateOnMap!(LatLng(lat, lng), item.id, data);
                  } else {
                    widget.onSwitchToMap?.call();
                  }
                },
              ),
              if (!isApproved) ...[
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(88, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.edit_note_rounded, size: 17),
                  label: const Text('Edit'),
                  onPressed: () =>
                      _showEditReportDialog(context, item.id, data),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(88, 48),
                    foregroundColor: AppDesign.danger,
                    side: BorderSide(
                      color: AppDesign.danger.withValues(alpha: 0.55),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: const Text('Trash'),
                  onPressed: () => _confirmAndMoveToTrash(context, item.id),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrashedReportCard({
    required BuildContext context,
    required UserReportListItem item,
    required bool isDark,
    required Color textColor,
    required Color subtextColor,
  }) {
    final data = item.data;
    final imageUrl = data['imageUrl'] as String? ?? '';
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0.0;
    final cls = DpwhStandards.classify(DpwhStandards.reportDefectName(data));

    return MobileSectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildReportThumbnail(imageUrl, isDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        MobileDefectPill(defectClass: cls),
                        MobileStatusPill.forReportStatus(
                          'deleted',
                          isDark: isDark,
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${lat.toStringAsFixed(5)}°, ${lng.toStringAsFixed(5)}°',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatReportTimestamp(data['timestamp']),
                      style: TextStyle(fontSize: 12, color: subtextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(120, 48),
                  backgroundColor: AppDesign.accent(isDark),
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
                icon: const Icon(Icons.restore_from_trash_rounded, size: 17),
                label: const Text('Restore'),
                onPressed: () => _restoreReport(context, item.id),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(136, 48),
                  foregroundColor: AppDesign.danger,
                  side: BorderSide(color: AppDesign.danger),
                ),
                icon: const Icon(Icons.delete_forever_rounded, size: 17),
                label: const Text('Delete Forever'),
                onPressed: () => _confirmAndPermanentDelete(context, item.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showReportDetailsSheet({
    required BuildContext context,
    required String docId,
    required Map<String, dynamic> data,
    PendingReportRecord? localRecord,
  }) {
    final isDark = AppSettings.instance.isDarkMode;
    final textColor = AppDesign.textPrimary(isDark);
    final subtextColor = AppDesign.textSecondary(isDark);
    final status = (data['status'] as String? ?? 'pending').toLowerCase();
    final isApproved = localRecord == null && status == 'approved';
    final imageUrl =
        localRecord?.uploadedImageUrl ?? (data['imageUrl'] as String? ?? '');
    final localImagePath = localRecord?.imagePath;
    final hasLocalFile =
        !kIsWeb &&
        localImagePath != null &&
        localImagePath.isNotEmpty &&
        File(localImagePath).existsSync();
    final hasRemoteImage = imageUrl.startsWith('http');
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0.0;
    final cls = DpwhStandards.classify(DpwhStandards.reportDefectName(data));
    final detections =
        (data['detections'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];
    final address = (data['formattedAddress'] as String?)?.trim() ?? '';

    final int stageIndex = localRecord != null ? 1 : (isApproved ? 3 : 2);
    final localMeta = localRecord != null
        ? MobileStatusMeta.forLocalSyncState(localRecord.syncState, isDark)
        : null;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.78,
          minChildSize: 0.48,
          maxChildSize: 0.94,
          builder: (_, scrollController) => Container(
            decoration: BoxDecoration(
              color: AppDesign.surface(isDark),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border.all(color: AppDesign.border(isDark)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppDesign.border(isDark),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Report Details',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                      ),
                      MobileTouchIconButton(
                        icon: Icons.close_rounded,
                        tooltip: 'Close report details',
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(color: AppDesign.border(isDark), height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: EdgeInsets.fromLTRB(
                      18,
                      16,
                      18,
                      MediaQuery.paddingOf(sheetCtx).bottom + 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasLocalFile || hasRemoteImage) ...[
                          GestureDetector(
                            onTap: () {
                              showDialog<void>(
                                context: sheetCtx,
                                builder: (zoomCtx) => Dialog.fullscreen(
                                  backgroundColor: Colors.black,
                                  child: Stack(
                                    children: [
                                      InteractiveViewer(
                                        minScale: 1.0,
                                        maxScale: 4.5,
                                        child: Center(
                                          child: hasLocalFile
                                              ? Image.file(
                                                  File(localImagePath),
                                                  fit: BoxFit.contain,
                                                )
                                              : Image.network(
                                                  imageUrl,
                                                  fit: BoxFit.contain,
                                                ),
                                        ),
                                      ),
                                      SafeArea(
                                        child: Align(
                                          alignment: Alignment.topRight,
                                          child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: IconButton(
                                              style: IconButton.styleFrom(
                                                backgroundColor: Colors.black
                                                    .withValues(alpha: 0.72),
                                                foregroundColor: Colors.white,
                                                minimumSize: const Size(48, 48),
                                              ),
                                              icon: const Icon(
                                                Icons.close_rounded,
                                              ),
                                              tooltip: 'Close image zoom',
                                              onPressed: () =>
                                                  Navigator.of(zoomCtx).pop(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: hasLocalFile
                                      ? Image.file(
                                          File(localImagePath),
                                          height: 210,
                                          width: double.infinity,
                                          fit: BoxFit.cover,
                                        )
                                      : Image.network(
                                          imageUrl,
                                          height: 210,
                                          width: double.infinity,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                                Positioned(
                                  right: 10,
                                  bottom: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.78,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        AppDesign.radiusPill,
                                      ),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.zoom_in_rounded,
                                          size: 14,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'Tap to zoom',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            MobileDefectPill(defectClass: cls, showCode: true),
                            if (localMeta != null)
                              MobileStatusPill(
                                label: localMeta.label,
                                icon: localMeta.icon,
                                color: localMeta.color,
                                backgroundColor: localMeta.backgroundColor,
                                borderColor: localMeta.borderColor,
                              )
                            else
                              MobileStatusPill.forReportStatus(
                                status,
                                isDark: isDark,
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        MobileReportLifecycleBanner(activeStage: stageIndex),
                        const SizedBox(height: 10),
                        Text(
                          localRecord != null
                              ? (localRecord.syncState ==
                                        PendingSyncState.failed
                                    ? '${localRecord.errorCategory?.title ?? 'Upload failed'}: ${localRecord.errorMessage ?? 'Tap Retry Upload to submit for admin review.'}'
                                    : localRecord.syncState ==
                                          PendingSyncState.uploading
                                    ? 'Uploading photo and creating your submission for admin review.'
                                    : 'Saved on this device (${localRecord.syncState.label}). Will upload for admin review when ready.')
                              : isApproved
                              ? 'Approved by admin and visible on the public road hazard map.'
                              : status == 'rejected'
                              ? 'Not approved for public display.'
                              : 'Submitted and saved under Pending Review until an administrator approves it.',
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.4,
                            color:
                                localRecord?.syncState ==
                                    PendingSyncState.failed
                                ? AppDesign.danger
                                : subtextColor,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Location & Standards',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          address.isNotEmpty
                              ? address
                              : '${lat.toStringAsFixed(5)}°, ${lng.toStringAsFixed(5)}°',
                          style: TextStyle(fontSize: 13.5, color: textColor),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'DPWH Response Target: ${cls.responseTime} • ${cls.correctiveMeasure}',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: subtextColor,
                          ),
                        ),
                        if (detections.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            'AI Detections (${detections.length})',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: detections.map((d) {
                              final detCls = DpwhStandards.classify(
                                d['tag']?.toString() ??
                                    d['defectType']?.toString(),
                              );
                              final conf =
                                  (d['confidence'] as num?)?.toDouble() ??
                                  (d['box'] is List &&
                                          (d['box'] as List).length > 4
                                      ? ((d['box'] as List)[4] as num?)
                                            ?.toDouble()
                                      : null);
                              return MobileDefectPill(
                                defectClass: detCls,
                                confidence: conf,
                              );
                            }).toList(),
                          ),
                        ],

                        const SizedBox(height: 20),
                        if (localRecord != null) ...[
                          if (widget.onRetryPendingReports != null &&
                              localRecord.errorCategory !=
                                  ReportUploadErrorCategory.missingImage &&
                              (localRecord.hasLocalImage ||
                                  localRecord.uploadedImageUrl != null))
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 48),
                                  backgroundColor:
                                      localRecord.syncState ==
                                          PendingSyncState.failed
                                      ? AppDesign.danger
                                      : AppDesign.brand,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppDesign.radiusMd,
                                    ),
                                  ),
                                ),
                                icon: const Icon(Icons.refresh_rounded),
                                label: Text(
                                  localRecord.syncState ==
                                          PendingSyncState.failed
                                      ? 'Retry Upload'
                                      : 'Upload Now',
                                ),
                                onPressed: () {
                                  Navigator.of(sheetCtx).pop();
                                  _triggerPendingRetry(
                                    targetId: localRecord.id,
                                  );
                                },
                              ),
                            ),
                        ] else
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(double.infinity, 48),
                                backgroundColor: AppDesign.brand,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppDesign.radiusMd,
                                  ),
                                ),
                              ),
                              icon: const Icon(Icons.map_rounded),
                              label: const Text('View Location on Map'),
                              onPressed: () {
                                Navigator.of(sheetCtx).pop();
                                if (widget.onLocateOnMap != null) {
                                  widget.onLocateOnMap!(
                                    LatLng(lat, lng),
                                    docId,
                                    data,
                                  );
                                } else {
                                  widget.onSwitchToMap?.call();
                                }
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  InputDecoration _inputDecoration(
    String label,
    IconData icon, {
    Widget? suffixIcon,
    bool isDark = false,
  }) {
    return AppDesign.inputDecoration(
      label: label,
      icon: icon,
      suffixIcon: suffixIcon,
      isDark: isDark,
    );
  }
}

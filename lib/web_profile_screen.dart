import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'app_settings.dart';
import 'cloud_service.dart';
import 'dpwh_standards.dart';
import 'email_verification_view.dart';
import 'road_hazard_marker.dart';
import 'settings_dialog.dart';
import 'web_components.dart';
import 'web_design.dart';
import 'web_report_query.dart';

/// Public/user Surveyor workspace hosting both **My Reports** (history, status,
/// search/filter, edit/trash/restore) and **Account & Security** (identity,
/// personal details form with unsaved-changes guard, password reset, theme).
class ProfileScreen extends StatefulWidget {
  final VoidCallback? onSwitchToMap;
  final Function(LatLng location, String? docId, Map<String, dynamic>? data)?
  onLocateOnMap;
  final bool embeddedInShell;
  final WebShellRoute activeRoute;
  final ValueChanged<WebShellRoute>? onNavigateRoute;
  final ValueChanged<bool>? onUnsavedChangesChanged;
  final VoidCallback? onOpenHelp;
  final VoidCallback? onOpenSettings;

  const ProfileScreen({
    super.key,
    this.onSwitchToMap,
    this.onLocateOnMap,
    this.embeddedInShell = false,
    this.activeRoute = WebShellRoute.reports,
    this.onNavigateRoute,
    this.onUnsavedChangesChanged,
    this.onOpenHelp,
    this.onOpenSettings,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const int _reportsPerPage = 20;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _phoneController;
  final TextEditingController _reportSearch = TextEditingController();

  String _savedFirstName = '';
  String _savedLastName = '';
  String _savedPhone = '';
  bool _hasUnsavedChanges = false;
  bool _isSaving = false;
  bool _isSendingPasswordReset = false;
  String? _passwordResetMessage;
  String? _passwordResetError;

  late WebShellRoute _localRoute;
  bool _showTrashBin = false;
  String _reportStatus = 'all';
  String _selectedDefectClass = 'all';
  WebReportSort _reportSort = WebReportSort.newest;
  int _currentPage = 0;
  int _streamRetryNonce = 0;

  @override
  void initState() {
    super.initState();
    _localRoute = widget.activeRoute == WebShellRoute.account
        ? WebShellRoute.account
        : WebShellRoute.reports;
    final user = CloudService.instance.currentUser;
    final nameParts = (user?.displayName ?? '').trim().isEmpty
        ? <String>[]
        : user!.displayName!.trim().split(RegExp(r'\s+'));
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

    _firstNameController.addListener(_syncUnsavedFlag);
    _lastNameController.addListener(_syncUnsavedFlag);
    _phoneController.addListener(_syncUnsavedFlag);

    if (user != null) {
      FirebaseFirestore.instance.collection('users').doc(user.uid).get().then((
        doc,
      ) {
        if (!doc.exists ||
            doc.data() == null ||
            !mounted ||
            _hasUnsavedChanges) {
          return;
        }
        final data = doc.data()!;
        final f = (data['firstName'] ?? '').toString().trim();
        final l = (data['lastName'] ?? '').toString().trim();
        final p = (data['phoneNumber'] ?? '').toString().trim();
        if (f.isNotEmpty) {
          _savedFirstName = f;
          _firstNameController.text = f;
        }
        if (l.isNotEmpty) {
          _savedLastName = l;
          _lastNameController.text = l;
        }
        if (p.isNotEmpty) {
          _savedPhone = p;
          _phoneController.text = p;
        }
        _syncUnsavedFlag();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeRoute != widget.activeRoute) {
      _localRoute = widget.activeRoute == WebShellRoute.account
          ? WebShellRoute.account
          : WebShellRoute.reports;
    }
  }

  @override
  void dispose() {
    _reportSearch.dispose();
    _firstNameController.removeListener(_syncUnsavedFlag);
    _lastNameController.removeListener(_syncUnsavedFlag);
    _phoneController.removeListener(_syncUnsavedFlag);
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _syncUnsavedFlag() {
    final dirty =
        _firstNameController.text.trim() != _savedFirstName.trim() ||
        _lastNameController.text.trim() != _savedLastName.trim() ||
        _phoneController.text.trim() != _savedPhone.trim();
    if (dirty != _hasUnsavedChanges) {
      if (mounted) {
        setState(() => _hasUnsavedChanges = dirty);
      } else {
        _hasUnsavedChanges = dirty;
      }
      widget.onUnsavedChangesChanged?.call(dirty);
    }
  }

  void _resetUnsavedEdits() {
    _firstNameController.text = _savedFirstName;
    _lastNameController.text = _savedLastName;
    _phoneController.text = _savedPhone;
    _formKey.currentState?.validate();
    _syncUnsavedFlag();
  }

  Future<void> _switchSection(WebShellRoute target) async {
    if (widget.onNavigateRoute != null) {
      widget.onNavigateRoute!(target);
      return;
    }
    if (target == WebShellRoute.map) {
      widget.onSwitchToMap?.call();
      return;
    }
    setState(() => _localRoute = target);
  }

  Future<void> _saveProfile() async {
    final user = CloudService.instance.currentUser;
    if (user == null) return;
    if (!_formKey.currentState!.validate()) return;

    final first = _firstNameController.text.trim();
    final last = _lastNameController.text.trim();
    final phone = _phoneController.text.trim();

    setState(() => _isSaving = true);
    try {
      await CloudService.instance.updateUserProfileDetails(
        uid: user.uid,
        firstName: first,
        lastName: last,
        phoneNumber: phone,
      );
      if (!mounted) return;
      _savedFirstName = first;
      _savedLastName = last;
      _savedPhone = phone;
      _syncUnsavedFlag();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile information updated successfully.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update profile: $e'),
          backgroundColor: WebDesign.danger(
            Theme.of(context).brightness == Brightness.dark,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _sendPasswordReset(String email) async {
    if (email.trim().isEmpty) return;
    setState(() {
      _isSendingPasswordReset = true;
      _passwordResetMessage = null;
      _passwordResetError = null;
    });
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
      if (!mounted) return;
      setState(() {
        _isSendingPasswordReset = false;
        _passwordResetMessage =
            'Password reset instructions sent to ${email.trim()}. Check your inbox and spam folder.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSendingPasswordReset = false;
        _passwordResetError =
            'Could not send password reset email: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  Future<void> _confirmAndMoveToTrash(
    BuildContext context,
    String docId,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Trash?'),
        content: const Text(
          'Move this pending report to your Trash Bin? You can restore or permanently clean it up anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CloudService.instance.userSoftDeletePothole(docId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Report moved to Trash Bin.')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error moving report to trash: $e')),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    int potholeCount = ((data['potholeCount'] as num?)?.toInt() ?? 1).clamp(
      1,
      100,
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Report'),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 380,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),
                      InputDecorator(
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: const SizedBox.shrink(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Road defects detected in image',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          IconButton.outlined(
                            tooltip: 'Decrease defect count',
                            icon: const Icon(Icons.remove, size: 16),
                            onPressed: potholeCount > 1
                                ? () => setDialogState(() => potholeCount--)
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              '$potholeCount',
                              style: WebDesign.tabular(
                                TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: WebDesign.textPrimary(isDark),
                                ),
                              ),
                            ),
                          ),
                          IconButton.outlined(
                            tooltip: 'Increase defect count',
                            icon: const Icon(Icons.add, size: 16),
                            onPressed: potholeCount < 100
                                ? () => setDialogState(() => potholeCount++)
                                : null,
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
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    try {
                      await CloudService.instance.editPothole(
                        docId,

                        potholeCount: potholeCount,
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Report updated successfully.'),
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Update failed: $e'),
                            backgroundColor: WebDesign.danger(isDark),
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
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to restore: $e')));
      }
    }
  }

  Future<void> _confirmAndPermanentDelete(
    BuildContext context,
    String docId,
  ) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Forever?'),
        content: const Text(
          'Are you sure you want to permanently delete this report? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: WebDesign.danger(isDark),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CloudService.instance.permanentDeleteUserPothole(docId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Report permanently deleted.')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
        }
      }
    }
  }

  Future<void> _confirmAndEmptyTrash(
    BuildContext context,
    List<String> docIds,
  ) async {
    if (docIds.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clean Up All in Trash?'),
        content: Text(
          'Are you sure you want to permanently delete all ${docIds.length} item(s) from your trash bin? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: WebDesign.danger(isDark),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clean Up All'),
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
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to clean up trash: $e')),
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
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: EmailVerificationView(
              backend: CloudService.instance.emailVerificationBackend,
              initialEmail: user?.email ?? '',
              fetchStatusOnMount: true,
              autoSendIfMissing: true,
              isDark: Theme.of(context).brightness == Brightness.dark,
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

  void _openFullPhotoPreview(String imageUrl) {
    if (imageUrl.trim().isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black.withValues(alpha: 0.94),
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                imageUrl,
                fit: BoxFit.contain,
                loadingBuilder: (c, child, prog) {
                  if (prog == null) return child;
                  return const SizedBox(
                    width: 240,
                    height: 180,
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  );
                },
                errorBuilder: (c, e, st) => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 56,
                      ),
                      SizedBox(height: 10),
                      Text(
                        'Photo unavailable.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  tooltip: 'Close photo',
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  WebReportItem _docToWebReportItem(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? const {};
    final lat = (data['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (data['longitude'] as num?)?.toDouble() ?? 0.0;
    final dpwhCode = (data['primaryDpwhCode'] as String? ?? 'CODE 01').trim();
    final defectClass =
        DpwhStandards.classForReport(data) ??
        DpwhStandards.classifyByCode(dpwhCode);
    DateTime ts = DateTime.now();
    final rawTs = data['timestamp'];
    if (rawTs is Timestamp) {
      ts = rawTs.toDate();
    } else if (rawTs is int) {
      ts = DateTime.fromMillisecondsSinceEpoch(rawTs);
    }

    return WebReportItem(
      docId: doc.id,
      location: LatLng(lat, lng),
      imageUrl: (data['imageUrl'] as String? ?? '').trim(),
      timestamp: ts,
      status: (data['status'] as String? ?? 'pending').trim().toLowerCase(),
      severity: (data['overallSeverity'] as String? ?? 'medium')
          .trim()
          .toLowerCase(),
      potholeCount: (data['potholeCount'] as num?)?.toInt() ?? 1,
      primaryDefect: DpwhStandards.reportDefectName(data),
      primaryDpwhCode: dpwhCode,
      responseTime:
          (data['responseTime'] as String? ?? defectClass.responseTime).trim(),
      correctiveMeasure:
          (data['correctiveMeasure'] as String? ??
                  defectClass.correctiveMeasure)
              .trim(),
      barangay: (data['barangay'] as String? ?? '').trim(),
      city: (data['city'] as String? ?? '').trim(),
      province: (data['province'] as String? ?? '').trim(),
      formattedAddress: (data['formattedAddress'] as String? ?? '').trim(),
      note: (data['note'] as String? ?? '').trim(),
      rejectionReason: (data['rejectionReason'] as String? ?? '').trim(),
      reporterUid: (data['reporterUid'] as String? ?? '').trim(),
      detections:
          (data['detections'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList(growable: false) ??
          const [],
      lastEditedAt: (data['lastEditedAt'] as Timestamp?)?.toDate(),
      moderatedAt: (data['moderatedAt'] as Timestamp?)?.toDate(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = CloudService.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(
          child: Text('Sign in to access your reports and account.'),
        ),
      );
    }

    final isGoogleAuth = CloudService.instance.isGoogleAuthUser(user);
    final activeSection = widget.embeddedInShell
        ? (widget.activeRoute == WebShellRoute.account
              ? WebShellRoute.account
              : WebShellRoute.reports)
        : _localRoute;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, _, _) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final media = MediaQuery.of(context);
        final width = media.size.width;
        final isPhoneLandscape =
            media.size.width > media.size.height && media.size.height < 560;
        final isCompact = width < 700 || isPhoneLandscape;

        return Scaffold(
          backgroundColor: WebDesign.bg(isDark),
          appBar: widget.embeddedInShell
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(WebDesign.headerHeight),
                  child: Container(
                    decoration: BoxDecoration(
                      color: WebDesign.surface(isDark),
                      border: Border(
                        bottom: BorderSide(color: WebDesign.border(isDark)),
                      ),
                    ),
                    child: CenteredMaxWidth(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: WebDesign.space4,
                        ),
                        child: Row(
                          children: [
                            Text(
                              'RoadSense',
                              style: theme.textTheme.titleMedium,
                            ),
                            const Spacer(),
                            WebViewSwitcher(
                              isMapActive: false,
                              showLiveIndicator: false,
                              onSelectMap: widget.onSwitchToMap,
                              onOpenSettings: () {
                                showDialog<void>(
                                  context: context,
                                  builder: (_) => WebSettingsDialog(
                                    onSettingsChanged: () => setState(() {}),
                                    onPlacePinOnMap: widget.onSwitchToMap,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          body: StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .snapshots(),
            builder: (context, userDocSnapshot) {
              final userData =
                  userDocSnapshot.data?.data() as Map<String, dynamic>? ??
                  const {};
              final role = (userData['role'] as String? ?? 'user').trim();
              final isVerified = isGoogleAuth || user.emailVerified;

              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  (isCompact ? WebDesign.space3 : WebDesign.space6) +
                      media.padding.left,
                  isPhoneLandscape
                      ? WebDesign.space3
                      : (isCompact ? WebDesign.space4 : WebDesign.space6),
                  (isCompact ? WebDesign.space3 : WebDesign.space6) +
                      media.padding.right,
                  (isPhoneLandscape
                          ? WebDesign.space4
                          : (isCompact ? WebDesign.space4 : WebDesign.space6)) +
                      media.padding.bottom,
                ),
                child: CenteredMaxWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPageTopStrip(
                        context: context,
                        isDark: isDark,
                        activeSection: activeSection,
                      ),
                      const SizedBox(height: WebDesign.space4),
                      if (activeSection == WebShellRoute.account)
                        _buildAccountView(
                          context: context,
                          isDark: isDark,
                          isCompact: isCompact,
                          user: user,
                          role: role,
                          isVerified: isVerified,
                          isGoogleAuth: isGoogleAuth,
                        )
                      else
                        _buildMyReportsView(
                          context: context,
                          isDark: isDark,
                          isCompact: isCompact,
                          width: width,
                          uid: user.uid,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildPageTopStrip({
    required BuildContext context,
    required bool isDark,
    required WebShellRoute activeSection,
  }) {
    final theme = Theme.of(context);
    final isReports = activeSection == WebShellRoute.reports;
    return Wrap(
      spacing: WebDesign.space3,
      runSpacing: WebDesign.space2,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(
              isReports
                  ? 'SURVEY HISTORY & MODERATION'
                  : 'IDENTITY, SECURITY & PREFERENCES',
            ),
            const SizedBox(height: 2),
            Text(
              isReports ? 'My Road Reports' : 'Account & Security',
              style: theme.textTheme.headlineMedium,
            ),
          ],
        ),
        Wrap(
          spacing: WebDesign.space2,
          runSpacing: WebDesign.space2,
          children: [
            OutlinedButton.icon(
              onPressed: () => unawaited(
                _switchSection(
                  isReports ? WebShellRoute.account : WebShellRoute.reports,
                ),
              ),
              icon: Icon(
                isReports
                    ? Icons.manage_accounts_outlined
                    : Icons.assignment_outlined,
                size: 16,
              ),
              label: Text(isReports ? 'Profile' : 'My Reports'),
            ),
            if (widget.onSwitchToMap != null)
              ElevatedButton.icon(
                onPressed: widget.onSwitchToMap,
                icon: const Icon(Icons.map_outlined, size: 16),
                label: const Text('Back to Map'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildAccountView({
    required BuildContext context,
    required bool isDark,
    required bool isCompact,
    required User user,
    required String role,
    required bool isVerified,
    required bool isGoogleAuth,
  }) {
    final theme = Theme.of(context);
    final displayTitle =
        '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'
            .trim();
    final effectiveName = displayTitle.isNotEmpty
        ? displayTitle
        : (user.displayName?.trim().isNotEmpty == true
              ? user.displayName!.trim()
              : (user.email ?? 'Road Surveyor'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Identity overview card
        WebCard(
          padding: EdgeInsets.all(
            isCompact ? WebDesign.space4 : WebDesign.space5,
          ),
          child: Wrap(
            spacing: WebDesign.space4,
            runSpacing: WebDesign.space4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: WebDesign.brand(isDark),
                    backgroundImage:
                        user.photoURL != null && user.photoURL!.isNotEmpty
                        ? NetworkImage(user.photoURL!)
                        : null,
                    child: user.photoURL == null || user.photoURL!.isEmpty
                        ? Text(
                            effectiveName.characters.first.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 22,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: WebDesign.space4),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: WebDesign.space2,
                          runSpacing: WebDesign.space1,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              effectiveName,
                              style: theme.textTheme.titleLarge,
                            ),
                            _buildVerificationBadge(isVerified, isGoogleAuth),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user.email ?? '',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: WebDesign.textSecondary(isDark),
                          ),
                        ),
                        const SizedBox(height: WebDesign.space2),
                        StatusChip(
                          label: _formatRoleLabel(role),
                          tone: StatusTone.neutral,
                          dense: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              OutlinedButton.icon(
                onPressed: () => CloudService.instance.signOut(),
                icon: const Icon(Icons.logout_rounded, size: 16),
                label: const Text('Sign Out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: WebDesign.danger(isDark),
                  side: BorderSide(
                    color: WebDesign.danger(isDark).withValues(alpha: 0.45),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (!isVerified) ...[
          const SizedBox(height: WebDesign.space4),
          Container(
            padding: const EdgeInsets.all(WebDesign.space4),
            decoration: BoxDecoration(
              color: WebDesign.statusStyle(StatusTone.pending, isDark).bg,
              borderRadius: BorderRadius.circular(WebDesign.radiusMd),
              border: Border.all(
                color: WebDesign.statusStyle(
                  StatusTone.pending,
                  isDark,
                ).outline,
              ),
            ),
            child: Wrap(
              spacing: WebDesign.space3,
              runSpacing: WebDesign.space3,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      color: WebDesign.statusStyle(
                        StatusTone.pending,
                        isDark,
                      ).fg,
                    ),
                    const SizedBox(width: WebDesign.space3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Email verification required to report',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            'Verify your email via the link sent to your inbox before sending pothole reports.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: () => _showVerificationDialog(user.uid),
                  icon: const Icon(Icons.mark_email_read_outlined, size: 16),
                  label: const Text('Verify Email'),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: WebDesign.space4),

        // Personal details form
        WebCard(
          padding: EdgeInsets.all(
            isCompact ? WebDesign.space4 : WebDesign.space5,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading(
                  title: 'Personal Details',
                  subtitle:
                      'Keep your surveyor name and contact details current.',
                  icon: Icons.badge_outlined,
                ),
                if (_hasUnsavedChanges) ...[
                  const SizedBox(height: WebDesign.space3),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WebDesign.space3,
                      vertical: WebDesign.space2,
                    ),
                    decoration: BoxDecoration(
                      color: WebDesign.statusStyle(
                        StatusTone.pending,
                        isDark,
                      ).bg,
                      borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                      border: Border.all(
                        color: WebDesign.statusStyle(
                          StatusTone.pending,
                          isDark,
                        ).outline,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_notifications_outlined,
                          size: 16,
                          color: WebDesign.statusStyle(
                            StatusTone.pending,
                            isDark,
                          ).fg,
                        ),
                        const SizedBox(width: WebDesign.space2),
                        const Expanded(
                          child: Text('You have unsaved profile changes.'),
                        ),
                        TextButton(
                          onPressed: _isSaving ? null : _resetUnsavedEdits,
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: WebDesign.space4),
                if (isCompact) ...[
                  TextFormField(
                    controller: _firstNameController,
                    textInputAction: TextInputAction.next,
                    decoration: _inputDecoration(
                      'First Name',
                      Icons.person_outline,
                      isDark: isDark,
                    ),
                    validator: (v) {
                      final trimmed = (v ?? '').trim();
                      if (trimmed.isEmpty) return 'Enter first name';
                      if (trimmed.length < 2) {
                        return 'Use at least 2 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: WebDesign.space3),
                  TextFormField(
                    controller: _lastNameController,
                    textInputAction: TextInputAction.next,
                    decoration: _inputDecoration(
                      'Last Name',
                      Icons.person_outline,
                      isDark: isDark,
                    ),
                    validator: (v) {
                      final trimmed = (v ?? '').trim();
                      if (trimmed.isEmpty) return 'Enter last name';
                      if (trimmed.length < 2) {
                        return 'Use at least 2 characters';
                      }
                      return null;
                    },
                  ),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _firstNameController,
                          textInputAction: TextInputAction.next,
                          decoration: _inputDecoration(
                            'First Name',
                            Icons.person_outline,
                            isDark: isDark,
                          ),
                          validator: (v) {
                            final trimmed = (v ?? '').trim();
                            if (trimmed.isEmpty) return 'Enter first name';
                            if (trimmed.length < 2) {
                              return 'Use at least 2 characters';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: WebDesign.space4),
                      Expanded(
                        child: TextFormField(
                          controller: _lastNameController,
                          textInputAction: TextInputAction.next,
                          decoration: _inputDecoration(
                            'Last Name',
                            Icons.person_outline,
                            isDark: isDark,
                          ),
                          validator: (v) {
                            final trimmed = (v ?? '').trim();
                            if (trimmed.isEmpty) return 'Enter last name';
                            if (trimmed.length < 2) {
                              return 'Use at least 2 characters';
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: WebDesign.space3),
                if (isCompact) ...[
                  TextFormField(
                    initialValue: user.email ?? '',
                    readOnly: true,
                    decoration: _inputDecoration(
                      'Email Address (Primary)',
                      Icons.email_outlined,
                      suffixIcon: isVerified
                          ? Icon(
                              Icons.check_circle_rounded,
                              color: WebDesign.statusStyle(
                                StatusTone.approved,
                                isDark,
                              ).fg,
                              size: 18,
                            )
                          : null,
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(height: WebDesign.space3),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: _inputDecoration(
                      'Phone Number (Optional)',
                      Icons.phone_outlined,
                      isDark: isDark,
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return null;
                      if (!RegExp(r'^[0-9+\-\s()]{7,20}$').hasMatch(t)) {
                        return 'Enter a valid phone number';
                      }
                      return null;
                    },
                  ),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: user.email ?? '',
                          readOnly: true,
                          decoration: _inputDecoration(
                            'Email Address (Primary)',
                            Icons.email_outlined,
                            suffixIcon: isVerified
                                ? Icon(
                                    Icons.check_circle_rounded,
                                    color: WebDesign.statusStyle(
                                      StatusTone.approved,
                                      isDark,
                                    ).fg,
                                    size: 18,
                                  )
                                : null,
                            isDark: isDark,
                          ),
                        ),
                      ),
                      const SizedBox(width: WebDesign.space4),
                      Expanded(
                        child: TextFormField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          decoration: _inputDecoration(
                            'Phone Number (Optional)',
                            Icons.phone_outlined,
                            isDark: isDark,
                          ),
                          validator: (v) {
                            final t = (v ?? '').trim();
                            if (t.isEmpty) return null;
                            if (!RegExp(r'^[0-9+\-\s()]{7,20}$').hasMatch(t)) {
                              return 'Enter a valid phone number';
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: WebDesign.space4),
                Wrap(
                  spacing: WebDesign.space2,
                  runSpacing: WebDesign.space2,
                  alignment: WrapAlignment.end,
                  children: [
                    if (_hasUnsavedChanges)
                      OutlinedButton(
                        onPressed: _isSaving ? null : _resetUnsavedEdits,
                        child: const Text('Discard Changes'),
                      ),
                    ElevatedButton.icon(
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.save_rounded, size: 16),
                      label: Text(
                        _isSaving
                            ? 'Saving Changes...'
                            : 'Save Profile Details',
                      ),
                      onPressed: _isSaving ? null : _saveProfile,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: WebDesign.space4),

        // Security + Preferences split row
        LayoutBuilder(
          builder: (context, cons) {
            final twoCol = cons.maxWidth >= 820;
            final securityCard = WebCard(
              padding: EdgeInsets.all(
                isCompact ? WebDesign.space4 : WebDesign.space5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeading(
                    title: 'Password & Data Governance',
                    subtitle:
                        'Authentication method and report lifecycle rules.',
                    icon: Icons.security_rounded,
                  ),
                  const SizedBox(height: WebDesign.space3),
                  if (isGoogleAuth)
                    const Text(
                      'Your account signs in through Google Authentication. Manage your password directly in your Google account security settings.',
                    )
                  else ...[
                    Text(
                      'Send a password reset link to ${user.email ?? 'your registered email'}.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: WebDesign.space3),
                    OutlinedButton.icon(
                      onPressed: _isSendingPasswordReset
                          ? null
                          : () => _sendPasswordReset(user.email ?? ''),
                      icon: _isSendingPasswordReset
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lock_reset_rounded, size: 16),
                      label: Text(
                        _isSendingPasswordReset
                            ? 'Sending link...'
                            : 'Send Password Reset Email',
                      ),
                    ),
                    if (_passwordResetMessage != null) ...[
                      const SizedBox(height: WebDesign.space2),
                      Text(
                        _passwordResetMessage!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: WebDesign.statusStyle(
                            StatusTone.approved,
                            isDark,
                          ).fg,
                        ),
                      ),
                    ],
                    if (_passwordResetError != null) ...[
                      const SizedBox(height: WebDesign.space2),
                      Text(
                        _passwordResetError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: WebDesign.danger(isDark),
                        ),
                      ),
                    ],
                  ],
                  const Divider(height: WebDesign.space5),
                  Text(
                    '• Public visibility: Other users see verified hazards without your email address.\n'
                    '• Editing & Trash: Pending submissions can be edited or trashed. Approved and rejected reports are archived for audit.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            );

            final prefCard = WebCard(
              padding: EdgeInsets.all(
                isCompact ? WebDesign.space4 : WebDesign.space5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeading(
                    title: 'Display & Map Preferences',
                    subtitle: 'Theme, basemap layers, and guidance.',
                    icon: Icons.tune_rounded,
                  ),
                  const SizedBox(height: WebDesign.space3),
                  const Eyebrow('APPEARANCE MODE'),
                  const SizedBox(height: WebDesign.space2),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined, size: 16),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined, size: 16),
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.settings_suggest_outlined, size: 16),
                        label: Text('System'),
                      ),
                    ],
                    selected: {AppSettings.instance.themeModeNotifier.value},
                    onSelectionChanged: (sel) {
                      final next = sel.first;
                      if (next == ThemeMode.system) {
                        AppSettings.instance.themeModeNotifier.value =
                            ThemeMode.system;
                      } else {
                        AppSettings.instance.toggleTheme(
                          next == ThemeMode.dark,
                        );
                      }
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: WebDesign.space4),
                  Wrap(
                    spacing: WebDesign.space2,
                    runSpacing: WebDesign.space2,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            widget.onOpenSettings ??
                            () => showDialog<void>(
                              context: context,
                              builder: (_) => WebSettingsDialog(
                                onSettingsChanged: () => setState(() {}),
                                onPlacePinOnMap: widget.onSwitchToMap,
                              ),
                            ),
                        icon: const Icon(Icons.layers_outlined, size: 16),
                        label: const Text('Map & Display Settings'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            widget.onOpenHelp ??
                            () => showDialog<void>(
                              context: context,
                              builder: (_) => const WebHelpDialog(),
                            ),
                        icon: const Icon(Icons.help_outline_rounded, size: 16),
                        label: const Text('Web Guide'),
                      ),
                    ],
                  ),
                ],
              ),
            );

            if (twoCol) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: securityCard),
                  const SizedBox(width: WebDesign.space4),
                  Expanded(child: prefCard),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                securityCard,
                const SizedBox(height: WebDesign.space4),
                prefCard,
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildMyReportsView({
    required BuildContext context,
    required bool isDark,
    required bool isCompact,
    required double width,
    required String uid,
  }) {
    final theme = Theme.of(context);
    return StreamBuilder<QuerySnapshot>(
      key: ValueKey('user_reports_$_streamRetryNonce'),
      stream: CloudService.instance.streamUserPotholes(uid),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return WebCard(
            padding: const EdgeInsets.all(WebDesign.space5),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load your reports',
              message:
                  'We encountered an issue reading your submissions (${snapshot.error}).',
              action: ElevatedButton.icon(
                onPressed: () => setState(() => _streamRetryNonce++),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: WebDesign.space8),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final allDocs = snapshot.data?.docs ?? const [];
        final Map<String, Map<String, dynamic>> rawDataById = {};
        final List<WebReportItem> activeItems = [];
        final List<WebReportItem> trashedItems = [];

        for (final doc in allDocs) {
          final data = doc.data() as Map<String, dynamic>? ?? const {};
          rawDataById[doc.id] = data;
          final item = _docToWebReportItem(doc);
          if (item.normalizedStatus == 'deleted') {
            trashedItems.add(item);
          } else {
            activeItems.add(item);
          }
        }

        int approvedCount = 0;
        int pendingCount = 0;
        int rejectedCount = 0;
        for (final item in activeItems) {
          switch (item.normalizedStatus) {
            case 'approved':
              approvedCount++;
            case 'rejected':
              rejectedCount++;
            default:
              pendingCount++;
          }
        }

        final filter = WebReportFilter(
          defectClasses: _selectedDefectClass == 'all'
              ? const {}
              : {_selectedDefectClass},
          statuses: _reportStatus == 'all' ? const {} : {_reportStatus},
          sort: _reportSort,
        );
        final queryResult = WebReportQueryEngine.execute(
          dataset: activeItems,
          filter: filter,
          query: _reportSearch.text,
        );
        final visibleItems = queryResult.items;
        final totalPages = WebReportQueryEngine.totalPages(
          visibleItems.length,
          _reportsPerPage,
        );
        final safePage = _currentPage.clamp(0, totalPages - 1);
        final pageStart = safePage * _reportsPerPage;
        final pageEnd = (pageStart + _reportsPerPage).clamp(
          0,
          visibleItems.length,
        );
        final pageItems = visibleItems.sublist(pageStart, pageEnd);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MetricGrid(
              desktopColumns: 4,
              spacing: WebDesign.space3,
              children: [
                MetricTile(
                  label: 'Total Active Reports',
                  value: '${activeItems.length}',
                  icon: Icons.analytics_outlined,
                  accent: WebDesign.brand(isDark),
                  hint: 'Synced from cloud',
                ),
                MetricTile(
                  label: 'Approved Live',
                  value: '$approvedCount',
                  icon: Icons.check_circle_outline_rounded,
                  accent: WebDesign.statusStyle(StatusTone.approved, isDark).fg,
                  hint: 'Visible on public map',
                ),
                MetricTile(
                  label: 'Pending Review',
                  value: '$pendingCount',
                  icon: Icons.schedule_rounded,
                  accent: WebDesign.statusStyle(StatusTone.pending, isDark).fg,
                  hint: 'Editable while pending',
                ),
                MetricTile(
                  label: 'Rejected',
                  value: '$rejectedCount',
                  icon: Icons.cancel_outlined,
                  accent: WebDesign.danger(isDark),
                  hint: 'Archived by moderators',
                ),
              ],
            ),

            const SizedBox(height: WebDesign.space4),

            // Active vs Trash Bin switcher
            WebCard(
              padding: const EdgeInsets.all(WebDesign.space3),
              child: Wrap(
                spacing: WebDesign.space2,
                runSpacing: WebDesign.space2,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment<bool>(
                        value: false,
                        icon: const Icon(Icons.assignment_outlined, size: 16),
                        label: Text('Active (${activeItems.length})'),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                        ),
                        label: Text('Trash Bin (${trashedItems.length})'),
                      ),
                    ],
                    selected: {_showTrashBin},
                    onSelectionChanged: (sel) => setState(() {
                      _showTrashBin = sel.first;
                      _currentPage = 0;
                    }),
                  ),
                  Text(
                    _showTrashBin
                        ? 'Restore or permanently remove trashed pending reports.'
                        : 'Pending reports remain editable until reviewed by a moderator.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),

            const SizedBox(height: WebDesign.space4),

            if (_showTrashBin)
              _buildTrashSection(
                context: context,
                isDark: isDark,
                width: width,
                trashedItems: trashedItems,
              )
            else ...[
              // Search + Status + 4-Class Defect + Sort toolbar
              WebCard(
                padding: const EdgeInsets.all(WebDesign.space4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _reportSearch,
                            onChanged: (_) => setState(() => _currentPage = 0),
                            decoration: InputDecoration(
                              hintText:
                                  'Search by report ID, defect class or barangay',
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 18,
                              ),
                              suffixIcon: _reportSearch.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Clear report search',
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 16,
                                      ),
                                      onPressed: () => setState(() {
                                        _reportSearch.clear();
                                        _currentPage = 0;
                                      }),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: WebDesign.space3),
                    Wrap(
                      spacing: WebDesign.space2,
                      runSpacing: WebDesign.space2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Eyebrow('STATUS'),
                        for (final st in [
                          'all',
                          'pending',
                          'approved',
                          'rejected',
                        ])
                          ChoiceChip(
                            label: Text(
                              st == 'all'
                                  ? 'All'
                                  : '${st[0].toUpperCase()}${st.substring(1)}',
                            ),
                            selected: _reportStatus == st,
                            onSelected: (_) => setState(() {
                              _reportStatus = st;
                              _currentPage = 0;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: WebDesign.space2),
                    Wrap(
                      spacing: WebDesign.space2,
                      runSpacing: WebDesign.space2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Eyebrow('DEFECT'),
                        ChoiceChip(
                          label: const Text('All classes'),
                          selected: _selectedDefectClass == 'all',
                          onSelected: (_) => setState(() {
                            _selectedDefectClass = 'all';
                            _currentPage = 0;
                          }),
                        ),
                        for (final cls in DpwhStandards.allClasses)
                          ChoiceChip(
                            avatar: RoadDefectGlyph(
                              classId: cls.classId,
                              size: 16,
                              color: cls.color,
                            ),
                            label: Text(cls.name),
                            selected: _selectedDefectClass == cls.name,
                            onSelected: (_) => setState(() {
                              _selectedDefectClass = cls.name;
                              _currentPage = 0;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: WebDesign.space3),
                    Wrap(
                      spacing: WebDesign.space3,
                      runSpacing: WebDesign.space2,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Wrap(
                          spacing: WebDesign.space2,
                          runSpacing: WebDesign.space1,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Eyebrow('SORT'),
                            DropdownButton<WebReportSort>(
                              value: _reportSort,
                              isDense: true,
                              underline: const SizedBox.shrink(),
                              items: const [
                                DropdownMenuItem(
                                  value: WebReportSort.newest,
                                  child: Text('Newest first'),
                                ),
                                DropdownMenuItem(
                                  value: WebReportSort.oldest,
                                  child: Text('Oldest first'),
                                ),
                              ],
                              onChanged: (next) {
                                if (next == null) return;
                                setState(() {
                                  _reportSort = next;
                                  _currentPage = 0;
                                });
                              },
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Showing ${visibleItems.length} of ${activeItems.length}',
                              style: WebDesign.tabular(
                                theme.textTheme.bodySmall,
                              ),
                            ),
                            if (_reportSearch.text.isNotEmpty ||
                                _reportStatus != 'all' ||
                                _selectedDefectClass != 'all') ...[
                              const SizedBox(width: WebDesign.space2),
                              TextButton(
                                onPressed: () => setState(() {
                                  _reportSearch.clear();
                                  _reportStatus = 'all';
                                  _selectedDefectClass = 'all';
                                  _currentPage = 0;
                                }),
                                child: const Text('Reset filters'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: WebDesign.space4),

              if (activeItems.isEmpty)
                WebCard(
                  padding: const EdgeInsets.all(WebDesign.space6),
                  child: EmptyState(
                    icon: Icons.add_road_rounded,
                    title: 'No road reports yet',
                    message:
                        'Use the RoadSense mobile scanner to capture and upload road defects, then track and manage them here.',
                    action: widget.onSwitchToMap != null
                        ? OutlinedButton.icon(
                            onPressed: widget.onSwitchToMap,
                            icon: const Icon(Icons.map_outlined, size: 16),
                            label: const Text('Explore Road Map'),
                          )
                        : null,
                  ),
                )
              else if (visibleItems.isEmpty)
                WebCard(
                  padding: const EdgeInsets.all(WebDesign.space6),
                  child: EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No matching reports',
                    message:
                        'No submitted reports matched your current search or filter settings.',
                    action: OutlinedButton(
                      onPressed: () => setState(() {
                        _reportSearch.clear();
                        _reportStatus = 'all';
                        _selectedDefectClass = 'all';
                        _currentPage = 0;
                      }),
                      child: const Text('Reset filters'),
                    ),
                  ),
                )
              else ...[
                for (final item in pageItems) ...[
                  _buildReportListCard(
                    context: context,
                    isDark: isDark,
                    wide: width >= 920,
                    item: item,
                    rawData: rawDataById[item.docId] ?? const {},
                  ),
                  const SizedBox(height: WebDesign.space3),
                ],
                if (totalPages > 1)
                  WebCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WebDesign.space4,
                      vertical: WebDesign.space3,
                    ),
                    child: Wrap(
                      spacing: WebDesign.space3,
                      runSpacing: WebDesign.space2,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'Page ${safePage + 1} of $totalPages · Showing ${pageStart + 1}–$pageEnd of ${visibleItems.length}',
                          style: WebDesign.tabular(theme.textTheme.bodySmall),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OutlinedButton.icon(
                              onPressed: safePage > 0
                                  ? () => setState(
                                      () => _currentPage = safePage - 1,
                                    )
                                  : null,
                              icon: const Icon(
                                Icons.chevron_left_rounded,
                                size: 18,
                              ),
                              label: const Text('Previous'),
                            ),
                            const SizedBox(width: WebDesign.space2),
                            OutlinedButton.icon(
                              onPressed: safePage + 1 < totalPages
                                  ? () => setState(
                                      () => _currentPage = safePage + 1,
                                    )
                                  : null,
                              icon: const Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                              ),
                              label: const Text('Next'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _buildReportListCard({
    required BuildContext context,
    required bool isDark,
    required bool wide,
    required WebReportItem item,
    required Map<String, dynamic> rawData,
  }) {
    final theme = Theme.of(context);
    final status = item.normalizedStatus;
    final canModify = status == 'pending';
    final statusTone = status == 'approved'
        ? StatusTone.approved
        : (status == 'rejected' ? StatusTone.rejected : StatusTone.pending);
    final statusLabel = status == 'approved'
        ? 'Approved Live'
        : (status == 'rejected' ? 'Rejected' : 'Pending Review');
    final conf = item.peakModelConfidence;

    final thumb = InkWell(
      onTap: item.imageUrl.isNotEmpty
          ? () => _openFullPhotoPreview(item.imageUrl)
          : null,
      borderRadius: BorderRadius.circular(WebDesign.radiusSm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
        child: Container(
          width: wide ? 88 : 72,
          height: wide ? 68 : 64,
          color: WebDesign.sunken(isDark),
          child: item.imageUrl.startsWith('http')
              ? Image.network(
                  item.imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, st) => Icon(
                    Icons.broken_image_outlined,
                    color: WebDesign.textMuted(isDark),
                  ),
                )
              : Icon(
                  Icons.photo_camera_outlined,
                  color: WebDesign.textMuted(isDark),
                ),
        ),
      ),
    );

    final metaColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: WebDesign.space2,
          runSpacing: WebDesign.space1,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            WebDefectBadge(
              defectName: item.primaryDefect,
              dpwhCode: item.primaryDpwhCode,
              dense: true,
            ),

            StatusChip(label: statusLabel, tone: statusTone, dense: true),
            if (item.potholeCount > 1)
              Text(
                '${item.potholeCount} detections',
                style: WebDesign.tabular(theme.textTheme.labelMedium),
              ),
            if (conf != null)
              Text(
                '${WebReportQueryEngine.formatConfidence(conf)} AI confidence',
                style: WebDesign.tabular(theme.textTheme.bodySmall),
              ),
          ],
        ),
        const SizedBox(height: WebDesign.space2),
        Text(item.locationLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          'ID #${item.shortId} · ${WebReportQueryEngine.formatTimestamp(item.timestamp)} · ${item.location.latitude.toStringAsFixed(5)}, ${item.location.longitude.toStringAsFixed(5)}',
          style: WebDesign.tabular(theme.textTheme.bodySmall),
        ),

        if (status == 'rejected') ...[
          const SizedBox(height: WebDesign.space1),
          Text(
            item.rejectionReason.isNotEmpty
                ? 'Moderator note: ${item.rejectionReason}'
                : 'Declined during review — no specific moderator note recorded.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: WebDesign.statusStyle(StatusTone.rejected, isDark).fg,
            ),
          ),
        ] else if (status == 'approved') ...[
          const SizedBox(height: WebDesign.space1),
          Text(
            'Verified road hazard · Locked after approval.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );

    final actions = Wrap(
      spacing: WebDesign.space2,
      runSpacing: WebDesign.space2,
      children: [
        OutlinedButton.icon(
          onPressed: widget.onLocateOnMap == null
              ? null
              : () => widget.onLocateOnMap!(item.location, item.docId, rawData),
          icon: const Icon(Icons.place_outlined, size: 16),
          label: const Text('Inspect on Map'),
        ),
        if (canModify) ...[
          OutlinedButton.icon(
            onPressed: () =>
                _showEditReportDialog(context, item.docId, rawData),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit'),
          ),
          OutlinedButton.icon(
            onPressed: () => _confirmAndMoveToTrash(context, item.docId),
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 16,
              color: WebDesign.danger(isDark),
            ),
            label: Text(
              'Trash',
              style: TextStyle(color: WebDesign.danger(isDark)),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: WebDesign.danger(isDark).withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ],
    );

    return WebCard(
      padding: const EdgeInsets.all(WebDesign.space4),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                thumb,
                const SizedBox(width: WebDesign.space4),
                Expanded(child: metaColumn),
                const SizedBox(width: WebDesign.space4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: actions,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    thumb,
                    const SizedBox(width: WebDesign.space3),
                    Expanded(child: metaColumn),
                  ],
                ),
                const SizedBox(height: WebDesign.space3),
                actions,
              ],
            ),
    );
  }

  Widget _buildTrashSection({
    required BuildContext context,
    required bool isDark,
    required double width,
    required List<WebReportItem> trashedItems,
  }) {
    if (trashedItems.isEmpty) {
      return WebCard(
        padding: const EdgeInsets.all(WebDesign.space6),
        child: const EmptyState(
          icon: Icons.auto_delete_outlined,
          title: 'Trash Bin is Empty',
          message:
              'Deleted pending reports are held here so you can restore or permanently remove them.',
        ),
      );
    }

    final cols = width >= 1080 ? 3 : (width >= 700 ? 2 : 1);
    final gap = WebDesign.space3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WebCard(
          padding: const EdgeInsets.symmetric(
            horizontal: WebDesign.space4,
            vertical: WebDesign.space3,
          ),
          accentBorder: WebDesign.statusStyle(
            StatusTone.rejected,
            isDark,
          ).outline,
          child: Wrap(
            spacing: WebDesign.space3,
            runSpacing: WebDesign.space2,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${trashedItems.length} item(s) in Trash Bin. Permanent deletion cannot be undone.',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: WebDesign.statusStyle(StatusTone.rejected, isDark).fg,
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: WebDesign.danger(isDark),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _confirmAndEmptyTrash(
                  context,
                  trashedItems.map((e) => e.docId).toList(growable: false),
                ),
                icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                label: const Text('Clean Up All'),
              ),
            ],
          ),
        ),
        const SizedBox(height: WebDesign.space3),
        LayoutBuilder(
          builder: (ctx, cons) {
            final itemWidth = cols == 1
                ? cons.maxWidth
                : (cons.maxWidth - (gap * (cols - 1))) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final item in trashedItems)
                  SizedBox(
                    width: itemWidth,
                    child: WebCard(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(
                              WebDesign.radiusSm,
                            ),
                            child: Container(
                              height: 120,
                              width: double.infinity,
                              color: WebDesign.sunken(isDark),
                              child: item.imageUrl.startsWith('http')
                                  ? Image.network(
                                      item.imageUrl,
                                      fit: BoxFit.cover,
                                      errorBuilder: (c, e, st) => Icon(
                                        Icons.broken_image_outlined,
                                        color: WebDesign.textMuted(isDark),
                                      ),
                                    )
                                  : Icon(
                                      Icons.image_not_supported_outlined,
                                      color: WebDesign.textMuted(isDark),
                                    ),
                            ),
                          ),
                          const SizedBox(height: WebDesign.space3),
                          Wrap(
                            spacing: WebDesign.space2,
                            runSpacing: WebDesign.space1,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              WebDefectBadge(
                                defectName: item.primaryDefect,
                                dpwhCode: item.primaryDpwhCode,
                                dense: true,
                              ),
                              const StatusChip(
                                label: 'Trashed',
                                tone: StatusTone.rejected,
                                dense: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: WebDesign.space2),
                          Text(
                            item.locationLabel,
                            style: Theme.of(context).textTheme.titleSmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            WebReportQueryEngine.formatTimestamp(
                              item.timestamp,
                            ),
                            style: WebDesign.tabular(
                              Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(height: WebDesign.space3),
                          Wrap(
                            spacing: WebDesign.space2,
                            runSpacing: WebDesign.space2,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () =>
                                    _restoreReport(context, item.docId),
                                icon: const Icon(
                                  Icons.restore_from_trash_rounded,
                                  size: 16,
                                ),
                                label: const Text('Restore'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _confirmAndPermanentDelete(
                                  context,
                                  item.docId,
                                ),
                                icon: Icon(
                                  Icons.delete_forever_rounded,
                                  size: 16,
                                  color: WebDesign.danger(isDark),
                                ),
                                label: Text(
                                  'Delete',
                                  style: TextStyle(
                                    color: WebDesign.danger(isDark),
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: WebDesign.danger(
                                      isDark,
                                    ).withValues(alpha: 0.45),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(
    String label,
    IconData icon, {
    Widget? suffixIcon,
    bool isDark = false,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      suffixIcon: suffixIcon,
    );
  }

  String _formatRoleLabel(String role) {
    if (role == 'super_admin') return 'Super Admin';
    if (role == 'admin') return 'GIS Administrator';
    return 'Road Surveyor';
  }

  Widget _buildVerificationBadge(bool isVerified, bool isGoogleAuth) {
    return StatusChip(
      label: isVerified
          ? (isGoogleAuth ? 'Google Verified' : 'Verified Account')
          : 'Unverified',
      tone: isVerified ? StatusTone.approved : StatusTone.rejected,
    );
  }
}

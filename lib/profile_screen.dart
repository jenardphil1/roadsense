import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'cloud_service.dart';
import 'settings_dialog.dart';
import 'app_settings.dart';
import 'app_design.dart';

/// Professional Enterprise Profile & Surveyor Dashboard Page
class ProfileScreen extends StatefulWidget {
  final VoidCallback? onSwitchToMap;
  final Function(LatLng location, String? docId, Map<String, dynamic>? data)? onLocateOnMap;
  final Function(List<LatLng> locations, {String filterLabel})? onLocateAllOnMap;

  const ProfileScreen({
    super.key,
    this.onSwitchToMap,
    this.onLocateOnMap,
    this.onLocateAllOnMap,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _phoneController;
  bool _isSaving = false;
  bool _showTrashBin = false;

  @override
  void initState() {
    super.initState();
    final user = CloudService.instance.currentUser;
    final nameParts = (user?.displayName ?? '').split(' ');
    final initialFirst = nameParts.isNotEmpty ? nameParts.first : '';
    final initialLast = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

    _firstNameController = TextEditingController(text: initialFirst);
    _lastNameController = TextEditingController(text: initialLast);
    _phoneController = TextEditingController(text: user?.phoneNumber ?? '');

    // Fetch stored Firestore user profile fields
    if (user != null) {
      FirebaseFirestore.instance.collection('users').doc(user.uid).get().then((doc) {
        if (doc.exists && doc.data() != null && mounted) {
          final data = doc.data()!;
          if (data['firstName'] != null && data['firstName'].toString().isNotEmpty) {
            _firstNameController.text = data['firstName'];
          }
          if (data['lastName'] != null && data['lastName'].toString().isNotEmpty) {
            _lastNameController.text = data['lastName'];
          }
          if (data['phoneNumber'] != null && data['phoneNumber'].toString().isNotEmpty) {
            _phoneController.text = data['phoneNumber'];
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final user = CloudService.instance.currentUser;
    if (user == null) return;
    final isDark = AppSettings.instance.isDarkMode;
    final accentColor = AppDesign.accent(isDark);

    setState(() => _isSaving = true);
    try {
      await CloudService.instance.updateUserProfileDetails(
        uid: user.uid,
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Profile information updated successfully.'),
            backgroundColor: accentColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update profile: $e'), backgroundColor: AppDesign.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmAndMoveToTrash(BuildContext context, String docId) async {
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
              child: const Icon(Icons.delete_outline_rounded, color: Color(0xFFF59E0B), size: 22),
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
              style: TextStyle(color: AppDesign.textSecondary(isDark), fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Move to Trash', style: TextStyle(fontWeight: FontWeight.bold)),
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
    String selectedSeverity =
        (data['overallSeverity'] as String? ?? 'medium').toLowerCase();
    int potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;
    final noteController =
        TextEditingController(text: data['note'] as String? ?? '');

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
                      Text(
                        'Overall Severity',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppDesign.textPrimary(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: selectedSeverity,
                        dropdownColor: AppDesign.surface(isDark),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'low',
                            child: Text('Low Severity'),
                          ),
                          DropdownMenuItem(
                            value: 'medium',
                            child: Text('Medium Severity'),
                          ),
                          DropdownMenuItem(
                            value: 'high',
                            child: Text('High Severity'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => selectedSeverity = val);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Potholes in Frame',
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
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
                      Text(
                        'Notes / Description',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppDesign.textPrimary(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: noteController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Add or edit report notes...',
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
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
                        overallSeverity: selectedSeverity,
                        potholeCount: potholeCount,
                        note: noteController.text.trim(),
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

  Future<void> _confirmAndPermanentDelete(BuildContext context, String docId) async {
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
              child: Icon(Icons.delete_forever_rounded, color: AppDesign.danger, size: 22),
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
              style: TextStyle(color: AppDesign.textSecondary(isDark), fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppDesign.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete Forever', style: TextStyle(fontWeight: FontWeight.bold)),
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

  Future<void> _confirmAndEmptyTrash(BuildContext context, List<String> docIds) async {
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
              child: Icon(Icons.delete_sweep_rounded, color: AppDesign.danger, size: 24),
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
              style: TextStyle(color: AppDesign.textSecondary(isDark), fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppDesign.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Clean Up All', style: TextStyle(fontWeight: FontWeight.bold)),
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
    final codeController = TextEditingController();
    bool isSubmitting = false;
    int cooldownSeconds = 0;
    int sendAttempts = 0;
    const maxAttempts = 3;
    Timer? timer;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isDark = AppSettings.instance.isDarkMode;
          final dialogBg = AppDesign.surface(isDark);
          final dialogText = AppDesign.textPrimary(isDark);
          final subtext = AppDesign.textSecondary(isDark);
          final accentColor = AppDesign.accent(isDark);

          void startCooldown() {
            cooldownSeconds = 60;
            timer?.cancel();
            timer = Timer.periodic(const Duration(seconds: 1), (t) {
              if (cooldownSeconds > 0) {
                setDialogState(() => cooldownSeconds--);
              } else {
                t.cancel();
              }
            });
          }

          return AlertDialog(
            backgroundColor: dialogBg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Icon(Icons.verified_user_rounded, color: accentColor, size: 22),
                const SizedBox(width: 10),
                Text('Account Security Verification', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: dialogText)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter the 6-digit security code sent to your registered email inbox:',
                  style: TextStyle(fontSize: 13, color: subtext, height: 1.4),
                ),
                const SizedBox(height: 16),
                // 6 Individual Digit Box PIN Code Input UI
                Stack(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(6, (index) {
                        final text = codeController.text;
                        final digit = (index < text.length) ? text[index] : '';
                        final isCurrent = (index == text.length) || (index == 5 && text.length == 6);
                        final hasValue = digit.isNotEmpty;

                        return Container(
                          width: 42,
                          height: 52,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? accentColor.withValues(alpha: 0.12)
                                : AppDesign.bg(isDark),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isCurrent
                                  ? accentColor
                                  : (hasValue ? accentColor : AppDesign.border(isDark)),
                              width: isCurrent ? 2.0 : 1.2,
                            ),
                            boxShadow: isCurrent
                                ? [
                                    BoxShadow(
                                      color: accentColor.withValues(alpha: 0.25),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Text(
                              digit,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: dialogText,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.0,
                        child: TextField(
                          controller: codeController,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          autofocus: true,
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ),
                    ),
                  ],
                ),
                if (cooldownSeconds > 0) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      'Rate Limit: You can request another code in ${cooldownSeconds}s',
                      style: TextStyle(fontSize: 11.5, color: accentColor, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: (isSubmitting || cooldownSeconds > 0)
                    ? null
                    : () async {
                        if (sendAttempts >= maxAttempts) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Maximum code resend attempts reached for this session.')),
                          );
                          return;
                        }
                        sendAttempts++;
                        try {
                          await CloudService.instance.resendVerificationCode(uid);
                          startCooldown();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('A fresh verification code has been dispatched to your email.')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Failed to resend code: $e')),
                            );
                          }
                        }
                      },
                child: Text('Resend Code', style: TextStyle(color: subtext)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final code = codeController.text.trim();
                        if (code.length != 6) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter the full 6-digit verification code.')),
                          );
                          return;
                        }

                        setDialogState(() => isSubmitting = true);
                        try {
                          final isSuccess = await CloudService.instance.verifyUserSecurityCode(uid: uid, code: code);
                          if (context.mounted) {
                            if (isSuccess) {
                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Account verified successfully!')),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Invalid verification code. Please check and try again.')),
                              );
                            }
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Verification error: $e')),
                            );
                          }
                        } finally {
                          setDialogState(() => isSubmitting = false);
                        }
                      },
                child: isSubmitting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Verify Account'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = CloudService.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }

    final isGoogleAuth = CloudService.instance.isGoogleAuthUser(user);

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

        return Scaffold(
          backgroundColor: bgColor,
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(72),
            child: Container(
              decoration: BoxDecoration(
                color: cardBg,
                border: Border(
                  bottom: BorderSide(
                    color: cardBorder,
                    width: 1,
                  ),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      const Spacer(),

                      // TOP RIGHT NAVIGATION TAB SWITCHER
                      Container(
                        height: 48,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: cardBorder, width: 1.2),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08), blurRadius: 10, offset: const Offset(0, 3)),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (kIsWeb) ...[
                              // Map Tab
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: widget.onSwitchToMap,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.transparent,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.map_rounded, color: subtextColor, size: 16),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Map',
                                          style: TextStyle(color: subtextColor, fontSize: 12.5, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Profile Tab (Active)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: accentColor,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.person_rounded, color: Colors.white, size: 16),
                                    SizedBox(width: 6),
                                    Text(
                                      'Profile',
                                      style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            // Settings Button (Included in top right pill)
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () {
                                  showModalBottomSheet(
                                    context: context,
                                    isScrollControlled: true,
                                    backgroundColor: Colors.transparent,
                                    builder: (ctx) => MobileSettingsSheet(
                                      onSettingsChanged: () => setState(() {}),
                                    ),
                                  );
                                },
                                borderRadius: BorderRadius.circular(20),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(Icons.settings_rounded, color: subtextColor, size: 18),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          body: StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
            builder: (context, userDocSnapshot) {
              final userData = userDocSnapshot.data?.data() as Map<String, dynamic>? ?? {};
              final isVerified = isGoogleAuth || (userData['isVerified'] as bool? ?? false);

              final bool isMobile = MediaQuery.of(context).size.width < 640;

              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 16 : 24,
                  vertical: isMobile ? 16 : 28,
                ),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Professional Executive Header Card
                        Container(
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: cardBorder),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06), blurRadius: 16, offset: const Offset(0, 4)),
                            ],
                          ),
                          padding: EdgeInsets.all(isMobile ? 18 : 28),
                          child: isMobile
                              ? Column(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: accentColor.withValues(alpha: 0.3),
                                            blurRadius: 20,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: CircleAvatar(
                                        radius: 40,
                                        backgroundColor: accentColor,
                                        backgroundImage: user.photoURL != null && user.photoURL!.isNotEmpty
                                            ? NetworkImage(user.photoURL!)
                                            : null,
                                        child: user.photoURL == null || user.photoURL!.isEmpty
                                            ? Text(
                                                (user.displayName ?? user.email ?? 'U')[0].toUpperCase(),
                                                style: const TextStyle(fontSize: 30, color: Colors.white, fontWeight: FontWeight.w900),
                                              )
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        Text(
                                          user.displayName ?? 'Road Inspector',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          user.email ?? '',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: subtextColor, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton.icon(
                                        onPressed: () => CloudService.instance.signOut(),
                                        icon: const Icon(Icons.logout_rounded, size: 16),
                                        label: const Text('Sign Out', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(0xFFEF4444),
                                          side: BorderSide(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: accentColor.withValues(alpha: 0.3),
                                            blurRadius: 20,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: CircleAvatar(
                                        radius: 44,
                                        backgroundColor: accentColor,
                                        backgroundImage: user.photoURL != null && user.photoURL!.isNotEmpty
                                            ? NetworkImage(user.photoURL!)
                                            : null,
                                        child: user.photoURL == null || user.photoURL!.isEmpty
                                            ? Text(
                                                (user.displayName ?? user.email ?? 'U')[0].toUpperCase(),
                                                style: const TextStyle(fontSize: 34, color: Colors.white, fontWeight: FontWeight.w900),
                                              )
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            user.displayName ?? 'Road Inspector',
                                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textColor),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            user.email ?? '',
                                            style: TextStyle(color: subtextColor, fontSize: 14),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    OutlinedButton.icon(
                                      onPressed: () => CloudService.instance.signOut(),
                                      icon: const Icon(Icons.logout_rounded, size: 16),
                                      label: const Text('Sign Out', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFFEF4444),
                                        side: BorderSide(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                    ),
                                  ],
                                ),
                        ),

                        const SizedBox(height: 20),

                        // Unverified Account Banner
                        if (!isVerified)
                          Container(
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF451A03) : const Color(0xFFFFF1F2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: isDark ? const Color(0xFF78350F) : const Color(0xFFFECDD3)),
                            ),
                            padding: EdgeInsets.all(isMobile ? 14 : 18),
                            child: isMobile
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: isDark ? const Color(0xFF78350F) : const Color(0xFFFFE4E6),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(Icons.shield_outlined, color: Color(0xFFF97316), size: 20),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              'Account Security Verification Required',
                                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFFDBA74) : const Color(0xFF9F1239)),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Complete account verification to authorize survey logging and access full platform features.',
                                        style: TextStyle(fontSize: 11.5, color: isDark ? const Color(0xFFFED7AA) : const Color(0xFFBE123C)),
                                      ),
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFFEA580C),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                          ),
                                          icon: const Icon(Icons.verified_user_rounded, size: 16),
                                          label: const Text('Verify Code'),
                                          onPressed: () => _showVerificationDialog(user.uid),
                                        ),
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: isDark ? const Color(0xFF78350F) : const Color(0xFFFFE4E6),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.shield_outlined, color: Color(0xFFF97316), size: 22),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Account Security Verification Required',
                                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFFDBA74) : const Color(0xFF9F1239)),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'Complete account verification to authorize survey logging and access full platform features.',
                                              style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFFFED7AA) : const Color(0xFFBE123C)),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFFEA580C),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        icon: const Icon(Icons.verified_user_rounded, size: 16),
                                        label: const Text('Verify Code'),
                                        onPressed: () => _showVerificationDialog(user.uid),
                                      ),
                                    ],
                                  ),
                          ),

                        if (!isVerified) const SizedBox(height: 20),

                        // Personal Details & Credentials Card
                        Container(
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: cardBorder),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06), blurRadius: 6, offset: const Offset(0, 2)),
                            ],
                          ),
                          padding: EdgeInsets.all(isMobile ? 18 : 28),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.badge_rounded, color: accentColor, size: 22),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Personal Information & Credentials',
                                      style: TextStyle(fontSize: isMobile ? 15.5 : 17, fontWeight: FontWeight.bold, color: textColor),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Manage your account details and contact information.',
                                  style: TextStyle(color: subtextColor, fontSize: isMobile ? 12 : 13),
                                ),
                                const SizedBox(height: 20),

                                // First Name & Last Name
                                if (isMobile) ...[
                                  TextFormField(
                                    controller: _firstNameController,
                                    style: TextStyle(fontSize: 14, color: textColor, fontWeight: FontWeight.w500),
                                    decoration: _inputDecoration('First Name', Icons.person_outline, isDark: isDark),
                                    validator: (v) => (v == null || v.isEmpty) ? 'Enter first name' : null,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _lastNameController,
                                    style: TextStyle(fontSize: 14, color: textColor, fontWeight: FontWeight.w500),
                                    decoration: _inputDecoration('Last Name', Icons.person_outline, isDark: isDark),
                                    validator: (v) => (v == null || v.isEmpty) ? 'Enter last name' : null,
                                  ),
                                ] else
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller: _firstNameController,
                                          style: TextStyle(fontSize: 14.5, color: textColor, fontWeight: FontWeight.w500),
                                          decoration: _inputDecoration('First Name', Icons.person_outline, isDark: isDark),
                                          validator: (v) => (v == null || v.isEmpty) ? 'Enter first name' : null,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: TextFormField(
                                          controller: _lastNameController,
                                          style: TextStyle(fontSize: 14.5, color: textColor, fontWeight: FontWeight.w500),
                                          decoration: _inputDecoration('Last Name', Icons.person_outline, isDark: isDark),
                                          validator: (v) => (v == null || v.isEmpty) ? 'Enter last name' : null,
                                        ),
                                      ),
                                    ],
                                  ),

                                const SizedBox(height: 14),

                                // Email & Phone Number
                                if (isMobile) ...[
                                  TextFormField(
                                    initialValue: user.email,
                                    readOnly: true,
                                    style: TextStyle(fontSize: 14, color: textColor, fontWeight: FontWeight.w500),
                                    decoration: _inputDecoration(
                                      'Email Address (Primary)',
                                      Icons.email_outlined,
                                      suffixIcon: Padding(
                                        padding: const EdgeInsets.only(right: 8),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              isVerified ? Icons.verified_rounded : Icons.warning_amber_rounded,
                                              color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFEF4444),
                                              size: 16,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              isVerified ? 'VERIFIED' : 'UNVERIFIED',
                                              style: TextStyle(
                                                color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFEF4444),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      isDark: isDark,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isVerified ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                                          color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFF97316),
                                          size: 13,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          isVerified
                                              ? 'Email address is verified & authorized.'
                                              : 'Email is unverified. Tap Verify Code above to authorize.',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFF97316),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _phoneController,
                                    keyboardType: TextInputType.phone,
                                    style: TextStyle(fontSize: 14, color: textColor, fontWeight: FontWeight.w500),
                                    decoration: _inputDecoration('Phone Number', Icons.phone_outlined, isDark: isDark),
                                  ),
                                ] else
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            TextFormField(
                                              initialValue: user.email,
                                              readOnly: true,
                                              style: TextStyle(fontSize: 14.5, color: textColor, fontWeight: FontWeight.w500),
                                              decoration: _inputDecoration(
                                                'Email Address (Primary)',
                                                Icons.email_outlined,
                                                suffixIcon: Padding(
                                                  padding: const EdgeInsets.only(right: 8),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        isVerified ? Icons.verified_rounded : Icons.warning_amber_rounded,
                                                        color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFEF4444),
                                                        size: 16,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        isVerified ? 'VERIFIED' : 'UNVERIFIED',
                                                        style: TextStyle(
                                                          color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFEF4444),
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.w800,
                                                          letterSpacing: 0.5,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                isDark: isDark,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Padding(
                                              padding: const EdgeInsets.only(left: 4),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    isVerified ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                                                    color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFF97316),
                                                    size: 13,
                                                  ),
                                                  const SizedBox(width: 5),
                                                  Text(
                                                    isVerified
                                                        ? 'Email address is verified & authorized.'
                                                        : 'Email is unverified. Tap Verify Code above to authorize.',
                                                    style: TextStyle(
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.w600,
                                                      color: isVerified ? AppDesign.accent(isDark) : const Color(0xFFF97316),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: TextFormField(
                                          controller: _phoneController,
                                          keyboardType: TextInputType.phone,
                                          style: TextStyle(fontSize: 14.5, color: textColor, fontWeight: FontWeight.w500),
                                          decoration: _inputDecoration('Phone Number', Icons.phone_outlined, isDark: isDark),
                                        ),
                                      ),
                                    ],
                                  ),

                                const SizedBox(height: 20),

                                // Save Changes Action Button
                                SizedBox(
                                  width: isMobile ? double.infinity : null,
                                  child: Align(
                                    alignment: isMobile ? Alignment.center : Alignment.centerRight,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: accentColor,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                        minimumSize: isMobile ? const Size(double.infinity, 46) : null,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: _isSaving
                                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                          : const Icon(Icons.save_rounded, size: 18),
                                      label: Text(_isSaving ? 'Saving Changes...' : 'Save Profile Details'),
                                      onPressed: _isSaving
                                          ? null
                                          : () {
                                              if (_formKey.currentState!.validate()) {
                                                _saveProfile();
                                              }
                                            },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Hazard Submissions Section Title
                        Row(
                          children: [
                            Icon(Icons.assignment_rounded, color: accentColor, size: 22),
                            const SizedBox(width: 10),
                            Text(
                              'My Inspection & Hazard Reports',
                              style: TextStyle(fontSize: isMobile ? 15.5 : 17, fontWeight: FontWeight.bold, color: textColor),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        // User Hazard Submissions Stream
                        StreamBuilder<QuerySnapshot>(
                          stream: CloudService.instance.streamUserPotholes(user.uid),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Center(child: Text('Error loading reports: ${snapshot.error}', style: TextStyle(color: subtextColor)));
                            }
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return Center(child: CircularProgressIndicator(color: accentColor));
                            }

                            final allDocs = snapshot.data?.docs ?? [];
                            final activeDocs = allDocs.where((d) {
                              final data = d.data() as Map<String, dynamic>;
                              return data['status'] != 'deleted';
                            }).toList();

                            final trashedDocs = allDocs.where((d) {
                              final data = d.data() as Map<String, dynamic>;
                              return data['status'] == 'deleted';
                            }).toList();

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Header & Tab Selector
                                Row(
                                  children: [
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Icon(
                                            _showTrashBin ? Icons.delete_sweep_rounded : Icons.assignment_rounded,
                                            color: _showTrashBin ? AppDesign.danger : accentColor,
                                            size: 22,
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            _showTrashBin
                                                ? 'Trash Bin (${trashedDocs.length})'
                                                : 'My Inspection & Hazard Reports (${activeDocs.length})',
                                            style: TextStyle(
                                              fontSize: isMobile ? 15.5 : 17,
                                              fontWeight: FontWeight.bold,
                                              color: textColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),

                                // Tabs: Active Submissions vs Trash Bin
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: cardBg,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: cardBorder),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: InkWell(
                                          onTap: () => setState(() => _showTrashBin = false),
                                          borderRadius: BorderRadius.circular(8),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: !_showTrashBin ? accentColor : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Center(
                                              child: Text(
                                                'Active Submissions (${activeDocs.length})',
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: !_showTrashBin ? Colors.white : subtextColor,
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
                                          borderRadius: BorderRadius.circular(8),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: _showTrashBin ? AppDesign.danger : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  Icons.delete_outline_rounded,
                                                  size: 15,
                                                  color: _showTrashBin ? Colors.white : subtextColor,
                                                ),
                                                const SizedBox(width: 5),
                                                Text(
                                                  'Trash Bin (${trashedDocs.length})',
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: _showTrashBin ? Colors.white : subtextColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),

                                // Tab Content: Trash Bin
                                if (_showTrashBin) ...[
                                  if (trashedDocs.isEmpty)
                                    Container(
                                      decoration: BoxDecoration(
                                        color: cardBg,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: cardBorder),
                                      ),
                                      padding: EdgeInsets.all(isMobile ? 24 : 40),
                                      child: Center(
                                        child: Column(
                                          children: [
                                            Icon(Icons.auto_delete_outlined, size: isMobile ? 36 : 48, color: subtextColor),
                                            const SizedBox(height: 12),
                                            Text(
                                              'Trash Bin is Empty',
                                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textColor),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Deleted pending reports will be stored here before permanent cleanup.',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(fontSize: 12, color: subtextColor),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  else ...[
                                    // Clean Up All in Trash Button Bar
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: AppDesign.danger.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: AppDesign.danger.withValues(alpha: 0.3)),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${trashedDocs.length} item(s) in Trash Bin',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.bold,
                                                color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
                                              ),
                                            ),
                                          ),
                                          ElevatedButton.icon(
                                            onPressed: () => _confirmAndEmptyTrash(
                                              context,
                                              trashedDocs.map((d) => d.id).toList(),
                                            ),
                                            icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                                            label: const Text(
                                              'Clean Up All',
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: AppDesign.danger,
                                              foregroundColor: Colors.white,
                                              elevation: 0,
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),

                                    // Grid of Trashed Items
                                    GridView.builder(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: isMobile ? 1 : 3,
                                        mainAxisExtent: 275,
                                        crossAxisSpacing: 16,
                                        mainAxisSpacing: 16,
                                      ),
                                      itemCount: trashedDocs.length,
                                      itemBuilder: (context, index) {
                                        final data = trashedDocs[index].data() as Map<String, dynamic>;
                                        final imageUrl = data['imageUrl'] as String? ?? '';
                                        final lat = (data['latitude'] as num).toDouble();
                                        final lng = (data['longitude'] as num).toDouble();

                                        return Container(
                                          decoration: BoxDecoration(
                                            color: cardBg,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: AppDesign.danger.withValues(alpha: 0.35)),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                                                blurRadius: 4,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          clipBehavior: Clip.antiAlias,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: imageUrl.startsWith('http')
                                                    ? Image.network(
                                                        imageUrl,
                                                        width: double.infinity,
                                                        fit: BoxFit.cover,
                                                        cacheWidth: 360,
                                                        errorBuilder: (ctx, e, st) => Container(color: AppDesign.surface(isDark)),
                                                      )
                                                    : Container(color: AppDesign.surface(isDark)),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.all(12),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              Text(
                                                                '${lat.toStringAsFixed(4)}° N, ${lng.toStringAsFixed(4)}° E',
                                                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor),
                                                              ),
                                                              const SizedBox(height: 2),
                                                              Text(
                                                                'Trashed Hazard Report',
                                                                style: TextStyle(fontSize: 11, color: subtextColor),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                          decoration: BoxDecoration(
                                                            color: isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2),
                                                            borderRadius: BorderRadius.circular(6),
                                                          ),
                                                          child: Text(
                                                            'TRASHED',
                                                            style: TextStyle(
                                                              color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
                                                              fontSize: 9,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 10),
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: SizedBox(
                                                            height: 36,
                                                            child: ElevatedButton.icon(
                                                              onPressed: () => _restoreReport(context, trashedDocs[index].id),
                                                              icon: const Icon(Icons.restore_from_trash_rounded, size: 15),
                                                              label: const Text(
                                                                'Restore',
                                                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                                              ),
                                                              style: ElevatedButton.styleFrom(
                                                                backgroundColor: const Color(0xFF00796B),
                                                                foregroundColor: Colors.white,
                                                                elevation: 0,
                                                                shape: RoundedRectangleBorder(
                                                                  borderRadius: BorderRadius.circular(8),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(width: 8),
                                                        SizedBox(
                                                          height: 36,
                                                          child: OutlinedButton.icon(
                                                            onPressed: () => _confirmAndPermanentDelete(context, trashedDocs[index].id),
                                                            icon: const Icon(Icons.delete_forever_rounded, size: 15, color: Color(0xFFEF4444)),
                                                            label: const Text(
                                                              'Delete',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight: FontWeight.bold,
                                                                color: Color(0xFFEF4444),
                                                              ),
                                                            ),
                                                            style: OutlinedButton.styleFrom(
                                                              side: const BorderSide(color: Color(0xFFEF4444), width: 1.2),
                                                              padding: const EdgeInsets.symmetric(horizontal: 10),
                                                              shape: RoundedRectangleBorder(
                                                                borderRadius: BorderRadius.circular(8),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ] else ...[
                                  // Tab Content: Active Submissions
                                  if (activeDocs.isEmpty)
                                    Container(
                                      decoration: BoxDecoration(
                                        color: cardBg,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: cardBorder),
                                      ),
                                      padding: EdgeInsets.all(isMobile ? 24 : 40),
                                      child: Center(
                                        child: Column(
                                          children: [
                                            Icon(Icons.task_rounded, size: isMobile ? 36 : 48, color: subtextColor),
                                            const SizedBox(height: 12),
                                            Text(
                                              'No Active Inspection Reports',
                                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textColor),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Submissions logged from your mobile device scanner will be displayed here.',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(fontSize: 12, color: subtextColor),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  else
                                    GridView.builder(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: isMobile ? 1 : 3,
                                        mainAxisExtent: 275,
                                        crossAxisSpacing: 16,
                                        mainAxisSpacing: 16,
                                      ),
                                      itemCount: activeDocs.length,
                                      itemBuilder: (context, index) {
                                        final data = activeDocs[index].data() as Map<String, dynamic>;
                                        final imageUrl = data['imageUrl'] as String? ?? '';
                                        final lat = (data['latitude'] as num).toDouble();
                                        final lng = (data['longitude'] as num).toDouble();
                                        final status = data['status'] as String? ?? 'pending';

                                        Color statusBg;
                                        Color statusText;
                                        String statusLabel;

                                        if (status == 'approved') {
                                          statusBg = isDark ? AppDesign.accent(isDark).withValues(alpha: 0.18) : const Color(0xFFE5E7EB);
                                          statusText = isDark ? Colors.white : const Color(0xFF15803D);
                                          statusLabel = 'APPROVED LIVE';
                                        } else if (status == 'rejected') {
                                          statusBg = isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2);
                                          statusText = isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
                                          statusLabel = 'REJECTED';
                                        } else {
                                          statusBg = isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7);
                                          statusText = isDark ? const Color(0xFFFDE68A) : const Color(0xFFB45309);
                                          statusLabel = 'PENDING REVIEW';
                                        }

                                        final bool isApproved = status == 'approved';

                                        return Container(
                                          decoration: BoxDecoration(
                                            color: cardBg,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: cardBorder),
                                            boxShadow: [
                                              BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08), blurRadius: 4, offset: const Offset(0, 2)),
                                            ],
                                          ),
                                          clipBehavior: Clip.antiAlias,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: imageUrl.startsWith('http')
                                                    ? Image.network(
                                                        imageUrl,
                                                        width: double.infinity,
                                                        fit: BoxFit.cover,
                                                        cacheWidth: 360,
                                                        errorBuilder: (ctx, e, st) => Container(color: AppDesign.surface(isDark)),
                                                      )
                                                    : Container(color: AppDesign.surface(isDark)),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.all(12),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              Text(
                                                                '${lat.toStringAsFixed(4)}° N, ${lng.toStringAsFixed(4)}° E',
                                                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor),
                                                              ),
                                                              const SizedBox(height: 2),
                                                              Text(
                                                                'Road Pothole Hazard',
                                                                style: TextStyle(fontSize: 11, color: subtextColor),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                        Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                          decoration: BoxDecoration(
                                                            color: statusBg,
                                                            borderRadius: BorderRadius.circular(6),
                                                          ),
                                                          child: Text(
                                                            statusLabel,
                                                            style: TextStyle(color: statusText, fontSize: 9, fontWeight: FontWeight.bold),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 10),
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: SizedBox(
                                                            height: 36,
                                                            child: ElevatedButton.icon(
                                                              onPressed: () {
                                                                if (widget.onLocateOnMap != null) {
                                                                  widget.onLocateOnMap!(
                                                                    LatLng(lat, lng),
                                                                    activeDocs[index].id,
                                                                    data,
                                                                  );
                                                                } else {
                                                                  widget.onSwitchToMap?.call();
                                                                }
                                                              },
                                                              icon: const Icon(Icons.explore_rounded, size: 15),
                                                              label: const Text(
                                                                'Locate',
                                                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                                              ),
                                                              style: ElevatedButton.styleFrom(
                                                                backgroundColor: const Color(0xFF00796B),
                                                                foregroundColor: Colors.white,
                                                                elevation: 0,
                                                                shape: RoundedRectangleBorder(
                                                                  borderRadius: BorderRadius.circular(8),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(width: 8),
                                                        SizedBox(
                                                          height: 36,
                                                          child: OutlinedButton.icon(
                                                            onPressed: () => _showEditReportDialog(context, activeDocs[index].id, data),
                                                            icon: const Icon(Icons.edit_note_rounded, size: 15, color: Color(0xFF2563EB)),
                                                            label: const Text(
                                                              'Edit',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight: FontWeight.bold,
                                                                color: Color(0xFF2563EB),
                                                              ),
                                                            ),
                                                            style: OutlinedButton.styleFrom(
                                                              side: const BorderSide(color: Color(0xFF2563EB), width: 1.2),
                                                              padding: const EdgeInsets.symmetric(horizontal: 10),
                                                              shape: RoundedRectangleBorder(
                                                                borderRadius: BorderRadius.circular(8),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        // Only show Delete button if NOT approved (Pending or Rejected). Approved is protected for admins.
                                                        if (!isApproved) ...[
                                                          const SizedBox(width: 8),
                                                          SizedBox(
                                                            height: 36,
                                                            child: OutlinedButton.icon(
                                                              onPressed: () => _confirmAndMoveToTrash(context, activeDocs[index].id),
                                                              icon: const Icon(Icons.delete_outline_rounded, size: 15, color: Color(0xFFEF4444)),
                                                              label: const Text(
                                                                'Delete',
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: Color(0xFFEF4444),
                                                                ),
                                                              ),
                                                              style: OutlinedButton.styleFrom(
                                                                side: const BorderSide(color: Color(0xFFEF4444), width: 1.2),
                                                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                                                shape: RoundedRectangleBorder(
                                                                  borderRadius: BorderRadius.circular(8),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                ],
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon, {Widget? suffixIcon, bool isDark = false}) {
    return AppDesign.inputDecoration(
      label: label,
      icon: icon,
      suffixIcon: suffixIcon,
      isDark: isDark,
    );
  }
}

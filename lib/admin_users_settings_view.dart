import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'admin_report_query.dart';
import 'admin_shared_widgets.dart';
import 'approval_priority.dart';
import 'cloud_service.dart';
import 'web_components.dart';
import 'web_design.dart';

enum _ExportScope {
  approved('Approved live reports only'),
  pending('Pending review queue only'),
  rejected('Rejected reports only'),
  allActive('All active non-deleted reports');

  final String label;
  const _ExportScope(this.label);
}

/// Role-aware Users & Settings administration workspace:
/// - All verified admins: Auto-Accept policy control (with confirmation) &
///   scoped formula-safe dataset CSV export.
/// - Super Admins only (`isSuperAdmin`): Full user directory & role management
///   matching `firestore.rules` `allow list, update: if isSuperAdmin()`.
class AdminUsersSettingsView extends StatefulWidget {
  final List<AdminReportRow> activeRows;
  final Map<String, ReportPriority> priorities;
  final bool isSuperAdmin;
  final String currentUid;
  final Stream<bool>? autoAcceptStream;

  const AdminUsersSettingsView({
    super.key,
    required this.activeRows,
    required this.priorities,
    required this.isSuperAdmin,
    required this.currentUid,
    this.autoAcceptStream,
  });

  @override
  State<AdminUsersSettingsView> createState() => _AdminUsersSettingsViewState();
}

class _AdminUsersSettingsViewState extends State<AdminUsersSettingsView> {
  _ExportScope _exportScope = _ExportScope.approved;
  bool _includeEmails = false;
  String _userSearch = '';
  String _roleFilter = 'all';
  final TextEditingController _userSearchCtrl = TextEditingController();

  @override
  void dispose() {
    _userSearchCtrl.dispose();
    super.dispose();
  }

  List<AdminReportRow> _rowsForScope() {
    return widget.activeRows.where((r) {
      return switch (_exportScope) {
        _ExportScope.approved => r.status == AdminReportStatus.approved,
        _ExportScope.pending => r.status == AdminReportStatus.pending,
        _ExportScope.rejected => r.status == AdminReportStatus.rejected,
        _ExportScope.allActive => true,
      };
    }).toList();
  }

  void _runScopedExport(List<AdminReportRow> scoped) {
    final csv = AdminCsvExporter.buildReportsCsv(
      scoped,
      includeReporterEmail: widget.isSuperAdmin && _includeEmails,
      priorities: widget.priorities,
    );
    downloadAdminCsvFile(
      csv,
      'roadsense_${_exportScope.name}_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(
      WebDesign.snack(
        'Exported ${scoped.length} ${_exportScope.label.toLowerCase()} to CSV.',
        isDark: isDark,
        tone: StatusTone.approved,
      ),
    );
  }

  Future<void> _confirmRoleChange({
    required String uid,
    required String userName,
    required String currentRole,
    required String newRole,
  }) async {
    if (newRole == currentRole) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WebDesign.surface(isDark),
        title: Text('Update Role for $userName?'),
        content: Text(
          'Change access role from "$currentRole" to "$newRole"? '
          'Changes take effect immediately in Firestore security rules.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: WebDesign.brand(isDark),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Update Role'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await CloudService.instance.updateUserRole(uid, newRole);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Updated $userName role to "$newRole".',
            isDark: isDark,
            tone: StatusTone.approved,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WebDesign.snack(
            'Could not update role: $e',
            isDark: isDark,
            tone: StatusTone.rejected,
          ),
        );
      }
    }
  }

  String _safeInitial(String name, String email) {
    final cleanName = name.trim();
    if (cleanName.isNotEmpty) return cleanName[0].toUpperCase();
    final cleanEmail = email.trim();
    if (cleanEmail.isNotEmpty) return cleanEmail[0].toUpperCase();
    return 'U';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    final scopedRows = _rowsForScope();

    return SingleChildScrollView(
      padding: WebDesign.pageInsets(width),
      child: CenteredMaxWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Moderation Workflow Policy Card (All verified admins)
            WebCard(
              child: StreamBuilder<bool>(
                stream:
                    widget.autoAcceptStream ??
                    (Firebase.apps.isEmpty
                        ? Stream<bool>.value(false)
                        : CloudService.instance.streamAutoAcceptSetting()),
                builder: (context, snap) {
                  final isAuto = snap.data ?? false;
                  return SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      spacing: WebDesign.space4,
                      runSpacing: WebDesign.space3,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Eyebrow('SYSTEM MODERATION POLICY'),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    'Report Approval Mode',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  StatusChip(
                                    tone: isAuto
                                        ? StatusTone.pending
                                        : StatusTone.approved,
                                    label: isAuto
                                        ? 'Auto-Accept Active'
                                        : 'Manual Review Active',
                                    dense: true,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                isAuto
                                    ? 'Incoming citizen submissions skip manual moderation and publish directly onto the driver hazard map.'
                                    : 'Incoming reports wait in the Pending review queue until verified or rejected by an administrator.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isAuto
                                ? WebDesign.approveAction
                                : WebDesign.pendingLight,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => confirmAndToggleAutoAccept(
                            context,
                            currentEnabled: isAuto,
                          ),
                          icon: Icon(
                            isAuto
                                ? Icons.verified_user_outlined
                                : Icons.bolt_rounded,
                            size: 16,
                          ),
                          label: Text(
                            isAuto
                                ? 'Switch to Manual Review'
                                : 'Enable Auto-Accept',
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: WebDesign.space5),

            // 2. Scoped & Privacy-Safe CSV Export Card (All verified admins)
            WebCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeading(
                    eyebrow: 'DATASET EXPORT & PRIVACY CONTROLS',
                    title: 'Export Scoped Road Defect CSV',
                    subtitle:
                        'Select an explicit subset to download. Formula prefixes are escaped; reporter emails require Super Admin authorization and explicit opt-in.',
                  ),
                  const SizedBox(height: WebDesign.space4),
                  Wrap(
                    spacing: WebDesign.space2,
                    runSpacing: WebDesign.space2,
                    children: [
                      for (final scope in _ExportScope.values)
                        ChoiceChip(
                          label: Text(scope.label),
                          selected: _exportScope == scope,
                          onSelected: (_) =>
                              setState(() => _exportScope = scope),
                        ),
                    ],
                  ),
                  const SizedBox(height: WebDesign.space3),
                  if (widget.isSuperAdmin)
                    Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        value: _includeEmails,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text(
                          'Include reporter email addresses in exported file',
                          style: TextStyle(fontSize: 13.5),
                        ),
                        subtitle: const Text(
                          'Only enable for internal municipal audits; omit for external public briefs.',
                          style: TextStyle(fontSize: 12),
                        ),
                        onChanged: (v) =>
                            setState(() => _includeEmails = v ?? false),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(WebDesign.space3),
                      decoration: BoxDecoration(
                        color: WebDesign.sunken(isDark),
                        borderRadius: BorderRadius.circular(WebDesign.radiusSm),
                        border: Border.all(color: WebDesign.border(isDark)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.privacy_tip_outlined,
                            size: 16,
                            color: WebDesign.textSecondary(isDark),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Reporter email columns are omitted for standard admin exports to protect citizen PII.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: WebDesign.space4),
                  Wrap(
                    spacing: WebDesign.space4,
                    runSpacing: WebDesign.space2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: WebDesign.brand(isDark),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: scopedRows.isEmpty
                            ? null
                            : () => _runScopedExport(scopedRows),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: Text('Download CSV (${scopedRows.length} rows)'),
                      ),
                      Text(
                        'Selected scope contains ${scopedRows.length} report(s).',
                        style: WebDesign.tabular(
                          theme.textTheme.bodySmall ?? const TextStyle(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: WebDesign.space5),

            // 3. Role-Gated User Accounts & Permissions Directory
            if (!widget.isSuperAdmin)
              WebCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          color: WebDesign.textSecondary(isDark),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'User Directory & Role Management (Super Admin Only)',
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const StatusChip(
                          tone: StatusTone.neutral,
                          label: 'Restricted by backend rules',
                          dense: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: WebDesign.space2),
                    Text(
                      'Your verified account holds the standard Admin role. Firestore security rules restrict reading all user profiles and changing user roles exclusively to verified Super Admin accounts.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else
              WebCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeading(
                      eyebrow: 'SUPER ADMIN ACCESS CONTROL',
                      title: 'User Accounts & Roles',
                      subtitle:
                          'Promote or restrict verified accounts. Self-demotion is blocked by backend checks.',
                    ),
                    const SizedBox(height: WebDesign.space4),
                    Wrap(
                      spacing: WebDesign.space3,
                      runSpacing: WebDesign.space2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 340),
                          child: TextField(
                            controller: _userSearchCtrl,
                            onChanged: (v) => setState(() => _userSearch = v),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Search users by name or email...',
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 18,
                              ),
                              suffixIcon: _userSearch.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 16,
                                      ),
                                      onPressed: () {
                                        _userSearchCtrl.clear();
                                        setState(() => _userSearch = '');
                                      },
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        for (final r in const [
                          ('all', 'All roles'),
                          ('user', 'Surveyor / User'),
                          ('admin', 'Admin'),
                          ('super_admin', 'Super Admin'),
                        ])
                          ChoiceChip(
                            label: Text(r.$2),
                            selected: _roleFilter == r.$1,
                            onSelected: (_) =>
                                setState(() => _roleFilter = r.$1),
                          ),
                      ],
                    ),
                    const SizedBox(height: WebDesign.space4),
                    StreamBuilder<QuerySnapshot>(
                      stream: Firebase.apps.isEmpty
                          ? const Stream<QuerySnapshot>.empty()
                          : CloudService.instance.streamAllUsers(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return EmptyState(
                            icon: Icons.error_outline_rounded,
                            title: 'Could not load user directory',
                            message: '${snapshot.error}',
                            boxed: false,
                          );
                        }
                        if (snapshot.connectionState ==
                                ConnectionState.waiting &&
                            !snapshot.hasData) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }

                        final q = _userSearch.trim().toLowerCase();
                        final docs = (snapshot.data?.docs ?? []).where((doc) {
                          final data =
                              doc.data() as Map<String, dynamic>? ?? {};
                          final role = (data['role'] as String? ?? 'user')
                              .toLowerCase();
                          if (_roleFilter != 'all' && role != _roleFilter) {
                            return false;
                          }
                          if (q.isNotEmpty) {
                            final name = (data['displayName'] as String? ?? '')
                                .toLowerCase();
                            final email = (data['email'] as String? ?? '')
                                .toLowerCase();
                            if (!name.contains(q) && !email.contains(q)) {
                              return false;
                            }
                          }
                          return true;
                        }).toList();

                        if (docs.isEmpty) {
                          return const EmptyState(
                            icon: Icons.group_off_outlined,
                            title: 'No matching accounts',
                            message: 'Adjust search keywords or role filter.',
                            boxed: false,
                          );
                        }

                        return ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: docs.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: WebDesign.border(isDark),
                          ),
                          itemBuilder: (context, idx) {
                            final userDoc = docs[idx];
                            final data =
                                userDoc.data() as Map<String, dynamic>? ?? {};
                            final uid = data['uid'] as String? ?? userDoc.id;
                            final rawName =
                                (data['displayName'] as String? ?? '').trim();
                            final email = (data['email'] as String? ?? '')
                                .trim();
                            final role = (data['role'] as String? ?? 'user')
                                .trim();
                            final displayName = rawName.isNotEmpty
                                ? rawName
                                : 'Unnamed user';
                            final isSelf = uid == widget.currentUid;

                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: WebDesign.space2,
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 18,
                                    backgroundColor: role == 'super_admin'
                                        ? WebDesign.brand(isDark)
                                        : (role == 'admin'
                                              ? WebDesign.approveAction
                                              : WebDesign.textSecondary(
                                                  isDark,
                                                )),
                                    child: Text(
                                      _safeInitial(rawName, email),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: WebDesign.space3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                displayName,
                                                style:
                                                    theme.textTheme.titleSmall,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (isSelf) ...[
                                              const SizedBox(width: 6),
                                              const StatusChip(
                                                tone: StatusTone.info,
                                                label: 'You',
                                                dense: true,
                                              ),
                                            ],
                                          ],
                                        ),
                                        if (email.isNotEmpty)
                                          Text(
                                            email,
                                            style: theme.textTheme.bodySmall,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: WebDesign.space3),
                                  if (isSelf)
                                    const StatusChip(
                                      tone: StatusTone.approved,
                                      label: 'Super Admin',
                                      dense: true,
                                    )
                                  else
                                    DropdownButton<String>(
                                      value:
                                          const {
                                            'user',
                                            'admin',
                                            'super_admin',
                                          }.contains(role)
                                          ? role
                                          : 'user',
                                      underline: const SizedBox.shrink(),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 'user',
                                          child: Text('Surveyor / User'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'admin',
                                          child: Text('Admin'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'super_admin',
                                          child: Text('Super Admin'),
                                        ),
                                      ],
                                      onChanged: (nextRole) {
                                        if (nextRole != null) {
                                          _confirmRoleChange(
                                            uid: uid,
                                            userName: displayName,
                                            currentRole: role,
                                            newRole: nextRole,
                                          );
                                        }
                                      },
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

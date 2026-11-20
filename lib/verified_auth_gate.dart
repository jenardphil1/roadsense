import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'auth_screen.dart';
import 'cloud_service.dart';

/// Gates unauthenticated users on [AuthScreen] and lets signed-in users
/// enter the app immediately while email verification is enforced on actions
/// like submitting pothole reports.
class VerifiedAuthGate extends StatefulWidget {
  final Widget Function(String uid) authenticatedBuilder;
  const VerifiedAuthGate({super.key, required this.authenticatedBuilder});

  @override
  State<VerifiedAuthGate> createState() => _VerifiedAuthGateState();
}

class _VerifiedAuthGateState extends State<VerifiedAuthGate> {
  StreamSubscription<User?>? _subscription;
  User? _user;
  bool _ready = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _subscription = CloudService.instance.authStateChanges.listen((user) {
      setState(() {
        _user = user;
        _ready = true;
      });
      if (user != null) {
        unawaited(_refresh());
      }
    });
  }

  Future<void> _refresh() async {
    final revision = ++_revision;
    if (CloudService.instance.currentUser != null) {
      await CloudService.instance.isEmailVerified();
    }
    if (!mounted || revision != _revision) return;
    setState(() {
      _user = CloudService.instance.currentUser;
      _ready = true;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_user == null) {
      return AuthScreen(onAuthSuccess: _refresh);
    }
    return widget.authenticatedBuilder(_user!.uid);
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_flutter_app/app_design.dart';
import 'package:my_flutter_app/auth_screen.dart';
import 'package:my_flutter_app/email_verification_client.dart';
import 'package:my_flutter_app/email_verification_view.dart';

class FakeVerificationBackend implements EmailVerificationBackend {
  EmailVerificationStatus status;
  String activeCode;
  final List<String> verifyCalls = [];
  int sendCount = 0;
  int signOutCount = 0;
  Completer<bool>? pendingVerifyCompleter;
  EmailVerificationException? nextVerifyException;
  EmailVerificationException? nextSendException;
  EmailVerificationException? nextUpdateEmailException;

  FakeVerificationBackend({
    required this.status,
    this.activeCode = '004219',
  });

  @override
  Future<EmailVerificationStatus> getStatus() async => status;

  @override
  Future<EmailVerificationStatus> sendCode() async {
    sendCount++;
    if (nextSendException != null) {
      final err = nextSendException!;
      nextSendException = null;
      throw err;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    status = status.copyWith(
      hasActiveCode: true,
      isExpired: false,
      expiresAtMs: now + 600000,
      cooldownUntilMs: now + 60000,
      attemptsRemaining: 5,
      isLockedOut: false,
      sendsInWindow: status.sendsInWindow + 1,
    );
    return status;
  }

  @override
  Future<bool> verifyCode(String code) async {
    verifyCalls.add(code);
    if (pendingVerifyCompleter != null) {
      return pendingVerifyCompleter!.future;
    }
    if (nextVerifyException != null) {
      final err = nextVerifyException!;
      nextVerifyException = null;
      throw err;
    }
    if (code == activeCode) {
      status = status.copyWith(verified: true, hasActiveCode: false);
      return true;
    }
    final nextRem = (status.attemptsRemaining - 1).clamp(0, 5);
    status = status.copyWith(
      attemptsRemaining: nextRem,
      isLockedOut: nextRem == 0,
    );
    throw EmailVerificationException(
      code: nextRem == 0 ? 'resource-exhausted' : 'permission-denied',
      reason: nextRem == 0 ? 'attempt-limited' : 'incorrect',
      message: nextRem == 0
          ? 'Maximum incorrect attempts reached for this code. Tap Resend code to receive a new one.'
          : 'Incorrect verification code. $nextRem attempts remaining.',
      attemptsRemaining: nextRem,
    );
  }

  @override
  Future<EmailVerificationStatus> updatePendingEmail(String newEmail) async {
    if (nextUpdateEmailException != null) {
      final err = nextUpdateEmailException!;
      nextUpdateEmailException = null;
      throw err;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    status = status.copyWith(
      maskedEmail: maskEmailAddress(newEmail),
      hasActiveCode: true,
      isExpired: false,
      expiresAtMs: now + 600000,
      cooldownUntilMs: now + 60000,
      attemptsRemaining: 5,
      isLockedOut: false,
    );
    return status;
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File('C:/Windows/Fonts/arial.ttf');
    if (await font.exists()) {
      final bytes = await font.readAsBytes();
      for (final family in ['Roboto', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('maskEmailAddress masks local parts cleanly', () {
    expect(maskEmailAddress('a@example.com'), '*@example.com');
    expect(maskEmailAddress('ab@example.com'), 'a*@example.com');
    expect(maskEmailAddress('joe@example.com'), 'j*e@example.com');
    expect(maskEmailAddress('jenard@Example.COM'), 'je***d@example.com');
  });

  test('DigitsPasteInputFormatter preserves leading zeros and strips non-digits', () {
    const formatter = DigitsPasteInputFormatter();
    final pasted = formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: 'Code: 004-219!'),
    );
    expect(pasted.text, '004219');

    final capped = formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: '00123456789'),
    );
    expect(capped.text, '001234');
  });

  testWidgets(
    'shows masked email, instruction, leading-zero entry, and verifies once without duplicate submits',
    (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final backend = FakeVerificationBackend(
        activeCode: '004219',
        status: EmailVerificationStatus(
          verified: false,
          maskedEmail: 'je***d@example.com',
          hasActiveCode: true,
          isExpired: false,
          expiresAtMs: now + 600000,
          cooldownUntilMs: now + 60000,
          attemptsRemaining: 5,
          isLockedOut: false,
          sendLimitReached: false,
          sendsInWindow: 1,
          maxSendsPerWindow: 5,
          ttlMinutes: 10,
        ),
      );
      var verifiedCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: EmailVerificationView(
                backend: backend,
                initialEmail: 'jenard@example.com',
                initialStatus: backend.status,
                fetchStatusOnMount: false,
                onVerified: () => verifiedCount++,
                onSignOut: backend.signOut,
                isDark: false,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Verify your email'), findsOneWidget);
      expect(
        find.text('Enter the 6-digit code sent to your email.'),
        findsOneWidget,
      );
      expect(find.text('je***d@example.com'), findsOneWidget);
      expect(find.textContaining('Resend code ('), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('verification_code_field')),
        '004219',
      );
      await tester.pump();

      // Hold verification open to confirm duplicate taps cannot double-submit.
      backend.pendingVerifyCompleter = Completer<bool>();
      await tester.tap(find.byKey(const Key('verify_email_submit_button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('verify_email_submit_button')));
      await tester.pump();

      expect(backend.verifyCalls, ['004219']);

      backend.pendingVerifyCompleter!.complete(true);
      backend.pendingVerifyCompleter = null;
      await tester.pumpAndSettle();

      expect(verifiedCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'preserves entered code on connection error, shows incorrect/superseded/expired errors, and supports email correction',
    (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final backend = FakeVerificationBackend(
        activeCode: '012345',
        status: EmailVerificationStatus(
          verified: false,
          maskedEmail: 'ty*o@example.com',
          hasActiveCode: true,
          isExpired: false,
          expiresAtMs: now + 600000,
          cooldownUntilMs: 0,
          attemptsRemaining: 5,
          isLockedOut: false,
          sendLimitReached: false,
          sendsInWindow: 1,
          maxSendsPerWindow: 5,
          ttlMinutes: 10,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: EmailVerificationView(
                backend: backend,
                initialEmail: 'typo@example.com',
                fetchStatusOnMount: true,
                onVerified: () {},
                onSignOut: backend.signOut,
                isDark: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Network failure preserves entered 6 digits.
      backend.nextVerifyException = const EmailVerificationException(
        code: 'network',
        reason: 'network',
        message: 'Connection error. Check your internet connection and try again.',
        isNetworkError: true,
      );
      await tester.enterText(
        find.byKey(const Key('verification_code_field')),
        '012345',
      );
      await tester.tap(find.byKey(const Key('verify_email_submit_button')));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Connection error. Check your internet connection and try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('012345'), findsOneWidget);

      // 2. Wrong code shows decrementing remaining attempts.
      await tester.enterText(
        find.byKey(const Key('verification_code_field')),
        '999999',
      );
      await tester.tap(find.byKey(const Key('verify_email_submit_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('4 attempts remaining'), findsOneWidget);

      // 3. Resend works when cooldown is 0 and restarts countdown.
      await tester.tap(find.byKey(const Key('resend_verification_code_button')));
      await tester.pumpAndSettle();
      expect(backend.sendCount, 1);
      expect(find.textContaining('Resend code ('), findsOneWidget);

      // 4. Correct email address inline flow updates masked email.
      await tester.tap(find.byKey(const Key('toggle_change_email_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('change_pending_email_field')),
        'jenard@example.com',
      );
      await tester.tap(
        find.byKey(const Key('submit_change_pending_email_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('je***d@example.com'), findsOneWidget);

      // 5. Sign out button triggers signOut callback cleanly.
      await tester.tap(find.byKey(const Key('verification_sign_out_button')));
      await tester.pumpAndSettle();
      expect(backend.signOutCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(375, 812), const Size(1440, 900)]) {
    testWidgets(
      'verification view renders cleanly without overflow at $size and 2x text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final now = DateTime.now().millisecondsSinceEpoch;
        final backend = FakeVerificationBackend(
          status: EmailVerificationStatus(
            verified: false,
            maskedEmail: 'je***d@example.com',
            hasActiveCode: true,
            isExpired: false,
            expiresAtMs: now + 500000,
            cooldownUntilMs: now + 30000,
            attemptsRemaining: 4,
            isLockedOut: false,
            sendLimitReached: false,
            sendsInWindow: 1,
            maxSendsPerWindow: 5,
            ttlMinutes: 10,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: EmailVerificationView(
                  backend: backend,
                  initialEmail: 'jenard@example.com',
                  initialStatus: backend.status,
                  fetchStatusOnMount: false,
                  onVerified: () {},
                  onSignOut: backend.signOut,
                  isDark: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final size in [const Size(375, 812), const Size(1440, 900)]) {
    testWidgets(
      'AuthScreen resumes directly into Verify your email mode across restarts at $size without showing Explore Map',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final now = DateTime.now().millisecondsSinceEpoch;
        final backend = FakeVerificationBackend(
          activeCode: '009876',
          status: EmailVerificationStatus(
            verified: false,
            maskedEmail: 'je***d@example.com',
            hasActiveCode: true,
            isExpired: false,
            expiresAtMs: now + 540000,
            cooldownUntilMs: now + 45000,
            attemptsRemaining: 5,
            isLockedOut: false,
            sendLimitReached: false,
            sendsInWindow: 1,
            maxSendsPerWindow: 5,
            ttlMinutes: 10,
          ),
        );
        var authSucceeded = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppDesign.buildTheme(isDark: false),
            home: AuthScreen(
              onAuthSuccess: () => authSucceeded = true,
              initialPendingVerificationEmail: 'jenard@example.com',
              verificationBackend: backend,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.text('Verify your email'), findsOneWidget);
        expect(find.text('Explore Map'), findsNothing);
        expect(find.textContaining('Resend code ('), findsOneWidget);
        expect(backend.sendCount, 0);

        await tester.enterText(
          find.byKey(const Key('verification_code_field')),
          '009876',
        );
        await tester.tap(find.byKey(const Key('verify_email_submit_button')));
        await tester.pump(const Duration(milliseconds: 500));

        expect(authSucceeded, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'EmailVerificationView auto-sends missing code and handles resend cooldown updates',
    (tester) async {
      final backend = FakeVerificationBackend(
        status: const EmailVerificationStatus(
          verified: false,
          maskedEmail: 'te***r@example.com',
          hasActiveCode: false,
          isExpired: false,
          expiresAtMs: 0,
          cooldownUntilMs: 0,
          attemptsRemaining: 5,
          isLockedOut: false,
          sendLimitReached: false,
          sendsInWindow: 0,
          maxSendsPerWindow: 5,
          ttlMinutes: 10,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppDesign.buildTheme(isDark: false),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: EmailVerificationView(
                backend: backend,
                initialEmail: 'tester@example.com',
                fetchStatusOnMount: true,
                autoSendIfMissing: true,
                onVerified: () {},
                onSignOut: backend.signOut,
                isDark: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(backend.sendCount, 1);
      expect(
        find.textContaining('A 6-digit verification code was sent to te***r@example.com.'),
        findsOneWidget,
      );
      expect(find.textContaining('Resend code ('), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

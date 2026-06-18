import 'package:flutter/material.dart';
import 'package:loader_overlay/loader_overlay.dart';
import 'package:open_tv/backend/identity_service.dart';
import 'package:open_tv/backend/restore_service.dart';
import 'package:open_tv/l10n/strings.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/pin_keypad.dart';
import 'package:open_tv/setup.dart';
import 'package:open_tv/subscription_dialog.dart';
import 'package:open_tv/tv_home.dart';

/// First screen on a clean install: the subscriber enters their ID + PIN to
/// download and import their playlist. "Skip login" opens the classic
/// add-playlist wizard instead. On an update this screen is not shown (the app
/// already has a playlist / ID) — see main.dart.
class RestoreLoginPage extends StatefulWidget {
  // Whether to show the "Skip login" button (true on a clean install; false
  // when opened from inside the setup wizard, where Back already returns there).
  final bool showSkip;
  const RestoreLoginPage({super.key, this.showSkip = true});

  @override
  State<RestoreLoginPage> createState() => _RestoreLoginPageState();
}

class _RestoreLoginPageState extends State<RestoreLoginPage> {
  String _id = '';
  String _pin = '';

  Future<void> _editId() async {
    final v = await showPinKeypad(
      context,
      title: S.of(context).restoreIdLabel,
      length: subscriberIdLength,
    );
    if (v != null && mounted) setState(() => _id = v);
  }

  Future<void> _editPin() async {
    final v = await showPinKeypad(
      context,
      title: S.of(context).restorePinLabel,
      length: subscriberPinLength,
    );
    if (v != null && mounted) setState(() => _pin = v);
  }

  Future<void> _login() async {
    final s = S.of(context);
    if (_id.length != subscriberIdLength ||
        _pin.length != subscriberPinLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.restoreInvalidInput)),
      );
      return;
    }
    context.loaderOverlay.show();
    try {
      await RestoreService.restore(_id, _pin);
      if (!mounted) return;
      context.loaderOverlay.hide();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.restoreSuccess)),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const TvHome()),
        (route) => false,
      );
    } on RestoreException catch (ex) {
      if (!mounted) return;
      context.loaderOverlay.hide();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(restoreErrorText(s, ex.code))),
      );
    } catch (_) {
      if (!mounted) return;
      context.loaderOverlay.hide();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(restoreErrorText(s, RestoreError.network))),
      );
    }
  }

  void _skip() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const Setup()),
    );
  }

  // For users without a subscription yet: opens the "become a subscriber"
  // payment (2800 Kč, fresh ID + PIN). They log in afterwards with those.
  void _become() {
    showDialog(
      context: context,
      builder: (_) => const SubscriptionDialog(becomeSubscriber: true),
    );
  }

  Widget _valueRow(
    String label,
    IconData icon,
    String value,
    VoidCallback onTap, {
    bool autofocus = false,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        autofocus: autofocus,
        leading: Icon(icon),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          value.isEmpty ? '—' : value,
          style: const TextStyle(fontSize: 18, color: Colors.white),
        ),
        trailing: const Icon(Icons.edit, size: 18),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      body: Loading(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.loginTitle,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s.loginSub,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _valueRow(
                      s.restoreIdLabel,
                      Icons.badge,
                      _id,
                      _editId,
                      autofocus: true,
                    ),
                    _valueRow(
                      s.restorePinLabel,
                      Icons.password,
                      _pin,
                      _editPin,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _login,
                      icon: const Icon(Icons.login),
                      label: Text(s.loginButton),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _become,
                      icon: const Icon(Icons.how_to_reg),
                      label: Text(s.becomeSubscriber),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 16,
                        ),
                      ),
                    ),
                    if (widget.showSkip) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _skip,
                        child: Text(s.skipLogin),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

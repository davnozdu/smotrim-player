import 'package:flutter/material.dart';
import 'package:loader_overlay/loader_overlay.dart';
import 'package:open_tv/backend/identity_service.dart';
import 'package:open_tv/backend/restore_service.dart';
import 'package:open_tv/l10n/strings.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/pin_keypad.dart';

/// "Restore playlist": the subscriber enters their ID (8 digits) and PIN
/// (6 digits); the app fetches the playlist from the server and imports it.
/// Numeric values are entered through the on-screen keypad (reliable on the TV
/// box, which won't open its soft keyboard on D-pad focus).
class RestorePlaylistPage extends StatefulWidget {
  const RestorePlaylistPage({super.key});

  @override
  State<RestorePlaylistPage> createState() => _RestorePlaylistPageState();
}

class _RestorePlaylistPageState extends State<RestorePlaylistPage> {
  String _id = '';
  String _pin = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Pre-fill with this device's own ID/PIN; the user can overwrite them when
  // restoring credentials issued on another device.
  Future<void> _load() async {
    final id = await IdentityService.getOrCreateId();
    final pin = await IdentityService.getPin() ?? '';
    if (!mounted) return;
    setState(() {
      _id = id;
      _pin = pin;
      _loading = false;
    });
  }

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

  Future<void> _send() async {
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
      // Back to the shell; the newly restored playlist is already active.
      Navigator.of(context).popUntil((route) => route.isFirst);
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

  Widget _valueRow(String label, IconData icon, String value, VoidCallback onTap,
      {bool autofocus = false, bool obscure = false}) {
    // The PIN is shown as bullets — it stays secret from anyone in the room,
    // while the count still tells the user how many digits went in.
    final shown = value.isEmpty
        ? '—'
        : (obscure ? '●' * value.length : value);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        autofocus: autofocus,
        leading: Icon(icon),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          shown,
          style: TextStyle(
            fontSize: 18,
            color: Colors.white,
            letterSpacing: obscure && value.isNotEmpty ? 4 : null,
          ),
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
      appBar: AppBar(title: Text(s.restorePlaylist)),
      body: Loading(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.restorePlaylistSub,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 16),
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
                            obscure: true,
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _send,
                            icon: const Icon(Icons.cloud_download),
                            label: Text(s.send),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 16,
                              ),
                            ),
                          ),
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

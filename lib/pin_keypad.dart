import 'package:flutter/material.dart';

/// Length of the hotel-mode PIN.
const int hotelPinLength = 8;

/// Shows an on-screen numeric keypad and returns the entered [hotelPinLength]-
/// digit PIN (or null if cancelled). A dedicated keypad is used instead of a
/// text field because this TV box only opens its soft keyboard on a touch tap,
/// not on D-pad focus — the keypad is fully navigable with the remote.
Future<String?> showPinKeypad(
  BuildContext context, {
  required String title,
  String? subtitle,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _PinKeypadDialog(title: title, subtitle: subtitle),
  );
}

class _PinKeypadDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  const _PinKeypadDialog({required this.title, this.subtitle});

  @override
  State<_PinKeypadDialog> createState() => _PinKeypadDialogState();
}

class _PinKeypadDialogState extends State<_PinKeypadDialog> {
  String _value = '';

  void _input(String d) {
    if (_value.length >= hotelPinLength) return;
    setState(() => _value += d);
    if (_value.length == hotelPinLength) {
      final v = _value;
      // Let the last dot render before closing.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(v);
      });
    }
  }

  void _backspace() {
    if (_value.isEmpty) return;
    setState(() => _value = _value.substring(0, _value.length - 1));
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(hotelPinLength, (i) {
        final filled = i < _value.length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? Colors.white : Colors.transparent,
            border: Border.all(color: Colors.white70, width: 2),
          ),
        );
      }),
    );
  }

  Widget _key(
    String label, {
    VoidCallback? onTap,
    IconData? icon,
    bool autofocus = false,
  }) {
    return Padding(
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        width: 62,
        height: 54,
        child: FilledButton.tonal(
          autofocus: autofocus,
          onPressed: onTap,
          style: FilledButton.styleFrom(padding: EdgeInsets.zero),
          child: icon != null
              ? Icon(icon, size: 22)
              : Text(label, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }

  Widget _row(List<Widget> children) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.subtitle != null) ...[
              Text(
                widget.subtitle!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 12),
            ],
            _dots(),
            const SizedBox(height: 16),
            FocusTraversalGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _row([
                    _key('1', autofocus: true, onTap: () => _input('1')),
                    _key('2', onTap: () => _input('2')),
                    _key('3', onTap: () => _input('3')),
                  ]),
                  _row([
                    _key('4', onTap: () => _input('4')),
                    _key('5', onTap: () => _input('5')),
                    _key('6', onTap: () => _input('6')),
                  ]),
                  _row([
                    _key('7', onTap: () => _input('7')),
                    _key('8', onTap: () => _input('8')),
                    _key('9', onTap: () => _input('9')),
                  ]),
                  _row([
                    _key('', icon: Icons.backspace_outlined, onTap: _backspace),
                    _key('0', onTap: () => _input('0')),
                    _key(
                      '',
                      icon: Icons.close,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

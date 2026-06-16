import 'package:flutter/material.dart';

/// An [IconButton] with a clear blue focus ring, so D-pad focus is visible on
/// the black background / TV (the default IconButton highlight is too faint).
class FocusIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final double iconSize;
  const FocusIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 30,
  });

  @override
  State<FocusIconButton> createState() => _FocusIconButtonState();
}

class _FocusIconButtonState extends State<FocusIconButton> {
  final FocusNode _node = FocusNode();

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _node.hasFocus;
    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: focused ? const Color(0x334FC3F7) : Colors.transparent,
        border: Border.all(
          color: focused ? const Color(0xFF4FC3F7) : Colors.transparent,
          width: 3,
        ),
      ),
      child: IconButton(
        focusNode: _node,
        iconSize: widget.iconSize,
        icon: Icon(widget.icon),
        onPressed: widget.onPressed,
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: button)
        : button;
  }
}

import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';

class MenuTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final LinearGradient color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;
  // Optional category icon image (assets/categories/*.png). When set, it is
  // shown instead of [icon].
  final String? imageAsset;

  const MenuTile({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.imageAsset,
  });

  @override
  State<MenuTile> createState() => _MenuTileState();
}

class _MenuTileState extends State<MenuTile> {
  bool _isFocused = false;
  bool _isHovered = false;

  // Single-line label. Long names scroll horizontally (marquee) while the tile
  // is focused instead of wrapping to a second line.
  Widget _buildLabel(BuildContext context) {
    final bool isImage = widget.imageAsset != null;
    final double fontSize = isImage
        ? (Theme.of(context).textTheme.titleMedium?.fontSize ?? 16)
        : (Theme.of(context).textTheme.headlineSmall?.fontSize ?? 24);
    final style = TextStyle(
      color: Colors.white,
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      shadows: const [
        Shadow(color: Colors.black45, offset: Offset(0, 2), blurRadius: 2),
      ],
    );
    // Tile is 200 wide; minus the 4px border each side and 8px padding each side.
    const double labelWidth = 200 - 8 - 16;
    final tp = TextPainter(
      text: TextSpan(text: widget.label, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final overflows = tp.width > labelWidth;
    tp.dispose();
    return SizedBox(
      width: labelWidth,
      height: fontSize * 1.5,
      child: (overflows && (_isFocused || _isHovered))
          ? Marquee(
              text: widget.label,
              style: style,
              velocity: 28,
              blankSpace: 40,
              startPadding: 0,
              pauseAfterRound: const Duration(milliseconds: 1200),
              accelerationDuration: const Duration(milliseconds: 300),
              decelerationDuration: const Duration(milliseconds: 300),
            )
          : Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: style,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = _isFocused || _isHovered;
    final double scale = isActive ? 1.1 : 1.0;
    final Color borderColor = isActive ? Colors.white : Colors.transparent;
    final double shadowOpacity = isActive ? 0.5 : 0.2;

    return Padding(
      padding: const EdgeInsets.all(10.0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        transform: Matrix4.identity()..scale(scale),
        transformAlignment: Alignment.center,
        width: 200,
        height: 150,
        decoration: BoxDecoration(
          gradient: widget.color,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: shadowOpacity),
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            autofocus: widget.autofocus,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onFocusChange: (value) => setState(() => _isFocused = value),
            onHover: (value) => setState(() => _isHovered = value),
            borderRadius: BorderRadius.circular(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.imageAsset != null)
                  Image.asset(
                    widget.imageAsset!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, __, ___) =>
                        Icon(widget.icon, color: Colors.white, size: 50),
                  )
                else
                  Icon(widget.icon, color: Colors.white, size: 50),
                const SizedBox(height: 8),
                _buildLabel(context),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

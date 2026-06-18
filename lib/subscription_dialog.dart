import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:open_tv/backend/identity_service.dart';
import 'package:open_tv/l10n/strings.dart';
import 'package:open_tv/pin_keypad.dart';

/// Subscription renewal payment, ported from the Smotrim.CZ launcher.
/// Two options: bank transfer (Czech "QR Platba" SPAYD) or card (SumUp link).

/// Payment details for the Smotrim.CZ subscription.
class _Payment {
  static const String accountNumber = "2200198639 / 2010";
  static const String ibanDisplay = "CZ47 2010 0000 0022 0019 8639";
  static const String iban = "CZ4720100000002200198639";
  static const String bic = "FIOBCZPPXXX";
  static const String phone = "+420608210867";

  /// Card payment links encoded into the QR on the "pay by card" page.
  static const String renewCardUrl = "https://pay.sumup.com/b2c/QZFA9XAV";
  static const String becomeCardUrl = "https://pay.sumup.com/b2c/Q2W3D0TB";

  /// Czech instant "QR Platba" (SPAYD) for the bank transfer. The subscriber ID
  /// goes into the X-VS (variabilní symbol) field so the payment is matched
  /// automatically; the PIN (new subscriber), email and phone go into the MSG
  /// (message) note. Payment type is instant (PT:IP).
  static String transferSpayd(
    String payerPhone,
    String subscriberId,
    String email,
    String amountSpayd, {
    String pin = '',
  }) {
    final id = subscriberId.replaceAll(RegExp(r'\D'), ''); // VS = digits only
    final phone = payerPhone.replaceAll(RegExp(r'[*\s]'), '');
    final mail = email.replaceAll(RegExp(r'[*\s]'), '');
    final pinClean = pin.replaceAll(RegExp(r'\D'), '');
    final msg = [
      if (id.isNotEmpty) 'ID:$id',
      if (pinClean.isNotEmpty) 'PIN:$pinClean',
      if (mail.isNotEmpty) 'Email:$mail',
      if (phone.isNotEmpty) 'Tel:$phone',
    ].join(' ');
    final vsPart = id.isEmpty ? '' : '*X-VS:$id';
    final msgPart = msg.isEmpty ? '' : '*MSG:$msg';
    return "SPD*1.0*ACC:$iban+$bic*AM:$amountSpayd*CC:CZK*PT:IP$vsPart$msgPart";
  }
}

enum _PayPage { menu, transfer, card }

/// Subscription dialog: a menu with two options (bank transfer / card), each
/// opening its own card. Fully navigable with the TV remote.
class SubscriptionDialog extends StatefulWidget {
  // false = "Renew subscription" (existing subscriber, 1000 Kč, device ID).
  // true  = "Become a subscriber" (new: 2800 Kč, fresh ID+PIN, activation note).
  final bool becomeSubscriber;
  const SubscriptionDialog({super.key, this.becomeSubscriber = false});

  @override
  State<SubscriptionDialog> createState() => _SubscriptionDialogState();
}

class _SubscriptionDialogState extends State<SubscriptionDialog> {
  _PayPage _page = _PayPage.menu;
  String _phone = "";
  String _id = "";
  String _pin = "";
  String _email = "";
  final ScrollController _scrollController = ScrollController();

  bool get _become => widget.becomeSubscriber;
  String get _amountDisplay => _become ? '2800 Kč' : '1000 Kč';
  String get _amountSpayd => _become ? '2800.00' : '1000.00';
  String get _cardUrl =>
      _become ? _Payment.becomeCardUrl : _Payment.renewCardUrl;

  @override
  void initState() {
    super.initState();
    if (_become) {
      // New subscriber: fresh ID + PIN, NOT saved until the user logs in.
      final c = IdentityService.generateCredentials();
      _id = c.id;
      _pin = c.pin;
    } else {
      // Renew: use the subscriber ID + PIN already stored in the player (the
      // PIN is only used in the payment note, not shown).
      IdentityService.getOrCreateId().then((id) {
        if (mounted) setState(() => _id = id);
      });
      IdentityService.getOrCreatePin().then((pin) {
        if (mounted) setState(() => _pin = pin);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _goTo(_PayPage page) {
    // Reset the scroll offset so each page opens from the top.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() => _page = page);
  }

  // D-pad handling for the payment pages: first try to move focus between the
  // focusable buttons; if there is nothing focusable further in that direction
  // (e.g. the read-only header, QR or notes), scroll the page instead — so the
  // user can always go back up to see the activation note / ID / PIN.
  KeyEventResult _handleScrollKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final TraversalDirection? dir = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    if (dir == null) return KeyEventResult.ignored;
    final moved =
        FocusManager.instance.primaryFocus?.focusInDirection(dir) ?? false;
    if (moved) return KeyEventResult.handled;
    if (!_scrollController.hasClients) return KeyEventResult.handled;
    final pos = _scrollController.position;
    final target = (_scrollController.offset +
            (dir == TraversalDirection.down ? 140.0 : -140.0))
        .clamp(0.0, pos.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  Future<void> _editPhone() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _TextEntryDialog(
        title: S.of(context).subscriptionYourPhone,
        initial: _phone,
        keyboardType: TextInputType.phone,
        icon: Icons.phone,
      ),
    );
    if (result != null && mounted) setState(() => _phone = result.trim());
  }

  Future<void> _editEmail() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _TextEntryDialog(
        title: S.of(context).yourEmail,
        initial: _email,
        keyboardType: TextInputType.emailAddress,
        icon: Icons.email,
      ),
    );
    if (result != null && mounted) setState(() => _email = result.trim());
  }

  // 8-digit numeric keypad (reliable on the TV box).
  Future<void> _editId() async {
    final v = await showPinKeypad(
      context,
      title: S.of(context).yourId,
      length: subscriberIdLength,
    );
    if (v != null && mounted) setState(() => _id = v);
  }

  @override
  Widget build(BuildContext context) {
    final l = S.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FocusTraversalGroup(
            child: switch (_page) {
              _PayPage.menu => _menuPage(context, l),
              _PayPage.transfer => _transferPage(context, l),
              _PayPage.card => _cardPage(context, l),
            },
          ),
        ),
      ),
    );
  }

  // ---- Pages ---------------------------------------------------------------

  Widget _menuPage(BuildContext context, S l) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, _become ? l.becomeSubscriber : l.subscriptionDialogTitle),
        const SizedBox(height: 16),
        if (_become) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              l.becomeMenuNote,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
        ],
        _MenuButton(
          icon: Icons.account_balance,
          label: l.payByTransfer,
          autofocus: true,
          onPressed: () => _goTo(_PayPage.transfer),
        ),
        const SizedBox(height: 12),
        _MenuButton(
          icon: Icons.credit_card,
          label: l.payByCard,
          onPressed: () => _goTo(_PayPage.card),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: _TextButtonFocusable(
            label: l.close,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }

  Widget _transferPage(BuildContext context, S l) {
    final spayd = _Payment.transferSpayd(
      _phone,
      _id,
      _email,
      _amountSpayd,
      pin: _become ? _pin : '',
    );
    return _scrollPage(
      context,
      title: l.payByTransfer,
      body: [
        if (_become) ..._becomeHeader(context, l),
        _MenuButton(
          icon: Icons.phone,
          label: _phone.isEmpty ? l.subscriptionYourPhone : _phone,
          onPressed: _editPhone,
        ),
        const SizedBox(height: 12),
        // Renew: the device ID is editable. Become: the ID is freshly generated
        // and shown read-only in the header above.
        if (!_become) ...[
          _MenuButton(
            icon: Icons.badge,
            label: _id.isEmpty ? l.yourId : '${l.yourId} (VS): $_id',
            onPressed: _editId,
          ),
          const SizedBox(height: 12),
        ],
        _MenuButton(
          icon: Icons.email,
          label: _email.isEmpty ? l.yourEmail : _email,
          onPressed: _editEmail,
        ),
        const SizedBox(height: 16),
        _row(context, l.subscriptionAmountLabel, _amountDisplay, bold: true),
        _row(context, l.subscriptionAccountLabel, _Payment.accountNumber),
        _row(context, l.subscriptionIbanLabel, _Payment.ibanDisplay),
        _row(context, l.subscriptionBicLabel, _Payment.bic),
        const SizedBox(height: 12),
        _qr(spayd),
        const SizedBox(height: 8),
        Center(
          child: Text(
            l.subscriptionScanToPay,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const Divider(height: 24),
        _note(context, Icons.schedule, l.subscriptionProcessingHours),
        _note(
          context,
          Icons.support_agent,
          "${l.subscriptionContactLabel}: ${_Payment.phone}",
        ),
      ],
      footer: [
        _TextButtonFocusable(label: l.back, onPressed: () => _goTo(_PayPage.menu)),
        _TextButtonFocusable(
          label: l.close,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _cardPage(BuildContext context, S l) {
    return _scrollPage(
      context,
      title: l.payByCard,
      body: [
        if (_become) ..._becomeHeader(context, l),
        _qr(_cardUrl),
        const SizedBox(height: 8),
        Center(
          child: Text(
            l.subscriptionScanToPay,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 12),
        if (!_become) _row(context, l.yourId, _id),
        _note(context, Icons.percent, l.subscriptionCardCommission),
        _note(context, Icons.info_outline, l.subscriptionCardPhoneNote),
        _note(context, Icons.schedule, l.subscriptionProcessingHours),
      ],
      footer: [
        _TextButtonFocusable(
          label: l.back,
          onPressed: () => _goTo(_PayPage.menu),
        ),
        _TextButtonFocusable(
          label: l.close,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  // Header shown only for "become a subscriber": the activation note (first
  // position) plus the freshly generated ID and PIN to save.
  List<Widget> _becomeHeader(BuildContext context, S l) {
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(l.becomeNote, style: Theme.of(context).textTheme.bodyMedium),
      ),
      const SizedBox(height: 12),
      _row(context, l.yourId, _id, bold: true),
      _row(context, l.yourPin, _pin, bold: true),
      _note(context, Icons.save_alt, l.becomeSaveCredentials),
      const SizedBox(height: 8),
    ];
  }

  // ---- Building blocks -----------------------------------------------------

  Widget _scrollPage(
    BuildContext context, {
    required String title,
    required List<Widget> body,
    required List<Widget> footer,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, title),
        const SizedBox(height: 12),
        Flexible(
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _handleScrollKey,
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...body,
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: footer,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _title(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.titleLarge);

  Widget _qr(String data) => Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: QrImageView(
            data: data,
            version: QrVersions.auto,
            size: 160,
            backgroundColor: Colors.white,
          ),
        ),
      );

  Widget _row(BuildContext context, String label, String value,
      {bool bold = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Collects a text value (phone / email). On this TV box the soft keyboard only
/// opens on a tap / focus push, so the field forces it open when focused.
class _TextEntryDialog extends StatefulWidget {
  final String title;
  final String initial;
  final TextInputType keyboardType;
  final IconData icon;
  const _TextEntryDialog({
    required this.title,
    required this.initial,
    required this.keyboardType,
    required this.icon,
  });

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        SystemChannels.textInput.invokeMethod('TextInput.show');
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = S.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        keyboardType: widget.keyboardType,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.of(context).pop(value),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          prefixIcon: Icon(widget.icon),
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        _TextButtonFocusable(
          label: l.close,
          onPressed: () => Navigator.of(context).pop(),
        ),
        _TextButtonFocusable(
          label: l.save,
          onPressed: () => Navigator.of(context).pop(_controller.text),
        ),
      ],
    );
  }
}

/// Large focusable menu button (remote-friendly).
class _MenuButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent:
            CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed()),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) => widget.onPressed()),
      },
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (hasFocus) {
          setState(() => _focused = hasFocus);
          if (hasFocus) {
            Scrollable.ensureVisible(context,
                alignment: 0.5, duration: const Duration(milliseconds: 150));
          }
        },
        child: Material(
          color: _focused ? accent : accent.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: _focused ? Colors.white : accent, width: 2),
              ),
              child: Row(
                children: [
                  Icon(widget.icon, color: Colors.white, size: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Focusable text button used for Back/Close/Save (remote-friendly).
class _TextButtonFocusable extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  const _TextButtonFocusable({
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  @override
  State<_TextButtonFocusable> createState() => _TextButtonFocusableState();
}

class _TextButtonFocusableState extends State<_TextButtonFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent:
            CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed()),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) => widget.onPressed()),
      },
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (hasFocus) {
          setState(() => _focused = hasFocus);
          if (hasFocus) {
            Scrollable.ensureVisible(context,
                alignment: 0.5, duration: const Duration(milliseconds: 150));
          }
        },
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: _focused ? accent.withValues(alpha: 0.25) : Colors.transparent,
              border: Border.all(
                  color: _focused ? accent : Colors.transparent, width: 2),
            ),
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

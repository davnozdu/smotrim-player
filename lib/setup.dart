import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:animations/animations.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/proxy_installer.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:loader_overlay/loader_overlay.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/correction_modal.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/restore_login.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/steps.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/l10n/strings.dart';

enum _ProxyStatus { unknown, checking, online, offline }

class Setup extends StatefulWidget {
  final bool showAppBar;
  const Setup({super.key, this.showAppBar = false});

  @override
  State<Setup> createState() => _SetupState();
}

class _SetupState extends State<Setup> {
  Steps step = Steps.welcome;
  SourceType selectedSourceType = SourceType.xtream;
  bool isForward = true;
  bool formValid = false;
  final Map<Steps, FocusNode> focusNodes = {
    Steps.name: FocusNode(),
    Steps.url: FocusNode(),
    Steps.username: FocusNode(),
    Steps.password: FocusNode(),
  };
  final formPages = {Steps.name, Steps.url, Steps.username, Steps.password};
  final _formKeys = {
    Steps.name: GlobalKey<FormBuilderState>(),
    Steps.url: GlobalKey<FormBuilderState>(),
    Steps.username: GlobalKey<FormBuilderState>(),
    Steps.password: GlobalKey<FormBuilderState>(),
  };
  final formValues = {
    Steps.name: "",
    Steps.url: "",
    Steps.username: "",
    Steps.password: "",
  };
  final nextButtonFocusNode = FocusNode();
  Set<String> existingSourceNames = {};

  // HLS-PROXY: three pre-filled values (IP, port, playlist) combined into one
  // playlist URL. Edited via a popup so D-pad navigation between them never
  // pops the keyboard.
  final proxyIpCtrl = TextEditingController(text: 'http://127.0.0.1');
  final proxyPortCtrl = TextEditingController(text: '9393');
  final proxyPlaylistCtrl = TextEditingController(text: 'playlist.m3u8');

  Timer? _proxyDebounce;
  _ProxyStatus _proxyStatus = _ProxyStatus.unknown;
  bool _proxyInstalled = false;

  bool get _isProxy => selectedSourceType == SourceType.hlsProxy;

  // Host only (strip scheme / port / path) — for the port-open check.
  String _proxyHost() {
    var ip = proxyIpCtrl.text.trim();
    ip = ip.replaceAll(RegExp(r'^https?://'), '');
    ip = ip.replaceAll(RegExp(r'/.*$'), '');
    ip = ip.replaceAll(RegExp(r':\d+$'), '');
    return ip;
  }

  // Checks whether something is listening on the proxy host:port.
  Future<void> _checkProxy() async {
    final host = _proxyHost();
    final port = int.tryParse(proxyPortCtrl.text.trim());
    if (host.isEmpty || port == null) {
      if (mounted) {
        setState(() {
          _proxyStatus = _ProxyStatus.offline;
          formValid = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _proxyStatus = _ProxyStatus.checking;
      formValid = false;
    });
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      if (mounted) {
        setState(() {
          _proxyStatus = _ProxyStatus.online;
          formValid = _proxyReady();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && step == Steps.url && _isProxy && _proxyReady()) {
            nextButtonFocusNode.requestFocus();
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _proxyStatus = _ProxyStatus.offline;
          formValid = false;
        });
      }
    }
  }

  void _scheduleProxyCheck() {
    _proxyDebounce?.cancel();
    _proxyDebounce = Timer(const Duration(milliseconds: 600), _checkProxy);
  }

  // Called when the proxy page becomes visible.
  Future<void> _onEnterProxy() async {
    final installed = await ProxyInstaller.isInstalled();
    if (mounted) setState(() => _proxyInstalled = installed);
    await _checkProxy();
  }

  bool _proxyValid() =>
      proxyIpCtrl.text.trim().isNotEmpty &&
      proxyPortCtrl.text.trim().isNotEmpty &&
      proxyPlaylistCtrl.text.trim().isNotEmpty;

  bool _proxyReady() => _proxyValid() && _proxyStatus == _ProxyStatus.online;

  bool _isTextFormStep(Steps s) =>
      formPages.contains(s) && !(_isProxy && s == Steps.url);

  bool _canGoNext() {
    if (!formPages.contains(step)) return true;
    if (_isProxy && step == Steps.url) return _proxyReady();
    return formValid;
  }

  String _proxyUrl() {
    var ip = proxyIpCtrl.text.trim();
    if (!ip.startsWith('http')) ip = 'http://$ip';
    ip = ip.replaceAll(RegExp(r'/+$'), '');
    final port = proxyPortCtrl.text.trim();
    final pl = proxyPlaylistCtrl.text.trim().replaceAll(RegExp(r'^/+'), '');
    return '$ip:$port/$pl';
  }

  Future<void> finish() async {
    var result = await Error.tryAsync(
      () async {
        await Utils.processSource(
          Source(
            name: formValues[Steps.name]!,
            sourceType: selectedSourceType,
            url: selectedSourceType == SourceType.m3u
                ? formValues[Steps.url]!
                : _isProxy
                ? _proxyUrl()
                : await fixUrl(formValues[Steps.url]!),
            username: selectedSourceType == SourceType.xtream
                ? formValues[Steps.username]
                : null,
            password: selectedSourceType == SourceType.xtream
                ? formValues[Steps.password]
                : null,
          ),
        );
      },
      context,
      null,
      true,
      false,
    );
    if (!result.success) {
      return;
    }
    // Switch to the just-added playlist so the device shows it right away
    // (instead of merging every enabled source).
    await Error.tryAsyncNoLoading(
      () async => await Sql.activateOnlySource(formValues[Steps.name]!),
      context,
    );
    setState(() {
      step = Steps.finish;
    });
  }

  Future<String> fixUrl(String url) async {
    var uri = Uri.parse(url);
    if (uri.scheme.isEmpty) {
      uri = Uri.parse("http://$uri");
    }
    if (uri.path == "/" || uri.path.isEmpty) {
      if (await showXtreamCorrectionModal()) {
        uri = uri.resolve("player_api.php");
      }
    }
    return uri.toString();
  }

  Future showXtreamCorrectionModal() async {
    return await showDialog(
      context: context,
      builder: (context) => CorrectionModal(),
    );
  }

  @override
  void initState() {
    nextButtonFocusNode.requestFocus();
    // TV remotes: this box only opens the keyboard on a touch tap, and a focused
    // text field traps the D-pad (arrows move the caret). So on the form fields:
    //  • OK/Enter opens the keyboard;
    //  • Up/Down move focus out of the field instead of being swallowed.
    for (final node in focusNodes.values) {
      node.onKeyEvent = (n, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.gameButtonA) {
          SystemChannels.textInput.invokeMethod('TextInput.show');
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowDown) {
          n.unfocus();
          nextButtonFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowUp) {
          n.unfocus();
          n.previousFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      };
    }
    super.initState();
  }

  // Edits one proxy value in a popup (its own field autofocuses and reliably
  // opens the keyboard); navigating the value buttons stays keyboard-free.
  Future<void> _editProxyValue(
    TextEditingController ctrl,
    String label,
    TextInputType keyboard,
  ) async {
    final tmp = TextEditingController(text: ctrl.text);
    final focus = FocusNode();
    // This box only opens the keyboard on a tap, so force it open when the
    // popup field gets focus.
    focus.addListener(() {
      if (focus.hasFocus) {
        SystemChannels.textInput.invokeMethod('TextInput.show');
      }
    });
    final s = S.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: tmp,
          focusNode: focus,
          autofocus: true,
          autocorrect: false,
          keyboardType: keyboard,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(tmp.text),
            child: Text(s.ok),
          ),
        ],
      ),
    );
    tmp.dispose();
    focus.dispose();
    if (result != null) {
      setState(() {
        ctrl.text = result.trim();
        formValid = _proxyValid();
        _proxyStatus = _ProxyStatus.unknown;
      });
      _checkProxy();
    }
  }

  @override
  void dispose() {
    for (var focus in focusNodes.values) {
      focus.dispose();
    }
    nextButtonFocusNode.dispose();
    proxyIpCtrl.dispose();
    proxyPortCtrl.dispose();
    proxyPlaylistCtrl.dispose();
    _proxyDebounce?.cancel();
    super.dispose();
  }

  // When the user confirms a text field with the on-screen keyboard
  // (IME "next"/done), move focus straight to the Next button instead of
  // leaving it stuck in the field. Big help for D-pad / TV remotes.
  void onFieldSubmitted(Steps s) {
    final valid = _formKeys[s]?.currentState?.isValid == true;
    if (!valid) return;
    setState(() => formValid = true);
    
    // Explicitly unfocus to hide keyboard and then focus next button
    FocusManager.instance.primaryFocus?.unfocus();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) nextButtonFocusNode.requestFocus();
    });
  }

  Future<bool> selectFile() async {
    var path = (await FilePicker.platform.pickFiles())?.files.single.path;
    if (path == null) return false;
    formValues[Steps.url] = path;
    return true;
  }

  void prevStep() {
    isForward = false;
    if (_isTextFormStep(step)) {
      formValues[step] =
          _formKeys[step]?.currentState?.fields[step.name]?.value;
    }
    setState(() {
      step = Steps.values[step.index - 1];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        if (_isProxy && step == Steps.url) {
          formValid = _proxyValid();
        } else {
          formValid = _formKeys[step]?.currentState?.isValid == true;
        }
      });
      if (_isProxy && step == Steps.url) {
        _onEnterProxy();
      } else if (formPages.contains(step)) {
        focusNodes[step]?.requestFocus();
      }
      if (step == Steps.welcome) {
        nextButtonFocusNode.requestFocus();
      }
    });
  }

  Future<void> handleNext() async {
    isForward = true;
    if (_isTextFormStep(step)) {
      formValues[step] =
          _formKeys[step]?.currentState?.fields[step.name]?.value;
    }
    if (step == Steps.name) {
      var sourceName = formValues[step]!;
      if (await Sql.sourceNameExists(sourceName)) {
        existingSourceNames.add(sourceName);
        _formKeys[step]?.currentState?.validate();
        return;
      }
    }
    if (step == Steps.name && selectedSourceType == SourceType.m3u) {
      if (!await selectFile()) return;
      finish();
    } else if ((selectedSourceType == SourceType.m3uUrl && step == Steps.url) ||
        (_isProxy && step == Steps.url) ||
        step == Steps.password) {
      finish();
    } else if (step == Steps.finish) {
      navigateToHome();
    } else {
      setState(() {
        step = Steps.values[step.index + 1];
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          if (_isProxy && step == Steps.url) {
            formValid = _proxyReady();
          } else {
            if (formValues[step]?.isNotEmpty == true) {
              _formKeys[step]?.currentState?.validate();
            }
            formValid = _formKeys[step]?.currentState?.isValid == true;
          }
        });
        if (_isProxy && step == Steps.url) {
          _onEnterProxy();
        } else if (formPages.contains(step)) {
          focusNodes[step]?.requestFocus();
        }
      });
    }
  }

  // "Restore playlist" tile in the source-type step: opens the ID + PIN flow.
  // On success it imports the playlist and enters the app (no "skip" button —
  // the user is already in the wizard and can just go back).
  void _openRestore() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RestoreLoginPage(showSkip: false)),
    );
  }

  void navigateToHome() {
    // Adding a playlist from inside the app (showAppBar): just return to the
    // existing shell (the launcher menu / catalog root) — the new playlist is
    // already active. Don't replace the whole stack, which destroyed the TV
    // menu and left a stray catalog screen.
    if (widget.showAppBar) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    // First-launch setup: start the app.
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => Home(
          home: HomeManager(filters: Filters(viewType: ViewType.all)),
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: step == Steps.welcome,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final focus = FocusManager.instance.primaryFocus;
        final isEditing =
            focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null;
        if (isEditing) {
          focus?.unfocus();
          focus?.nextFocus();
          return;
        }
        prevStep();
      },
      child: Scaffold(
        appBar: widget.showAppBar ? AppBar() : null,
        body: SafeArea(
          child: LoaderOverlay(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 16,
                  ),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: (step.index + 1) / Steps.values.length,
                    ),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeInOut,
                    builder: (context, value, child) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: value,
                          minHeight: 6,
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: PageTransitionSwitcher(
                    duration: const Duration(milliseconds: 400),
                    reverse: !isForward,
                    transitionBuilder:
                        (child, primaryAnimation, secondaryAnimation) {
                          return SharedAxisTransition(
                            animation: primaryAnimation,
                            secondaryAnimation: secondaryAnimation,
                            transitionType: SharedAxisTransitionType.horizontal,
                            child: child,
                          );
                        },
                    child: currentPage,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        AnimatedOpacity(
                          opacity: step != Steps.welcome && step != Steps.finish
                              ? 1
                              : 0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          child: IgnorePointer(
                            ignoring:
                                step == Steps.welcome || step == Steps.finish,
                            child: FocusTraversalOrder(
                              order: NumericFocusOrder(2.0),
                              child: FilledButton.tonal(
                                onPressed: prevStep,
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 16,
                                  ),
                                ),
                                child: Text(
                                  S.of(context).back,
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                            ),
                          ),
                        ),
                        FocusTraversalOrder(
                          order: NumericFocusOrder(1.0),
                          child: FilledButton(
                            focusNode: nextButtonFocusNode,
                            onPressed: _canGoNext() ? handleNext : null,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                            ),
                            child: Text(
                              step == Steps.name &&
                                      selectedSourceType == SourceType.m3u
                                  ? S.of(context).selectFile
                                  : step == Steps.finish
                                  ? S.of(context).finish
                                  : S.of(context).next,
                              style: const TextStyle(fontSize: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget get currentPage {
    switch (step) {
      case Steps.welcome:
        return getPage(
          S.of(context).welcomeTitle("Smotrim CZ Player"),
          S.of(context).welcomeSub(!widget.showAppBar),
          null,
        );
      case Steps.sourceType:
        final tiles = <Widget>[
          ...List.generate(SourceType.values.length, (i) {
            return Card(
              color: selectedSourceType.index == i
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).cardTheme.color,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 2,
              child: ListTile(
                autofocus: selectedSourceType.index == i,
                title: Text((SourceType.values[i]).label),
                onTap: () {
                  setState(() {
                    formValues[Steps.url] = "";
                    selectedSourceType = SourceType.values[i];
                  });
                },
              ),
            );
          }),
          // Restore an existing playlist by subscriber ID + PIN (same flow as
          // the login screen). Down from here moves focus to the Next button.
          Focus(
            canRequestFocus: false,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.arrowDown) {
                nextButtonFocusNode.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 2,
              child: ListTile(
                leading: const Icon(Icons.cloud_download),
                title: Text(S.of(context).restorePlaylist),
                subtitle: Text(S.of(context).restorePlaylistSub),
                onTap: _openRestore,
              ),
            ),
          ),
        ];
        return getPage(S.of(context).providerType, null, tiles);
      case Steps.name:
        return getPage(S.of(context).nameQuestion, null, [
          FormBuilder(
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.name]!.currentState?.isValid == true;
                });
              });
            },
            initialValue: {Steps.name.name: formValues[Steps.name]},
            key: _formKeys[Steps.name],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.name],
              onSubmitted: (_) => onFieldSubmitted(Steps.name),
              decoration: InputDecoration(
                labelText: S.of(context).name,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label_outline),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.compose([
                FormBuilderValidators.required(),
                (value) {
                  var trimmed = value?.trim();
                  if (trimmed == null || trimmed.isEmpty) {
                    return null;
                  }
                  if (existingSourceNames.contains(trimmed)) {
                    return S.of(context).nameExists;
                  }
                  return null;
                },
              ]),
              name: 'name',
            ),
          ),
        ]);
      case Steps.url:
        if (_isProxy) return _proxyPage();
        return getPage(S.of(context).urlQuestion, null, [
          FormBuilder(
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.url]!.currentState?.isValid == true;
                });
              });
            },
            initialValue: {Steps.url.name: formValues[Steps.url]},
            key: _formKeys[Steps.url],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.url],
              onSubmitted: (_) => onFieldSubmitted(Steps.url),
              decoration: InputDecoration(
                labelText: S.of(context).url,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.required(),
              name: 'url',
            ),
          ),
        ]);
      case Steps.username:
        return getPage(S.of(context).usernameQuestion, null, [
          FormBuilder(
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.username]!.currentState?.isValid == true;
                });
              });
            },
            initialValue: {Steps.username.name: formValues[Steps.username]},
            key: _formKeys[Steps.username],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.username],
              onSubmitted: (_) => onFieldSubmitted(Steps.username),
              decoration: InputDecoration(
                labelText: S.of(context).username,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.required(),
              name: 'username',
            ),
          ),
        ]);
      case Steps.password:
        return getPage(S.of(context).passwordQuestion, null, [
          FormBuilder(
            initialValue: {Steps.password.name: formValues[Steps.password]},
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                setState(() {
                  formValid =
                      _formKeys[Steps.password]!.currentState?.isValid == true;
                });
              });
            },
            key: _formKeys[Steps.password],
            child: FormBuilderTextField(
              autocorrect: false,
              focusNode: focusNodes[Steps.password],
              onSubmitted: (_) => onFieldSubmitted(Steps.password),
              decoration: InputDecoration(
                labelText: S.of(context).password,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.password),
              ),
              textInputAction: TextInputAction.next,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: FormBuilderValidators.required(),
              name: 'password',
            ),
          ),
        ]);
      case Steps.finish:
        return getPage(S.of(context).doneTitle, S.of(context).doneSub, null);
    }
  }

  // HLS-PROXY page: narrow value column on the left, server status on the right.
  Widget _proxyPage() {
    final s = S.of(context);
    return getPage(s.hlsProxyQuestion, null, [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left: the three values (as buttons) + the resulting link.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _proxyValueRow(
                  proxyIpCtrl,
                  s.hlsProxyIp,
                  Icons.lan,
                  TextInputType.url,
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                _proxyValueRow(
                  proxyPortCtrl,
                  s.hlsProxyPort,
                  Icons.numbers,
                  TextInputType.number,
                ),
                const SizedBox(height: 8),
                _proxyValueRow(
                  proxyPlaylistCtrl,
                  s.hlsProxyPlaylist,
                  Icons.playlist_play,
                  TextInputType.text,
                ),
                const SizedBox(height: 10),
                Text(
                  _proxyUrl(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          // Right: server status + install/update button.
          Expanded(child: Center(child: _proxyStatusBlock())),
        ],
      ),
    ]);
  }

  // A value shown as a focusable button; OK opens a popup to edit it (keyboard
  // appears only there). D-pad moves between the buttons without any keyboard.
  Widget _proxyValueRow(
    TextEditingController ctrl,
    String label,
    IconData icon,
    TextInputType keyboard, {
    bool autofocus = false,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        autofocus: autofocus,
        dense: true,
        leading: Icon(icon),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          ctrl.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
        trailing: const Icon(Icons.edit, size: 18),
        onTap: () => _editProxyValue(ctrl, label, keyboard),
      ),
    );
  }

  // Server status under the fields: online / offline (+ install button & notes).
  Widget _proxyStatusBlock() {
    final s = S.of(context);
    switch (_proxyStatus) {
      case _ProxyStatus.checking:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(s.proxyChecking),
          ],
        );
      case _ProxyStatus.online:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                s.proxyOnline,
                style: const TextStyle(color: Colors.green),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: s.proxyRecheck,
              onPressed: _checkProxy,
            ),
          ],
        );
      case _ProxyStatus.offline:
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    s.proxyOffline,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: s.proxyRecheck,
                  onPressed: _checkProxy,
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () async {
                await ProxyInstaller.installOrUpdate(context);
                if (mounted) _onEnterProxy();
              },
              icon: const Icon(Icons.download),
              label: Text(_proxyInstalled ? s.proxyUpdate : s.proxyInstall),
            ),
            const SizedBox(height: 8),
            Text(
              s.proxyAfterInstall,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        );
      case _ProxyStatus.unknown:
        return TextButton.icon(
          onPressed: _checkProxy,
          icon: const Icon(Icons.refresh),
          label: Text(s.proxyRecheck),
        );
    }
  }

  Widget getPage(
    final String title,
    final String? subtitle,
    final List<Widget>? content,
  ) {
    return Center(
      key: ValueKey(title),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 20),
                textAlign: TextAlign.center,
              ),
            ],
            if (content != null) ...[const SizedBox(height: 24), ...content],
          ],
        ),
      ),
    );
  }
}

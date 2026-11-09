// HX: send one command to several PCs at once.
// For each selected PC a hidden terminal connection is opened (the remote
// terminal feature, PowerShell on Windows), the command is typed, and the output
// is collected until a marker line appears. It runs with the rights of the user
// logged on at that PC, not as administrator. PCs need a saved password (connect
// once with "remember password"), because no password dialog is shown here.
import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../models/model.dart';
import '../models/peer_model.dart';
import '../models/platform_model.dart';
import '../models/terminal_model.dart';
import '../utils/multi_window_manager.dart';

const _kDone = '__HX_DONE__';
// Typed after the command. The marker is built from two strings so that the echo
// of this line never contains it; only the real output does.
const _kDoneCmd = "Write-Output ('__HX' + '_DONE__')";
const _kTerminalId = 1;

class HxBatchResult {
  final String id;
  final String name;
  final RxString state = '대기'.obs;
  final RxString output = ''.obs;
  final RxBool done = false.obs;
  final RxBool ok = false.obs;
  HxBatchResult(this.id, this.name);
}

class _BatchTerminal extends TerminalModel {
  final void Function(String type, Map<String, dynamic> evt) onEvt;
  _BatchTerminal(FFI parent, this.onEvt) : super(parent, _kTerminalId);

  @override
  void onReady() {
    openTerminal().catchError((_) {});
  }

  @override
  void handleTerminalResponse(Map<String, dynamic> evt) {
    if (TerminalModel.getTerminalIdFromEvt(evt) != terminalId) return;
    onEvt(evt['type']?.toString() ?? '', evt);
  }
}

String _decode(dynamic data) {
  if (data is! String) return '';
  try {
    return utf8.decode(base64Decode(data), allowMalformed: true);
  } catch (_) {
    return data;
  }
}

String _clean(String s) {
  s = s
      .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(\x07|\x1B\\)'), '')
      .replaceAll(RegExp(r'\x1B[@-Z\\-_]'), '')
      .replaceAll('\r\n', '\n');
  return s
      .split('\n')
      .map((l) => l.contains('\r') ? l.split('\r').last : l)
      .join('\n');
}

String _result(String clean) {
  final i = clean.indexOf(_kDone);
  final body = i >= 0 ? clean.substring(0, i) : clean;
  final lines = body
      .split('\n')
      .where((l) => !l.contains("'__HX'"))
      .toList();
  // drop the prompt left on the last line
  while (lines.isNotEmpty &&
      (lines.last.trim().isEmpty || RegExp(r'^PS .*>\s*$').hasMatch(lines.last.trim()))) {
    lines.removeLast();
  }
  var out = lines.join('\n').trim();
  if (out.length > 20000) out = '...\n${out.substring(out.length - 20000)}';
  return out;
}

Future<void> hxRunOnPeer(HxBatchResult r, String command,
    {Duration timeout = const Duration(seconds: 90)}) async {
  if (!await bind.mainPeerHasPassword(id: r.id)) {
    r.state.value = '건너뜀: 비밀번호가 저장되지 않음 (한 번 접속하며 "비밀번호 기억" 체크)';
    r.done.value = true;
    return;
  }
  final ffi = FFI(null);
  final buf = StringBuffer();
  final completer = Completer<String>();
  var opened = false;
  final model = _BatchTerminal(ffi, (type, evt) {
    switch (type) {
      case 'opened':
        if (TerminalModel.getSuccessFromEvt(evt)) {
          opened = true;
          r.state.value = '실행 중';
          bind.sessionSendTerminalInput(
              sessionId: ffi.sessionId,
              terminalId: _kTerminalId,
              data: '$command\r$_kDoneCmd\r');
        } else if (!completer.isCompleted) {
          completer.completeError('터미널을 열 수 없음: ${evt['message'] ?? ''}');
        }
        break;
      case 'data':
        buf.write(_decode(evt['data']));
        final clean = _clean(buf.toString());
        r.output.value = _result(clean);
        if (clean.contains(_kDone) && !completer.isCompleted) {
          completer.complete(clean);
        }
        break;
      case 'closed':
        if (!completer.isCompleted) completer.complete(_clean(buf.toString()));
        break;
      case 'error':
        if (!completer.isCompleted) {
          completer.completeError('오류: ${evt['message'] ?? ''}');
        }
        break;
    }
  });
  r.state.value = '연결 중';
  try {
    ffi.start(r.id, isTerminal: true);
    ffi.registerTerminalModel(_kTerminalId, model);
    final out = await completer.future.timeout(timeout);
    r.output.value = _result(out);
    r.ok.value = true;
    r.state.value = '완료';
  } on TimeoutException {
    r.state.value = opened ? '시간 초과: 명령이 90초 안에 안 끝남' : '연결 실패: 꺼져 있거나 응답 없음';
  } catch (e) {
    r.state.value = e.toString();
  } finally {
    if (opened) {
      try {
        await bind
            .sessionCloseTerminal(sessionId: ffi.sessionId, terminalId: _kTerminalId)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await ffi.close();
    } catch (_) {}
    r.done.value = true;
  }
}

// Saved commands (name, command), kept in the local option below as JSON.
const _kSavedKey = 'hx-batch-commands';
const List<List<String>> _kDefaultCommands = [
  [
    '디스크 여유',
    r"Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{n='FreeGB';e={[int]($_.Free/1GB)}},@{n='UsedGB';e={[int]($_.Used/1GB)}} | Format-Table -AutoSize | Out-String -Width 200"
  ],
  [
    '켜진 프로그램',
    r"Get-Process | Where-Object MainWindowTitle | Sort-Object ProcessName | Select-Object ProcessName,MainWindowTitle | Format-Table -AutoSize | Out-String -Width 200"
  ],
  [
    'IP 주소',
    r"Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notlike '127.*' | Select-Object InterfaceAlias,IPAddress | Format-Table -AutoSize | Out-String -Width 200"
  ],
  [
    '켜진 시간',
    r"$b=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime; 'boot: ' + $b + '  (' + [int]((Get-Date)-$b).TotalHours + ' h ago)'"
  ],
];

List<List<String>> _loadSaved() {
  try {
    final raw = bind.mainGetLocalOption(key: _kSavedKey);
    if (raw.isNotEmpty) {
      return (jsonDecode(raw) as List)
          .map((e) => (e as List).map((x) => x.toString()).toList())
          .where((e) => e.length == 2)
          .toList();
    }
  } catch (_) {}
  return _kDefaultCommands.map((e) => List<String>.from(e)).toList();
}

void _storeSaved(List<List<String>> v) {
  bind.mainSetLocalOption(key: _kSavedKey, value: jsonEncode(v));
}

/// Dialog: one command for the selected PCs, results per PC.
void hxShowBatchCommandDialog(List<Peer> peers) {
  final cmd = TextEditingController();
  final results = <HxBatchResult>[].obs;
  final running = false.obs;
  final saved = _loadSaved().obs;
  gFFI.dialogManager.show((setState, close, context) {
    Future<void> run() async {
      final c = cmd.text.trim();
      if (c.isEmpty || running.value) return;
      running.value = true;
      results.assignAll(peers
          .map((p) => HxBatchResult(p.id, p.alias.isNotEmpty ? p.alias : p.id)));
      await Future.wait(results.map((r) => hxRunOnPeer(r, c)));
      running.value = false;
    }

    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return CustomAlertDialog(
      title: Text('명령 보내기 (${peers.length}대)'),
      contentBoxConstraints: const BoxConstraints(maxWidth: 820),
      content: SizedBox(
        width: 780,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '고른 PC마다 원격 터미널(윈도우는 PowerShell)에서 실행하고 결과를 모읍니다. '
              '그 PC에 로그인한 사용자 권한이며 관리자 권한은 아닙니다. '
              '비밀번호가 저장된 PC만 실행됩니다.',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 8),
            // saved commands: click to fill, x to remove
            Obx(() => Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (var i = 0; i < saved.length; i++)
                      InputChip(
                        label: Text(saved[i][0],
                            style: const TextStyle(fontSize: 12)),
                        tooltip: saved[i][1],
                        onPressed: () {
                          cmd.text = saved[i][1];
                          cmd.selection = TextSelection.collapsed(
                              offset: cmd.text.length);
                        },
                        onDeleted: () {
                          saved.removeAt(i);
                          _storeSaved(saved.toList());
                        },
                        deleteIconColor: Colors.grey,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                )),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: cmd,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    style: mono,
                    decoration: const InputDecoration(
                      hintText:
                          r'예: hostname; Get-PSDrive C | Select-Object Used,Free',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => run(),
                  ),
                ),
                // explicit paste: Cmd+V did not reach this field in a test
                IconButton(
                  tooltip: '붙여넣기',
                  icon: const Icon(Icons.content_paste, size: 18),
                  onPressed: () async {
                    final d = await Clipboard.getData(Clipboard.kTextPlain);
                    final t = d?.text ?? '';
                    if (t.isEmpty) return;
                    final sel = cmd.selection;
                    final start = sel.isValid ? sel.start : cmd.text.length;
                    final end = sel.isValid ? sel.end : cmd.text.length;
                    cmd.text = cmd.text.replaceRange(start, end, t);
                    cmd.selection =
                        TextSelection.collapsed(offset: start + t.length);
                  },
                ),
                IconButton(
                  tooltip: '이 명령 저장',
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  onPressed: () {
                    final c = cmd.text.trim();
                    if (c.isEmpty) return;
                    if (saved.any((e) => e[1] == c)) return;
                    final name = c.length > 18 ? '${c.substring(0, 18)}…' : c;
                    saved.add([name, c]);
                    _storeSaved(saved.toList());
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Obx(() => ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 440),
                  child: ListView(
                    shrinkWrap: true,
                    children: results
                        .map((r) => Obx(() => ExpansionTile(
                              initiallyExpanded: true,
                              tilePadding: EdgeInsets.zero,
                              leading: r.done.value
                                  ? Icon(
                                      r.ok.value
                                          ? Icons.check_circle
                                          : Icons.error_outline,
                                      color: r.ok.value
                                          ? Colors.green
                                          : Colors.orange,
                                      size: 18)
                                  : const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                              title: Text('${r.name}   ${r.state.value}',
                                  style: const TextStyle(fontSize: 13)),
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(8),
                                  color: Colors.black12,
                                  child: SelectableText(
                                      r.output.value.isEmpty
                                          ? '(출력 없음)'
                                          : r.output.value,
                                      style: mono),
                                ),
                              ],
                            )))
                        .toList(),
                  ),
                )),
          ],
        ),
      ),
      actions: [
        dialogButton('Close', onPressed: close, isOutline: true),
        Obx(() => dialogButton(running.value ? '실행 중...' : '실행',
            onPressed: running.value ? null : run)),
      ],
      onCancel: close,
    );
  });
}

/// HX: open all selected PCs as tabs of one remote window and switch that window
/// to the grid view (see DesktopTab._buildRemoteLayout). PCs without a saved
/// password ask for it in their tab as usual.
const kHxWindowEventGridOn = 'hx_grid_on';

Future<void> hxOpenPeersAsGrid(List<String> ids) async {
  int? win;
  for (var i = 0; i < ids.length; i++) {
    try {
      final r = await rustDeskWinManager.newRemoteDesktop(ids[i]);
      win ??= r.windowId;
    } catch (e) {
      debugPrint('[HX] open ${ids[i]} failed: $e');
    }
    // the first call creates the window; give it time to start listening
    await Future.delayed(Duration(milliseconds: i == 0 ? 2500 : 800));
  }
  if (win != null && ids.length > 1) {
    try {
      await DesktopMultiWindow.invokeMethod(win, kHxWindowEventGridOn, '');
    } catch (e) {
      debugPrint('[HX] grid on failed: $e');
    }
  }
}

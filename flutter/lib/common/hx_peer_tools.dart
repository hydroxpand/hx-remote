// HX: PC groups (open several PCs as a grid with one click) and a simple status
// board (C: free space, free memory, uptime) shown on the peer cards.
// Both are stored in local options on this computer, no server needed.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../consts.dart';
import '../models/peer_model.dart';
import '../models/platform_model.dart';
import 'hx_batch.dart';

// ---------------------------------------------------------------- groups
const _kGroupsKey = 'hx-peer-groups';

class HxGroup {
  final String name;
  final List<String> ids;
  HxGroup(this.name, this.ids);
}

List<HxGroup> hxLoadGroups() {
  try {
    final raw = bind.mainGetLocalOption(key: _kGroupsKey);
    if (raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => HxGroup(e['name'].toString(),
            (e['ids'] as List).map((x) => x.toString()).toList()))
        .where((g) => g.ids.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

void _storeGroups(List<HxGroup> groups) {
  bind.mainSetLocalOption(
      key: _kGroupsKey,
      value: jsonEncode(
          groups.map((g) => {'name': g.name, 'ids': g.ids}).toList()));
}

/// Ask for a name and save the selected PCs as a group.
void hxSaveGroupDialog(List<String> ids) {
  final name = TextEditingController();
  gFFI.dialogManager.show((setState, close, context) {
    submit() {
      final n = name.text.trim();
      if (n.isEmpty) return;
      final groups = hxLoadGroups()..removeWhere((g) => g.name == n);
      groups.add(HxGroup(n, ids));
      _storeGroups(groups);
      close();
      showToast('묶음 "$n" 저장 (${ids.length}대)');
    }

    return CustomAlertDialog(
      title: Text('묶음으로 저장 (${ids.length}대)'),
      content: TextField(
        controller: name,
        autofocus: true,
        decoration: const InputDecoration(
            hintText: '예: 실험실 2kW', border: OutlineInputBorder(), isDense: true),
        onSubmitted: (_) => submit(),
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('저장', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

/// Header button: list of saved groups; a click opens the group as a grid.
class HxGroupsButton extends StatelessWidget {
  const HxGroupsButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTapDown: (d) async {
        final groups = hxLoadGroups();
        final pos = RelativeRect.fromLTRB(d.globalPosition.dx,
            d.globalPosition.dy + 8, d.globalPosition.dx, 0);
        final picked = await showMenu<String>(
          context: context,
          position: pos,
          items: groups.isEmpty
              ? [
                  const PopupMenuItem<String>(
                      enabled: false,
                      child: Text('저장된 묶음이 없어요. 선택 모드에서 PC를 고른 뒤 "묶음으로 저장"',
                          style: TextStyle(fontSize: 12))),
                ]
              : [
                  for (final g in groups)
                    PopupMenuItem<String>(
                      value: 'open:${g.name}',
                      child: Row(children: [
                        const Icon(Icons.grid_view, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text('${g.name}  (${g.ids.length}대)')),
                      ]),
                    ),
                  const PopupMenuDivider(),
                  for (final g in groups)
                    PopupMenuItem<String>(
                      value: 'del:${g.name}',
                      child: Text('"${g.name}" 묶음 지우기',
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ),
                ],
        );
        if (picked == null) return;
        if (picked.startsWith('open:')) {
          final g = groups.firstWhere((g) => 'open:${g.name}' == picked);
          hxOpenPeersAsGrid(g.ids);
        } else if (picked.startsWith('del:')) {
          _storeGroups(groups..removeWhere((g) => 'del:${g.name}' == picked));
          showToast('묶음 지움');
        }
      },
      child: Tooltip(
        message: 'PC 묶음 (한 번에 모아 보기)',
        child: Icon(Icons.dashboard_outlined,
                size: 18, color: Theme.of(context).textTheme.titleLarge?.color)
            .marginSymmetric(horizontal: 6),
      ),
    );
  }
}

// ---------------------------------------------------------------- status
const _kStatusKey = 'hx-peer-status';
// One line the parser can find; the typed command echo starts with "PS ..." so it never matches.
const _kStatusCmd =
    r"$o=Get-CimInstance Win32_OperatingSystem; $c=Get-PSDrive C; 'HXSTAT c=' + [int]($c.Free/1GB) + ' ct=' + [int](($c.Free+$c.Used)/1GB) + ' m=' + [int]($o.FreePhysicalMemory/1KB) + ' mt=' + [int]($o.TotalVisibleMemorySize/1KB) + ' up=' + [int]((Get-Date)-$o.LastBootUpTime).TotalHours";

class HxStatus {
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  static Map<String, dynamic> _all() {
    try {
      final raw = bind.mainGetLocalOption(key: _kStatusKey);
      if (raw.isNotEmpty) return Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {}
    return {};
  }

  static Map<String, dynamic>? of(String id) {
    final v = _all()[id];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  static Future<void> _put(String id, Map<String, dynamic> v) async {
    final all = _all();
    all[id] = v;
    await bind.mainSetLocalOption(key: _kStatusKey, value: jsonEncode(all));
    changes.value++;
  }

  /// Check every Windows PC in [peers] that has a saved password.
  static Future<void> refresh(List<Peer> peers) async {
    if (running.value) return;
    running.value = true;
    try {
      final targets = <Peer>[];
      for (final p in peers) {
        if (p.platform != kPeerPlatformWindows) continue;
        if (!await bind.mainPeerHasPassword(id: p.id)) continue;
        targets.add(p);
      }
      if (targets.isEmpty) {
        showToast('확인할 PC가 없어요 (윈도우 PC 중 비밀번호 저장된 PC만)');
        return;
      }
      showToast('${targets.length}대 상태 확인 중...');
      var ok = 0;
      await Future.wait(targets.map((p) async {
        final r = HxBatchResult(p.id, p.alias);
        await hxRunOnPeer(r, _kStatusCmd, timeout: const Duration(seconds: 45));
        final m = RegExp(
                r'^HXSTAT c=(\d+) ct=(\d+) m=(\d+) mt=(\d+) up=(\d+)',
                multiLine: true)
            .firstMatch(r.output.value);
        if (m != null) {
          ok++;
          await _put(p.id, {
            'c': int.parse(m.group(1)!),
            'ct': int.parse(m.group(2)!),
            'm': int.parse(m.group(3)!),
            'mt': int.parse(m.group(4)!),
            'up': int.parse(m.group(5)!),
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
        }
      }));
      showToast('상태 확인 끝: ${targets.length}대 중 $ok대');
    } finally {
      running.value = false;
    }
  }
}

/// Header button: check the status of the PCs in the current list.
class HxStatusButton extends StatelessWidget {
  final List<Peer> Function() peers;
  const HxStatusButton({Key? key, required this.peers}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: HxStatus.running,
      builder: (context, busy, _) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: busy ? null : () => HxStatus.refresh(peers()),
        child: Tooltip(
          message: busy ? '상태 확인 중...' : 'PC 상태 확인 (디스크, 메모리, 켜진 시간)',
          child: (busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.monitor_heart_outlined,
                      size: 18,
                      color: Theme.of(context).textTheme.titleLarge?.color))
              .marginSymmetric(horizontal: 6),
        ),
      ),
    );
  }
}

/// Small badge on a peer card: "C 38GB  RAM 2/8GB", orange or red when low.
class HxStatusBadge extends StatelessWidget {
  final String id;
  const HxStatusBadge({Key? key, required this.id}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: HxStatus.changes,
      builder: (context, _, __) {
        final s = HxStatus.of(id);
        if (s == null) return const SizedBox.shrink();
        final c = s['c'] as int;
        final m = s['m'] as int;
        final mt = s['mt'] as int;
        final up = s['up'] as int;
        final ts = DateTime.fromMillisecondsSinceEpoch(s['ts'] as int);
        final ago = DateTime.now().difference(ts);
        final agoText = ago.inMinutes < 60
            ? '${ago.inMinutes}분 전'
            : ago.inHours < 48
                ? '${ago.inHours}시간 전'
                : '${ago.inDays}일 전';
        final low = c < 20 || m < 500;
        final warn = c < 50 || m < 1000;
        final color = low
            ? Colors.red
            : warn
                ? Colors.orange
                : Colors.black54;
        return Tooltip(
          message: 'C 드라이브 여유 ${c}GB / ${s['ct']}GB\n'
              '메모리 여유 ${(m / 1024).round()}GB / ${(mt / 1024).round()}GB\n'
              '켜진 지 ${up}시간\n'
              '확인: $agoText',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(4)),
            child: Text(
              'C ${c}GB  RAM ${(m / 1024).round()}/${(mt / 1024).round()}GB',
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
        );
      },
    );
  }
}

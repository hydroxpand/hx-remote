// HX: "HX Remote 업데이트" panel (Settings > About): the installed build, the newest
// build on GitHub, what is new (the release notes of every newer build), and a button
// that starts the update right away.
// The update itself is done by the auto-update job installed with the app:
//   Windows: scheduled task "HX Remote Update" (tools/hxupdate.ps1, runs as SYSTEM)
//   macOS:   LaunchAgent com.hydroxpand.hxremote.update (tools/hxupdate-mac.sh)
// The button drops a "force" flag (skip the "nobody connected / Mac idle" waits) and
// starts that job. Without the job (older installs) it runs the installer instead.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

const _kRepo = 'hydroxpand/hx-remote';
const _kRaw = 'https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools';

String get _home => Platform.environment['HOME'] ?? '';
String get _dataDir => Platform.isWindows
    ? r'C:\ProgramData\HX-Remote'
    : '$_home/Library/Application Support/HX-Remote-Updater';
String get _markPath =>
    Platform.isWindows ? '$_dataDir\\build.txt' : '$_dataDir/build.txt';
String get _flagPath =>
    Platform.isWindows ? '$_dataDir\\force-update' : '$_dataDir/force';

List<int>? _ver(String tag) {
  final m = RegExp(r'^hx-(\d+)\.(\d+)\.(\d+)-(\d+)$').firstMatch(tag.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
}

int _cmp(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

class HxRelease {
  final String tag;
  final List<int> ver;
  final String notes;
  final DateTime? published;
  HxRelease(this.tag, this.ver, this.notes, this.published);
}

/// Build tag written by the installer / auto-update job, or null.
Future<String?> hxInstalledBuild() async {
  try {
    final f = File(_markPath);
    if (!await f.exists()) return null;
    final first = (await f.readAsLines()).firstWhere((l) => l.trim().isNotEmpty,
        orElse: () => '');
    final tag = first.trim().split(RegExp(r'\s+')).first;
    return _ver(tag) == null ? null : tag;
  } catch (_) {
    return null;
  }
}

/// Complete hx-* releases for this platform, newest first.
Future<List<HxRelease>> hxFetchReleases() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$_kRepo/releases?per_page=30'));
    req.headers.set('User-Agent', 'hx-remote-app');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw 'GitHub ${res.statusCode}';
    final list = <HxRelease>[];
    for (final r in jsonDecode(body) as List) {
      final tag = (r['tag_name'] ?? '').toString();
      final v = _ver(tag);
      if (v == null || r['draft'] == true) continue;
      final names =
          ((r['assets'] as List?) ?? []).map((a) => a['name'].toString()).toList();
      if (!names.contains('SHA256SUMS')) continue;
      final ok = Platform.isWindows
          ? names.any((n) => n.endsWith('x86_64.exe'))
          : names.any((n) => n.endsWith('.dmg'));
      if (!ok) continue;
      list.add(HxRelease(tag, v, (r['body'] ?? '').toString().trim(),
          DateTime.tryParse((r['published_at'] ?? '').toString())));
    }
    list.sort((a, b) => _cmp(b.ver, a.ver));
    return list;
  } finally {
    client.close(force: true);
  }
}

/// Start the update now. Returns a message for the user.
Future<String> hxStartUpdate() async {
  try {
    await Directory(_dataDir).create(recursive: true);
    await File(_flagPath).writeAsString('1');
  } catch (_) {}
  if (Platform.isWindows) {
    final r = await Process.run('schtasks', ['/Run', '/TN', 'HX Remote Update']);
    if (r.exitCode == 0) {
      return '업데이트를 시작했어요. 1~2분 뒤 HX Remote가 새 버전으로 다시 켜져요. '
          '이 PC에 원격으로 들어와 있다면 연결이 잠깐 끊겼다가 다시 붙어요.';
    }
    // older install without the task (or without the right to start it): run the installer
    final path = '${Directory.systemTemp.path}\\hx-i.ps1';
    await _download('$_kRaw/i.ps1', path);
    await Process.start('powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path],
        mode: ProcessStartMode.detached);
    return '설치 창이 열려요. 관리자 확인 창에서 "예"를 눌러 주세요. '
        '이번에 자동 업데이트 장치도 같이 설치돼서 다음부터는 이 버튼만 누르면 돼요.';
  }
  if (Platform.isMacOS) {
    final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
    final r = await Process.run('launchctl',
        ['kickstart', '-k', 'gui/$uid/com.hydroxpand.hxremote.update']);
    if (r.exitCode == 0) {
      return '업데이트를 시작했어요. 잠시 뒤 HX Remote가 꺼졌다가 새 버전으로 다시 켜져요.';
    }
    await Process.run('osascript', [
      '-e',
      'tell application "Terminal" to do script "curl -fsSL $_kRaw/i-mac.sh | bash"',
      '-e',
      'tell application "Terminal" to activate',
    ]);
    return '터미널에서 설치를 시작했어요. 끝나면 자동 업데이트 장치도 같이 설치돼요.';
  }
  return '이 운영체제는 아직 지원하지 않아요.';
}

Future<void> _download(String url, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'hx-remote-app');
    final res = await req.close();
    if (res.statusCode != 200) throw 'download ${res.statusCode}';
    await res.pipe(File(path).openWrite());
  } finally {
    client.close(force: true);
  }
}

class HxUpdatePanel extends StatefulWidget {
  const HxUpdatePanel({Key? key}) : super(key: key);

  @override
  State<HxUpdatePanel> createState() => _HxUpdatePanelState();
}

class _HxUpdatePanelState extends State<HxUpdatePanel> {
  String? _installed;
  List<HxRelease>? _releases;
  String? _error;
  String? _message;
  bool _checking = false;
  bool _starting = false;
  bool _loaded = false; // first check finished (until then show "확인 중")

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final installed = await hxInstalledBuild();
    List<HxRelease>? rels;
    String? err;
    try {
      rels = await hxFetchReleases();
    } catch (e) {
      err = '업데이트 정보를 못 가져왔어요 ($e)';
    }
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _releases = rels;
      _error = err;
      _checking = false;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    final rels = _releases ?? [];
    final latest = rels.isEmpty ? null : rels.first;
    final iv = _installed == null ? null : _ver(_installed!);
    final newer = latest == null
        ? <HxRelease>[]
        : rels.where((r) => iv == null || _cmp(r.ver, iv) > 0).toList();
    final upToDate = latest != null && iv != null && newer.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('설치된 버전: ${!_loaded ? "확인 중..." : _installed ?? "알 수 없음 (자동 업데이트 장치가 아직 없어요)"}'),
        const SizedBox(height: 4),
        Text(_checking
            ? '받을 수 있는 버전: 확인 중...'
            : latest == null
                ? '받을 수 있는 버전: -'
                : upToDate
                    ? '받을 수 있는 버전: ${iv != null && _cmp(iv, latest.ver) > 0 ? _installed : latest.tag} (최신 버전이에요)'
                    : '받을 수 있는 버전: ${latest.tag}'),
        if (_error != null) Text(_error!, style: hint),
        if (!upToDate && newer.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('추가되는 기능', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).hoverColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in (iv == null ? newer.take(3) : newer)) ...[
                      Text(r.tag,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(r.notes.isEmpty ? '(설명 없음)' : r.notes,
                          style: const TextStyle(fontSize: 13, height: 1.4)),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(children: [
          OutlinedButton(
            onPressed: _checking ? null : _check,
            child: const Text('업데이트 확인'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: (_checking || _starting || upToDate || latest == null)
                ? null
                : () async {
                    setState(() => _starting = true);
                    String msg;
                    try {
                      msg = await hxStartUpdate();
                    } catch (e) {
                      msg = '업데이트를 시작하지 못했어요 ($e)';
                    }
                    if (!mounted) return;
                    setState(() {
                      _starting = false;
                      _message = msg;
                    });
                  },
            child: Text(_starting ? '시작하는 중...' : '지금 업데이트'),
          ),
        ]),
        if (_message != null) ...[
          const SizedBox(height: 6),
          Text(_message!, style: hint),
        ],
        const SizedBox(height: 4),
        Text(
            Platform.isWindows
                ? '자동 업데이트: 매일 새벽 3시 30분과 부팅 뒤에 스스로 확인해요.'
                : '자동 업데이트: 매시간 확인하고, 맥을 30분 이상 안 쓸 때 바꿔요.',
            style: hint),
      ],
    );
  }
}

/// Home screen (left pane): always-visible box with the installed build, the newest
/// build, up-to-date or "new version" status, a short what's-new line and the buttons
/// (update now when newer, check, details). Highlighted when a newer build exists.
class HxHomeUpdateCard extends StatefulWidget {
  final VoidCallback? onDetails;
  const HxHomeUpdateCard({Key? key, this.onDetails}) : super(key: key);

  @override
  State<HxHomeUpdateCard> createState() => _HxHomeUpdateCardState();
}

class _HxHomeUpdateCardState extends State<HxHomeUpdateCard> {
  String? _installed;
  List<HxRelease> _newer = [];
  HxRelease? _latest;
  String? _message;
  bool _starting = false;
  bool _checking = false;
  bool _failed = false; // could not reach GitHub
  DateTime? _checkedAt;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (mounted) setState(() => _checking = true);
    final installed = await hxInstalledBuild();
    List<HxRelease> rels = [];
    var failed = false;
    try {
      rels = await hxFetchReleases();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    final iv = installed == null ? null : _ver(installed);
    setState(() {
      _installed = installed;
      _latest = rels.isEmpty ? null : rels.first;
      // without a known installed build every release counts as "new":
      // the button then installs the auto-update job as well
      _newer = rels.where((r) => iv == null || _cmp(r.ver, iv) > 0).toList();
      _failed = failed;
      _checking = false;
      _checkedAt = DateTime.now();
    });
  }

  String _summary() {
    final lines = <String>[];
    for (final r in _newer) {
      for (final l in r.notes.split('\n')) {
        final t = l.trim().replaceFirst(RegExp(r'^[-*•]\s*'), '');
        if (t.isNotEmpty) lines.add(t);
      }
    }
    if (lines.isEmpty) return '';
    final firstTwo = lines.take(2).map((l) {
      final cut = l.indexOf(':');
      return cut > 0 && cut < 30 ? l.substring(0, cut) : (l.length > 40 ? '${l.substring(0, 40)}…' : l);
    }).join(', ');
    return lines.length > 2 ? '$firstTwo 외 ${lines.length - 2}가지' : firstTwo;
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    const ok = Color(0xFF2E9E5B);
    final hint = TextStyle(fontSize: 11, color: theme.hintColor);
    const body = TextStyle(fontSize: 12);
    final hasNew = _newer.isNotEmpty;

    // status line: checking / failed / new version / up to date
    Widget status;
    if (_checking && _checkedAt == null) {
      status = Text('확인 중...', style: hint);
    } else if (hasNew) {
      status = Row(children: [
        Icon(Icons.fiber_new, size: 15, color: accent),
        const SizedBox(width: 4),
        Flexible(
            child: Text('새 버전이 있어요',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: accent))),
      ]);
    } else if (_failed) {
      status = Row(children: [
        Icon(Icons.cloud_off, size: 14, color: theme.hintColor),
        const SizedBox(width: 4),
        Flexible(child: Text('서버 확인 못 함 (인터넷 확인)', style: hint)),
      ]);
    } else {
      status = const Row(children: [
        Icon(Icons.check_circle, size: 14, color: ok),
        SizedBox(width: 4),
        Flexible(
            child: Text('최신 버전이에요',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: ok))),
      ]);
    }
    final summary = hasNew ? _summary() : '';
    final btnStyle = ElevatedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12));

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 16, top: 4, bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: hasNew ? accent.withOpacity(0.12) : theme.hintColor.withOpacity(0.06),
          border: Border.all(
              color: hasNew ? accent.withOpacity(0.6) : theme.hintColor.withOpacity(0.25)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.system_update_alt, size: 15, color: hasNew ? accent : theme.hintColor),
              const SizedBox(width: 6),
              // short title: the 200 px pane wraps "HX Remote 업데이트"
              const Flexible(
                  child: Text('앱 업데이트',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 6),
            // the pane is 200 px wide: short labels
            Text('설치됨  ${_installed ?? (_checkedAt == null ? "확인 중..." : "알 수 없음")}',
                style: body),
            Text('최신  ${_latest?.tag ?? (_checkedAt == null || _checking ? "확인 중..." : "-")}',
                style: body),
            const SizedBox(height: 4),
            status,
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('추가: $summary', style: body),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (hasNew)
                  ElevatedButton(
                    style: btnStyle,
                    onPressed: _starting
                        ? null
                        : () async {
                            setState(() => _starting = true);
                            String msg;
                            try {
                              msg = await hxStartUpdate();
                            } catch (e) {
                              msg = '업데이트를 시작하지 못했어요 ($e)';
                            }
                            if (!mounted) return;
                            setState(() {
                              _starting = false;
                              _message = msg;
                            });
                          },
                    child: Text(_starting ? '시작하는 중...' : '지금 업데이트',
                        style: const TextStyle(fontSize: 12)),
                  ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10)),
                  onPressed: _checking ? null : _check,
                  child: Text(_checking ? '확인 중...' : '업데이트 확인',
                      style: const TextStyle(fontSize: 12)),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: widget.onDetails,
                  child: const Text('자세히', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 4),
              Text(_message!, style: hint),
            ],
            if (_checkedAt != null) ...[
              const SizedBox(height: 4),
              Text('${_two(_checkedAt!.hour)}:${_two(_checkedAt!.minute)} 확인, 6시간마다 자동',
                  style: hint),
            ],
          ],
        ),
      ),
    );
  }
}

// HX: plain-language labels and small widgets for the peer list (CEO request 261117:
// icon-only tabs and buttons were hard to understand). Korean when the app runs in Korean,
// otherwise the original English strings.
import 'package:flutter/material.dart';

import '../common.dart';
import '../models/peer_model.dart';

/// True when the app shows Korean (follows the language setting, not only the OS).
bool hxKo() => translate('Address book') == '주소록';

String hxT(String ko, String en) => hxKo() ? ko : en;

/// Peer list tab names, by PeerTabIndex order (recent, fav, lan, ab, group).
String hxTabLabel(int index) {
  switch (index) {
    case 0:
      return hxT('최근 접속', 'Recent');
    case 1:
      return hxT('즐겨찾기', 'Favorites');
    case 2:
      return hxT('같은 네트워크', 'Discovered');
    case 3:
      return hxT('회사 PC', 'Company PCs');
    case 4:
      return hxT('접근 가능한 장치', 'Accessible devices');
  }
  return '';
}

/// Friendlier text for a toolbar button, found by its (translated) tooltip.
String hxActionLabel(String toolTip) {
  final map = <String, String>{
    translate('Select'): hxT('여러 대 고르기', 'Select'),
    translate('Change view'): hxT('보기 방식', 'View'),
    translate('Sort by'): hxT('정렬', 'Sort'),
    translate('Toggle Tags'): hxT('방 고르기 칸', 'Tags panel'),
    translate('Refresh'): hxT('새로 고침', 'Refresh'),
    translate('Select All'): hxT('모두 고르기', 'Select all'),
    translate('Close'): hxT('닫기', 'Close'),
    translate('Delete'): hxT('지우기', 'Delete'),
    translate('Add to Favorites'): hxT('즐겨찾기에 넣기', 'Add to favorites'),
    translate('Add to address book'): hxT('주소록에 넣기', 'Add to address book'),
    translate('Edit Tag'): hxT('방 바꾸기', 'Edit tags'),
    translate('ab_web_console_tip'): hxT('관리 화면', 'Web console'),
  };
  return map[toolTip] ?? toolTip;
}

/// Small "on / off" text next to the coloured dot.
Widget hxOnlineText(bool online, {double fontSize = 11}) {
  return Text(
    online ? hxT('켜짐', 'On') : hxT('꺼짐', 'Off'),
    style: TextStyle(
        fontSize: fontSize,
        color: online ? Colors.green : Colors.grey,
        fontWeight: FontWeight.w500),
  );
}

/// Room order for the company address book (same names as the hub floor plan).
const List<String> kHxRoomOrder = [
  '평가실',
  '연구실',
  '제조실',
  '회의실',
  '탕비실',
  '문지 본사',
  '개인',
];

String hxRoomOf(Peer peer) {
  for (final t in peer.tags) {
    final s = t.toString().trim();
    if (s.isNotEmpty) return s;
  }
  return '';
}

/// Peers grouped by their first tag, rooms in kHxRoomOrder first, untagged last.
List<MapEntry<String, List<Peer>>> hxGroupByRoom(List<Peer> peers) {
  final groups = <String, List<Peer>>{};
  for (final p in peers) {
    groups.putIfAbsent(hxRoomOf(p), () => <Peer>[]).add(p);
  }
  int rank(String k) {
    if (k.isEmpty) return 10000;
    final i = kHxRoomOrder.indexOf(k);
    return i < 0 ? 1000 : i;
  }

  final keys = groups.keys.toList()
    ..sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final k in keys) MapEntry(k, groups[k]!)];
}

/// Shown on the company tab before signing in (instead of a lone "Login" button).
Widget hxLoginPrompt(BuildContext context, VoidCallback onLogin) {
  final muted = Theme.of(context).textTheme.bodySmall?.color;
  return Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.business_outlined, size: 40, color: muted),
          const SizedBox(height: 12),
          Text(
            hxT('회사 계정으로 로그인하면 회사 PC 목록이 보여요',
                'Sign in with your company account to see the company PCs'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            hxT('아이디는 이름이에요 (예: 김민규). 비밀번호를 모르면 관리자에게 물어보세요.',
                'Your user name is your name. Ask the administrator if you do not know the password.'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: muted),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onLogin,
            icon: const Icon(Icons.login, size: 18),
            label: Text(hxT('로그인', 'Sign in')),
          ),
        ],
      ),
    ),
  );
}

/// Section title above each room in the company list.
Widget hxRoomHeader(BuildContext context, String room, int count) {
  return Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 8),
    child: Row(children: [
      Text(room.isEmpty ? hxT('방 없음', 'No tag') : room,
          style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(width: 6),
      Text(hxT('$count대', '$count'),
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color)),
    ]),
  );
}

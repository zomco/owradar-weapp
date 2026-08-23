/// 日报设置页与账号接口。
///
/// 两条要守住的行为：
///
/// 1. **能不能用由服务端的配额决定**，客户端不自己判断套餐名 ——
///    否则改一次定价要同时改四端。
/// 2. **关掉之后下面的项要跟着变灰**，而不是留一堆点了没反应的控件。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mmradar_app/data/cloud_api.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/features/settings/report_settings.dart';

http.Response _res(Object? json, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(json)),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> _account({
  String plan = 'pro',
  bool allowed = true,
  bool enabled = true,
  bool weekly = false,
  int tz = 0,
  int hour = 8,
}) => {
  'email': 'a@b.test',
  'plan': plan,
  'quota': {'daily_report': allowed, 'max_devices': 1, 'history_days': 7},
  'report': {
    'enabled': enabled,
    'weekly_enabled': weekly,
    'tz_offset_min': tz,
    'hour': hour,
  },
};

CloudApi _api(Map<String, Object?> account, {List<http.Request>? log}) => CloudApi(
  baseUrl: 'http://x',
  accessToken: 'T',
  client: MockClient((req) async {
    log?.add(req);
    return _res(account);
  }),
);

Future<void> _pump(WidgetTester tester, ProviderScope scope) async {
  await tester.pumpWidget(scope);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

ProviderScope _scope(Map<String, Object?> account, {List<http.Request>? log}) => ProviderScope(
  overrides: [
    cloudApiProvider.overrideWithValue(_api(account, log: log)),
    accountProvider.overrideWith((ref) async => AccountInfo.fromJson(account)),
  ],
  child: const MaterialApp(home: ReportSettingsPage()),
);

void main() {
  group('账号解析', () {
    test('配额决定能不能用，不看套餐名', () {
      // 服务端说 daily_report=false，即便 plan 是 pro 也不该放开
      final a = AccountInfo.fromJson(_account(plan: 'pro', allowed: false));
      expect(a.dailyReportAllowed, isFalse);
      expect(a.plan, 'pro');
    });

    test('字段缺失时给安全默认值，不崩', () {
      final a = AccountInfo.fromJson({'email': 'x@y.z'});
      expect(a.plan, 'free');
      expect(a.dailyReportAllowed, isFalse);
      expect(a.reportHour, 8);
      expect(a.tzOffsetMin, 0);
    });

    test('分钟级时区偏移能原样读出 —— 印度 +330、尼泊尔 +345', () {
      expect(AccountInfo.fromJson(_account(tz: 330)).tzOffsetMin, 330);
      expect(AccountInfo.fromJson(_account(tz: 345)).tzOffsetMin, 345);
    });
  });

  group('设置页', () {
    testWidgets('套餐不含日报时说清原因，不显示一堆点不动的控件', (tester) async {
      await _pump(tester, _scope(_account(plan: 'free', allowed: false)));

      expect(find.text('定期报告是付费版功能'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
    });

    testWidgets('可用时显示两个开关与时刻、时区', (tester) async {
      await _pump(tester, _scope(_account(hour: 9, tz: 480)));

      expect(find.byKey(const Key('daily-report-switch')), findsOneWidget);
      expect(find.byKey(const Key('weekly-report-switch')), findsOneWidget);
      expect(find.textContaining('09:00'), findsOneWidget);
      expect(find.textContaining('UTC+8:00'), findsOneWidget);
    });

    testWidgets('两个都关掉之后时刻与时区才变灰', (tester) async {
      await _pump(tester, _scope(_account(enabled: false, weekly: false)));

      final hourTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('发送时刻'), matching: find.byType(ListTile)),
      );
      expect(hourTile.enabled, isFalse);
    });

    testWidgets('只开周报时时刻与时区仍可改', (tester) async {
      // 时刻与时区对两种报告都生效。只看日报开关的话，
      // 只开周报的用户会发现时区是灰的、改不了 —— 而它明明在起作用。
      await _pump(tester, _scope(_account(enabled: false, weekly: true)));

      for (final label in ['发送时刻', '时区']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isTrue, reason: '$label 应当可改');
      }
    });

    testWidgets('周报的说明讲清它和日报不重复', (tester) async {
      // 不说的话用户会以为周报只是「日报 ×7」，然后关掉它
      await _pump(tester, _scope(_account()));
      expect(find.textContaining('跨天'), findsOneWidget);
    });

    testWidgets('两个开关互相独立', (tester) async {
      await _pump(tester, _scope(_account(enabled: true, weekly: false)));

      final daily = tester.widget<SwitchListTile>(
        find.byKey(const Key('daily-report-switch')),
      );
      final weekly = tester.widget<SwitchListTile>(
        find.byKey(const Key('weekly-report-switch')),
      );
      expect(daily.value, isTrue);
      expect(weekly.value, isFalse);
    });

    testWidgets('把时区设错的后果要写在界面上', (tester) async {
      await _pump(tester, _scope(_account()));
      // 用户不会主动想到「时区会影响送达时间」，得替他说出来
      expect(find.textContaining('凌晨'), findsOneWidget);
    });

    testWidgets('拉不到账号时给重试，而不是空白页', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_api(_account())),
            accountProvider.overrideWith((ref) async => throw Exception('连不上服务端')),
          ],
          child: const MaterialApp(home: ReportSettingsPage()),
        ),
      );

      expect(find.textContaining('连不上服务端'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('更新偏好', () {
    test('只发改动的项 —— 服务端做的是部分更新', () async {
      final log = <http.Request>[];
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((req) async {
          log.add(req);
          return _res(_account(hour: 20));
        }),
      );

      await api.updateReportPrefs(hour: 20);

      final patch = log.firstWhere((r) => r.method == 'PATCH');
      expect(jsonDecode(patch.body), {'report_hour': 20});
    });

    test('周报开关用服务端认的字段名', () async {
      // 字段名打错的话请求照样 200，开关却纹丝不动 —— 只有对着
      // 真服务端手点才会发现。这里把线上格式钉住。
      final log = <http.Request>[];
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((req) async {
          log.add(req);
          return _res(_account(weekly: true));
        }),
      );

      await api.updateReportPrefs(weeklyEnabled: true);

      final patch = log.firstWhere((r) => r.method == 'PATCH');
      expect(jsonDecode(patch.body), {'weekly_report_enabled': true});
    });

    test('日报与周报可以各改各的，互不牵连', () async {
      final log = <http.Request>[];
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((req) async {
          log.add(req);
          return _res(_account());
        }),
      );

      await api.updateReportPrefs(enabled: false);

      final patch = log.firstWhere((r) => r.method == 'PATCH');
      // 只带日报那一项：顺手把周报也发过去会覆盖掉用户的另一个选择
      expect(jsonDecode(patch.body), {'report_enabled': false});
    });

    test('什么都不改时直接报错，不发空请求', () async {
      final log = <http.Request>[];
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((req) async {
          log.add(req);
          return _res(_account());
        }),
      );

      await expectLater(api.updateReportPrefs(), throwsA(isA<CloudException>()));
      expect(log, isEmpty);
    });

    test('更新后重新拉一次完整账号 —— PATCH 只回 report 段', () async {
      final log = <http.Request>[];
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((req) async {
          log.add(req);
          return _res(_account(hour: 7));
        }),
      );

      final a = await api.updateReportPrefs(hour: 7);

      expect(log.map((r) => r.method), containsAllInOrder(['PATCH', 'GET']));
      // 套餐信息还在，没有因为 PATCH 的窄响应而变空
      expect(a.plan, 'pro');
      expect(a.reportHour, 7);
    });
  });
}

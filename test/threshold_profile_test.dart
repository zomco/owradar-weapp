/// 分级标准的地区选择。
///
/// 这一页守的是两条：
///
/// 1. **用户选的是地区，不是标准编号。** 没人知道 EN 16798-1 是什么，
///    但每个人都知道自己在哪。标准名只作为依据放在副标题里。
/// 2. **换档会覆盖用户改过的阈值，所以必须先问。** 一次误触就把
///    用户调了半天的设置清掉，是不可接受的。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/core/contracts/command.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/features/settings/threshold_profile.dart';

import 'fake_channel.dart';

Future<void> _pump(
  WidgetTester tester, {
  String current = 'international',
  FakeChannel? channel,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        thresholdProfileProvider.overrideWith((ref) async => current),
        if (channel != null) channelProvider.overrideWithValue(channel),
      ],
      child: const MaterialApp(home: ThresholdProfilePage()),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  group('选项呈现', () {
    testWidgets('列的是地区，不是标准编号', (tester) async {
      await _pump(tester);

      // 标题必须是地区名 —— 用户认得的是这个
      expect(find.text('国际通用'), findsOneWidget);
      expect(find.text('欧盟'), findsOneWidget);
      expect(find.text('中国'), findsOneWidget);
    });

    testWidgets('标准编号作为依据放在副标题里', (tester) async {
      // 不显示的话，想核对依据的人无从查起；
      // 放标题的话，不想深究的人被吓退
      await _pump(tester);

      expect(find.textContaining('EN 16798-1'), findsOneWidget);
      expect(find.textContaining('GB/T 18883-2022'), findsOneWidget);
      expect(find.textContaining('ASHRAE'), findsOneWidget);
    });

    testWidgets('选中的是设备当前那一档', (tester) async {
      await _pump(tester, current: 'eu');

      final group = tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>));
      expect(group.groupValue, 'eu');
    });

    testWidgets('说明噪音没有地区差异', (tester) async {
      // 用户会问「为什么换了档噪音的颜色没变」，先替他回答
      await _pump(tester);
      expect(find.textContaining('噪音'), findsOneWidget);
    });
  });

  group('切换', () {
    testWidgets('先确认再切 —— 换档会覆盖用户改过的阈值', (tester) async {
      final channel = FakeChannel();
      await _pump(tester, channel: channel);

      await tester.tap(find.byKey(const Key('profile-eu')));
      await tester.pumpAndSettle();

      // 对话框必须点名代价，而不是只问「确定吗」
      expect(find.textContaining('会被覆盖'), findsOneWidget);
      expect(channel.sent, isEmpty, reason: '没确认之前不该下发命令');
    });

    testWidgets('取消则不下发命令', (tester) async {
      final channel = FakeChannel();
      await _pump(tester, channel: channel);

      await tester.tap(find.byKey(const Key('profile-china')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(channel.sent, isEmpty);
    });

    testWidgets('确认后下发 set_profile 与正确的档名', (tester) async {
      // 档名打错的话请求照样成功、设备纹丝不动 —— 这条把线上格式钉住
      final channel = FakeChannel();
      await _pump(tester, channel: channel);

      await tester.tap(find.byKey(const Key('profile-eu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换'));
      await tester.pumpAndSettle();

      expect(channel.sent, hasLength(1));
      expect(channel.sent.single.cmd, 'set_profile');
      expect(channel.sent.single.params?['profile'], 'eu');
    });

    testWidgets('点已选中的那一档什么都不做', (tester) async {
      final channel = FakeChannel();
      await _pump(tester, current: 'eu', channel: channel);

      await tester.tap(find.byKey(const Key('profile-eu')));
      await tester.pumpAndSettle();

      expect(find.textContaining('会被覆盖'), findsNothing, reason: '没改动就不该弹确认');
      expect(channel.sent, isEmpty);
    });

    testWidgets('设备拒绝时显示设备给的原因', (tester) async {
      final channel = FakeChannel(
        response: const CommandFailed(CommandError(ErrorCode.invalidParam, '档名不认识')),
      );
      await _pump(tester, channel: channel);

      await tester.tap(find.byKey(const Key('profile-china')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换'));
      await tester.pumpAndSettle();

      expect(find.textContaining('档名不认识'), findsOneWidget);
    });
  });

  group('档位清单与契约一致', () {
    test('三个 id 与契约 §8.1 完全一致', () {
      // 多一个少一个、拼错一个，设备都会把它当成未知档拒掉，
      // 而界面上看只是「点了没反应」
      expect(
        thresholdProfiles.map((p) => p.id).toList(),
        ['international', 'eu', 'china'],
      );
    });

    test('每一档都写明了依据', () {
      for (final p in thresholdProfiles) {
        expect(p.basis, isNotEmpty, reason: '${p.label} 没写依据');
        expect(p.label, isNotEmpty);
      }
    });
  });
}

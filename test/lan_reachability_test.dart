/// 局域网可达性（混合内容，OPEN-ISSUES S-14）。
///
/// 这条限制的特别之处在于**设备端无解**：浏览器禁止 https 页面向 http
/// 发请求，与 CORS 无关，设备做什么都绕不过去。
///
/// 所以这里测的不是「怎么连上」，而是「怎么在连不上的时候把话说清楚」——
/// 不检测的话用户看到的是一个笼统的网络错误，然后会去反复检查
/// Token、IP、防火墙这些其实都没问题的东西。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/core/lan_reachability.dart';

void main() {
  group('原生构建', () {
    test('不受混合内容限制，一律可达', () {
      // Android / iOS / 桌面根本没有这条规则。
      // 判错的话会给原生用户弹一个莫名其妙的警告。
      for (final host in ['192.168.1.50', 'mmradar-a1b2.local', '10.0.0.1']) {
        expect(
          lanReachability(host, isWeb: false, pageUrl: Uri.parse('https://app.example.com')),
          LanReachability.ok,
          reason: '原生构建不该被 https 页面的规则波及',
        );
      }
    });
  });

  group('http 页面的网页版', () {
    test('可以直连设备', () {
      // flutter run -d chrome 就是这种情形，开发日常靠它
      expect(
        lanReachability('192.168.1.50', isWeb: true, pageUrl: Uri.parse('http://localhost:5173')),
        LanReachability.ok,
      );
    });
  });

  group('https 页面的网页版', () {
    Uri page() => Uri.parse('https://app.example.com/');

    test('连私网 IP 被拦', () {
      expect(
        lanReachability('192.168.1.50', isWeb: true, pageUrl: page()),
        LanReachability.blockedByMixedContent,
      );
    });

    test('连 .local 名称同样被拦', () {
      expect(
        lanReachability('mmradar-a1b2.local', isWeb: true, pageUrl: page()),
        LanReachability.blockedByMixedContent,
      );
    });

    test('连环回地址不拦 —— 浏览器视环回为潜在可信', () {
      // 这条容易被写成「https 一律拦」。那样会误伤隧道到本机的用法，
      // 而那是网页版唯一还能走通的局域网路径。
      for (final host in ['localhost', '127.0.0.1', '::1']) {
        expect(
          lanReachability(host, isWeb: true, pageUrl: page()),
          LanReachability.ok,
          reason: '$host 是环回地址，不算混合内容',
        );
      }
    });
  });

  group('环回地址的判定', () {
    test('整个 127.0.0.0/8 都算', () {
      // 不只是 127.0.0.1 —— 127.0.0.2 一样是环回，Docker 场景里会遇到
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.0.0.2'), isTrue);
      expect(isLoopbackHost('127.1.2.3'), isTrue);
    });

    test('大小写与空格不影响判定', () {
      expect(isLoopbackHost(' LocalHost '), isTrue);
    });

    test('不把相似的主机名误判为环回', () {
      // 与固件 cors.cpp 里同一个陷阱：前缀/包含匹配会把攻击者的域名放进来
      for (final host in [
        'localhost.attacker.com',
        'notlocalhost',
        '127.0.0.1.evil.net',
        '1127.0.0.1',
        '',
      ]) {
        expect(isLoopbackHost(host), isFalse, reason: '$host 不该被当成环回地址');
      }
    });

    test('八位组超出 255 的不算', () {
      expect(isLoopbackHost('127.0.0.999'), isFalse);
    });

    test('私网地址不是环回 —— 它们照样被混合内容拦', () {
      for (final host in ['192.168.1.1', '10.0.0.1', '172.16.0.1']) {
        expect(isLoopbackHost(host), isFalse);
      }
    });
  });
}

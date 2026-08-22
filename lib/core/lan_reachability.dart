/// 这个构建到底能不能直连一台明文 HTTP 的设备。
///
/// 由来（OPEN-ISSUES S-14）：设备的局域网 API 是明文 HTTP，
/// 而**浏览器禁止 https 页面向 http 发请求**（混合内容）。
/// 这一条拦在 CORS 之前，设备端做什么都绕不过去。
///
/// 不检测的话，用户在线上 https 域名下选「仅局域网」会得到一个
/// 笼统的网络错误，然后开始怀疑 Token、IP、防火墙 —— 而真正的原因
/// 浏览器只写在控制台里，普通用户根本不会去看。
///
/// **这不是要说服用户去改什么，而是把一条查不出来的死路提前讲明白。**
library;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 局域网直连在当前环境下的可达性。
enum LanReachability {
  /// 可以直连。
  ok,

  /// 页面走 https，设备走 http —— 浏览器直接拦，无解。
  blockedByMixedContent;

  bool get isBlocked => this == LanReachability.blockedByMixedContent;
}

/// 环回地址（`localhost` / `127.0.0.0/8` / `::1`）。
///
/// 单独认它是因为浏览器把环回地址视为「潜在可信」
/// （W3C Secure Contexts），**https 页面访问 http 的环回地址不算混合内容**。
/// 所以隧道到本机的用法仍然可用，不该被一并拦下。
///
/// 注意 192.168.x.x 之类的私网地址**不在**此列 —— 它们照样被拦。
bool isLoopbackHost(String host) {
  final h = host.trim().toLowerCase();
  if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
  // 整个 127.0.0.0/8 都是环回，不只是 127.0.0.1
  final v4 = RegExp(r'^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
  if (v4 == null) return false;
  return List.generate(3, (i) => int.parse(v4.group(i + 1)!)).every((n) => n <= 255);
}

/// 当前页面是否由 https 提供。
///
/// 只在 web 上有意义：原生构建的 [Uri.base] 是工作目录，scheme 不是 http(s)。
/// 用参数注入而不是直接读全局，测试才好造各种情形。
bool _pageIsHttps(Uri pageUrl) => pageUrl.scheme == 'https';

/// 判断能否直连 [host] 上的设备。
///
/// [isWeb] 与 [pageUrl] 默认取当前运行环境，测试可覆盖。
LanReachability lanReachability(
  String host, {
  bool isWeb = kIsWeb,
  Uri? pageUrl,
}) {
  // 原生构建（Android / iOS / 桌面）没有混合内容这条规则，一律可达。
  if (!isWeb) return LanReachability.ok;

  final page = pageUrl ?? Uri.base;
  if (!_pageIsHttps(page)) return LanReachability.ok;

  // https 页面 + http 环回地址 = 浏览器放行
  if (isLoopbackHost(host)) return LanReachability.ok;

  return LanReachability.blockedByMixedContent;
}

/// 给用户看的解释。
///
/// 刻意讲清「这是浏览器的规则，不是设备或 Token 的问题」——
/// 否则用户会去反复检查那些其实没问题的东西。
const lanBlockedTitle = '这个网页版连不上局域网设备';

const lanBlockedExplanation =
    '当前页面由 https 提供，而设备的局域网接口是 http。'
    '浏览器禁止 https 页面访问 http 地址，这条限制在设备端无解，'
    '和配对 Token、IP、防火墙都没有关系。\n\n'
    '要走局域网直连，请改用手机 App 或桌面版；'
    '继续用网页版的话，请切到「云端」模式。';

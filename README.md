# mmradar-app

mmRadar 桌面助理客户端。**Flutter 3.47 · Dart 3.13**

> 架构说明在工作区，不在这里：
> [客户端架构](../../docs/architecture/04-app-architecture.md) ·
> [数据模型契约](../../docs/architecture/02-data-model.md) ·
> [ADR-0002 客户端选型](../../docs/adr/0002-client-stack.md)
>
> 本文件只讲**怎么把它跑起来**。

---

## 1. 快速开始

不需要硬件 —— 对着工作区的设备模拟器开发：

```bash
# 终端 1（在工作区根目录）
npm run sim

# 终端 2
flutter pub get
flutter run -d chrome
```

默认端点是 `127.0.0.1:8080`，token `dev-token`，正好对上模拟器。

要连云端（`mmradar-server`）的话，另开一个终端跑 `npm run dev`（在 server 仓库），
然后在 App 的「设置 → 连接方式」里切到「云端」，服务端地址填 `http://127.0.0.1:8787`。
登录用邮箱验证码，本地开发时服务端会把验证码回显在响应里并自动填好。

## 2. 平台状态

| 平台 | 状态 |
|---|---|
| **Web（Chrome / Edge）** | ✅ 可跑，当前主要开发目标 |
| Android | ⚠️ 需先装 Android SDK（`flutter doctor` 会提示） |
| iOS | ⚠️ 需 macOS |
| Windows 桌面 | ⚠️ 需 VS 的「C++ 桌面开发」工作负载 |

Web 上跑不了的只有两项：**BLE 配网**与 **mDNS 自动发现** ——
两者都需要原生插件。它们挡在 `DeviceChannel` 抽象后面，
不影响看板、规则、历史等其余功能的开发。

## 3. 三层结构

```
lib/
├── core/
│   ├── contracts/      契约的 Dart 映射 + 容错解析
│   ├── format.dart     展示逻辑（与固件 mmr_ui/format.cpp 同源）
│   ├── rule_templates.dart 规则模板（模板优先的规则配置）
│   └── async_view.dart AsyncValue 渲染约定：错误优先于加载
├── data/
│   ├── device_channel.dart  ⭐ 抽象接口 —— UI 只认它
│   ├── lan_channel.dart     局域网 HTTP + WebSocket
│   ├── cloud_api.dart       云端 REST 客户端
│   ├── cloud_channel.dart   云通道（REST + WSS）
│   ├── session.dart         连接模式与登录态
│   └── providers.dart       Riverpod 依赖图
└── features/
    ├── shell/        底部导航
    ├── dashboard/    实时看板
    ├── history/      历史曲线
    ├── rules/        提醒规则
    ├── devices/      设备列表与配对
    └── settings/     连接方式、账号、日报
```

**UI 不知道数据来自局域网还是云。** 这是 `DeviceChannel` 存在的全部意义：
`channelProvider` 按会话模式选 `LanChannel` 还是 `CloudChannel`，
换传输方式不需要动任何一个 widget。

### 展示逻辑与固件同源

`core/format.dart` 与固件的 `components/mmr_ui/src/format.cpp` 是同一套规则：
同一个 `level` 在屏幕、App、HA、云上必须是同一个颜色，
同一个 `health` 必须显示同样的语义。**改一边就要改另一边。**

风险分级本身**不在客户端计算** —— 直接用设备下发的 `level` 字段。
各端各算一遍，阈值一旦不同步就会出现「手机上是绿的、屏幕上是红的」。

## 4. 契约解析的两条原则

**① 缺失一律是 null，不是 0。**
`value: null` 表示传感器没数据；解析成 0 会让 UI 显示「0 lx」这种假数据。

**② 未知枚举降级，不抛异常。**
设备固件可能比 App 新。多出来的枚举值应当被安全忽略，
而不是让整个界面白屏。

## 5. 两个 Riverpod 3 的坑

**`StateProvider` 已移出主导出**，在 `legacy.dart` 里。用 `Notifier` 代替。
`Override` 类型也没有公开导出，所以测试里的 helper 只能收整个 `ProviderScope`。

**失败的 Provider 会被自动无限重试，重试期间 `isLoading` 一直是 true。**
直接用 `AsyncValue.when()` 的话 `error` 分支永远不触发 —— 界面就成了永远转圈，
用户既看不到失败原因也没有手动重试的入口。
所以：异步 Provider 统一挂 `retry: backOffThenGiveUp`（退避两次就放弃），
UI 统一用 `asyncView()` 而不是 `.when()`，它把错误分支排在加载分支前面。

对一个「设备可能就是不在线」的产品来说这不是小事：
说不清楚为什么连不上，比连不上本身更让人烦。

## 6. 测试

```bash
flutter analyze   # 零告警（strict-casts / strict-inference / strict-raw-types）
flutter test      # 107 项
```

| 文件 | 覆盖 |
|---|---|
| `test/contracts_test.dart` | 契约解析、Delta 合并、展示逻辑、规则序列化往返 |
| `test/dashboard_test.dart` | 看板的**无头渲染断言** —— 断言实际显示出来的文字 |
| `test/rules_test.dart` | 规则模板的去抖/滞回/冷却约束、人话渲染、规则界面 |
| `test/cloud_api_test.dart` | 与 mmradar-server 的**线格式**：路径、字段名、鉴权头、错误码 |
| `test/cloud_channel_test.dart` | WS 握手与票据鉴权、帧解析容错 |
| `test/token_refresh_test.dart` | 令牌过期后的自动刷新，重点是并发合并 |
| `test/report_settings_test.dart` | 日报设置页；能不能用由服务端配额决定 |
| `test/cloud_ui_test.dart` | 设备列表、历史曲线、设置页 |

widget 测试重点覆盖各 health 状态的渲染，因为
**用户必须能一眼分辨「传感器坏了」和「数值正常」**：

- `fault` 时显示「故障」，即使 value 字段还有数 —— 显示陈旧值是最危险的做法
- `warming_up` 显示「预热中」并说明约 30 秒
- `absent` 显示「未接入」
- `degraded` 显示数值但附「未标定，数值仅供参考」
- 无人时提示「监测已暂停」，且不再给行动建议

同样的原则用在云上：历史被保留期裁掉要明说，
局域网模式下不假装有历史曲线，拉取失败要给出原因和重试。

## 7. 已验证

**局域网** —— Web 构建产物 + 工作区设备模拟器实测：

- CORS 预检 204 → 快照请求 200
- WebSocket 建立，模拟器侧确认 `ws_clients: 1`
- 规则页的 `get_config` 命令 200

**云端** —— 对着真实的 `wrangler dev --local`（2026-08-21）逐个走通：
注册设备 → 设备领配对码 → 邮箱验证码登录 → App 配对 → 设备列表 →
重命名（中文往返无损）→ 在线状态 → 规则列表 → 历史查询 → 命令转发。
字段名与 `CloudApi` 的预期完全一致，包括设备离线时
`POST /command` 回 `400 + {ok:false, error:{code:"busy"}}` 这种
「HTTP 失败但响应体合法」的情况。

**实时流**（2026-08-21，改用一次性票据之后）：Flutter web 构建产物
对着真实服务端 + 一台真在推数的假设备跑通 ——
`POST /stream-ticket` 200 → `GET /stream?ticket=` **101**，
DO 侧 `subscribers: 1`，**1 次握手、1 张票，无重连风暴**。

## 8. 实时订阅为什么要多换一张票

`/stream` 是唯一不带 `Authorization` 头的请求，因为
**浏览器的 WebSocket API 不允许设置请求头**。

早期版本把 access token 塞进 `?token=`，被服务端 401 拒掉（OPEN-ISSUES S-12）。
现在的做法是先用 Bearer 头换一张票：

```
POST /v1/devices/:id/stream-ticket   →  { ticket, expires_in: 30 }
GET  /v1/devices/:id/stream?ticket=  →  101
```

票据绑定到一台设备、30 秒有效、**用一次即废** ——
所以**每次重连都要重新换**，`CloudChannel._openSocket()` 里就是这么做的。

`test/cloud_channel_test.dart` 有一条专门的回归断言：
**WS 的 URL 里不许出现 access token**。当初那个 bug 之所以没被测出来，
就是因为没人断言过 URL 是怎么拼的。

## 9. 网页版连不上局域网设备

浏览器禁止 https 页面向 http 发请求（混合内容）。设备的局域网 API 是明文
HTTP，因此**由 https 域名提供的网页版无法直连局域网设备** —— 这条在设备端
无解，与 CORS、Token、防火墙都没有关系。

| 构建 | 局域网直连 |
|---|---|
| 原生 Android / iOS / 桌面 | ✅ |
| 网页版，页面走 http（`flutter run -d chrome`、自建内网面板） | ✅ |
| 网页版，页面走 https（线上域名） | ❌ 只能走云 |

例外：https 页面访问 `localhost` / `127.0.0.0/8` / `::1` **不算**混合内容
（浏览器视环回为潜在可信），所以隧道到本机的用法仍然可用。

App 会提前检测并直说，而不是让用户对着一个笼统的网络错误去查 Token 和防火墙。
判定在 `lib/core/lan_reachability.dart`。产品层面怎么收口见工作区 OPEN-ISSUES S-14。

## 10. 尚未实现

- **BLE 配网**（`flutter_blue_plus`，需 Android SDK）—— 见契约 §9.4
- mDNS 自动发现 `_mmradar._tcp`
- token 的安全存储：现在用 `SharedPreferences`，web 上没有 Keychain 等价物；
  原生构建上线前应换 `flutter_secure_storage`
- 本地通知 / FCM / APNs

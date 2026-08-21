/// 邮箱验证码登录。
///
/// 没有密码 —— 服务端只做 OTP（见 05-server-architecture.md §3）。
/// 少一套密码就少一类泄露面，也不用做找回流程。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/cloud_api.dart';
import '../../data/providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

enum _Step { email, code }

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();

  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;

  /// 本地开发时服务端会把验证码回显在响应里，省得去翻邮箱。
  /// 生产环境为 null。
  String? _devCode;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  CloudApi _api() => CloudApi(baseUrl: ref.read(sessionProvider).cloudBaseUrl);

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.error.display);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestCode() {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = '请输入有效的邮箱');
      return Future.value();
    }
    return _run(() async {
      final api = _api();
      try {
        final dev = await api.requestOtp(email);
        if (!mounted) return;
        setState(() {
          _step = _Step.code;
          _devCode = dev;
          if (dev != null) _code.text = dev;
        });
      } finally {
        api.close();
      }
    });
  }

  Future<void> _verify() {
    final email = _email.text.trim();
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() => _error = '验证码不完整');
      return Future.value();
    }
    return _run(() async {
      final api = _api();
      try {
        final tokens = await api.verifyOtp(email, code);
        await ref
            .read(sessionProvider.notifier)
            .signIn(email: email, access: tokens.access, refresh: tokens.refresh);
        // 登录本身不代表能连设备 —— 还要选一台。
        // 由设置页的「我的设备」引导，这里只负责回退。
        if (mounted) Navigator.of(context).pop();
      } finally {
        api.close();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onEmailStep = _step == _Step.email;

    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(onEmailStep ? '用邮箱登录' : '输入验证码', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            onEmailStep ? '我们会给你发一个 6 位验证码，10 分钟内有效。' : '验证码已发到 ${_email.text.trim()}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),

          TextField(
            controller: _email,
            enabled: onEmailStep && !_busy,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: '邮箱',
              prefixIcon: Icon(Icons.alternate_email),
            ),
            onSubmitted: (_) => onEmailStep ? _requestCode() : null,
          ),

          if (!onEmailStep) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              enabled: !_busy,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '验证码',
                prefixIcon: Icon(Icons.pin_outlined),
              ),
              onSubmitted: (_) => _verify(),
            ),
            if (_devCode != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '开发环境已自动填入：$_devCode',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary),
                ),
              ),
          ],

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : (onEmailStep ? _requestCode : _verify),
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(onEmailStep ? '发送验证码' : '登录'),
          ),

          if (!onEmailStep)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _step = _Step.email;
                      _code.clear();
                      _devCode = null;
                      _error = null;
                    }),
              child: const Text('换个邮箱'),
            ),
        ],
      ),
    );
  }
}

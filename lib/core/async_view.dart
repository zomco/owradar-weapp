/// AsyncValue 的渲染约定：**错误优先于加载**。
///
/// Riverpod 3 会自动重试失败的 Provider，而重试期间 `isLoading` 一直是 true、
/// `AsyncValue` 停留在 `AsyncLoading(error: ...)`。直接用 `.when()` 的话
/// `error` 分支永远不触发，界面就成了永远转圈 ——
/// 用户既看不到失败原因，也没有手动重试的入口。
///
/// 对一个「设备可能就是不在线」的产品来说，这是不可接受的：
/// 说不清楚为什么连不上，比连不上本身更让人烦。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider 的重试策略：快速退避两次就放弃。
///
/// 保留少量自动重试是为了吃掉切网、WiFi 漫游这类几百毫秒的抖动；
/// 但不能无限重试 —— 设备真的关机时，用户需要看到结论而不是等待。
Duration? backOffThenGiveUp(int retryCount, Object error) =>
    retryCount >= 2 ? null : Duration(milliseconds: 200 * (retryCount + 1));

/// 把 [AsyncValue] 渲染成组件，错误分支的优先级高于加载分支。
///
/// - 有错误 → [error]（即使 Riverpod 还在后台重试）
/// - 有数据 → [data]（重试导致的 loading 不会把已有数据顶掉）
/// - 其余 → [loading]，默认是居中的转圈
Widget asyncView<T>(
  AsyncValue<T> value, {
  required Widget Function(T data) data,
  required Widget Function(Object error) error,
  Widget Function()? loading,
}) {
  final err = value.error;
  if (err != null) return error(err);

  final v = value.value;
  if (v != null) return data(v);
  if (value.hasValue) return data(value.value as T);

  return loading?.call() ?? const Center(child: CircularProgressIndicator());
}

# flutter_ymodem_lib 中文文档

一个用 **纯 Dart** 实现的 **YModem** 文件传输协议 Flutter 插件，由知名
Android 库 [YModemlib_Android](https://github.com/ArdWang/YModemlib_Android)
（`com.bw.yml.YModem`）移植而来，主要用于 **BLE OTA 固件升级**。

协议引擎全部由 Dart 实现，在 **Android / iOS / Windows / macOS / Linux**
上行为完全一致，**零原生代码、零额外依赖**，并且兼容低版本 Flutter
（插件本体要求 Flutter >= 3.0 / Dart >= 2.17）。

> English docs: [README.md](README.md).

## 快速上手

在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  flutter_ymodem_lib: ^0.0.1
```

```dart
import 'package:flutter_ymodem_lib/flutter_ymodem_lib.dart';

final ymodem = YModem(
  fileName: 'firmware.bin',
  source: YModemFileSource('/path/to/firmware.bin'),
  onDataReady: (package) => 发送到蓝牙(package),
  onProgress: (sent, total) => print('$sent / $total'),
  onSuccess: () => print('升级完成 ✔'),
  onFailed: (reason) => print('升级失败: $reason'),
);

ymodem.start();                    // 直接发送文件名包（0 包）
// ymodem.start('Customized Data'); // 或先发送握手数据，等待接收方回复 'C'

// 把蓝牙收到的每个通知喂给引擎：
ymodem.onReceiveData(收到的字节);

await ymodem.stop();               // 随时终止
```

引擎不依赖任何具体传输方式（BLE / 经典蓝牙 / 串口 / Socket 均可）。

## 配合 flutter_blue_plus 使用

引擎不负责传输，需要自行对接。与 `flutter_blue_plus` 2.3.12（Windows 端即
`flutter_blue_plus_winrt` 0.0.20）配合的完整示例见 [`example/`](example)，
核心接线方式如下：

```dart
// 1. 选定 OTA 服务的写特征和通知特征（例如服务 FFE0、特征 FFE1）
// 2. 请求更大的 MTU，越大传输越快
final mtu = await device.requestMtu(247);

// 3. 把每个包拆成 (MTU - 3) 字节的块写入
Future<void> writeChunked(List<int> data) async {
  final chunkSize = mtu - 3;
  for (var i = 0; i < data.length; i += chunkSize) {
    final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
    await characteristic.write(data.sublist(i, end), withoutResponse: true);
    await Future.delayed(const Duration(milliseconds: 8));
  }
}

// 4. 接线
final ymodem = YModem(
  fileName: basename(filePath),
  source: YModemFileSource(filePath),
  onDataReady: (package) => writeChunked(package),
  onProgress: (sent, total) => updateProgressUi(sent, total),
  onSuccess: () => showDone(),
  onFailed: (reason) => showError(reason),
);
ymodem.start('Customized Data'); // 或 ymodem.start()

notifyCharacteristic.lastValueStream.listen((data) {
  ymodem.onReceiveData(data);
});
```

> **注意**：`flutter_blue_plus` >= 2.3 的 `device.connect()` 需要传
> `License` 参数：个人/教育用途用 `License.nonprofit`，商业产品需使用
> `License.commercial`（详见 flutter_blue_plus 的 LICENSE）。

## 协议流程

```
(可选) 握手数据                     >>>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< C
SOH 00 FF "文件名" "大小" "MD5" ... CRC CRC >>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK C
STX 01 FE data[1024] CRC CRC        >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK
... 每包一个 ACK ...
EOT                                 >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< NAK
EOT                                 >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK
SOH 00 FF NUL[128] CRC CRC          >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK (或 MD5_OK)
```

## 特性

- YModem 发送端完整状态机：握手、0 包（文件名/大小/MD5）、128(SOH)/
  1024(STX) 数据包、EOT、结束包、`MD5_OK`/`MD5_ERR`
- CRC-16/XMODEM 校验（查表实现，帧内大端序）
- `NAK`/超时自动重传（默认最多 6 次，可配置）、`CAN` 处理、`stop()` 终止
- 自动处理 BLE 通知拆包（`ACK` 与 `C` 分两次到达、`MD5_OK` 文本被拆分）
- 流式文件读取，固件无需整体载入内存
- 完整单元测试（CRC 向量、组包格式、模拟接收端端到端、重传、取消）

## API 概览

### `YModem`（引擎）

| 参数 | 默认值 | 说明 |
| ---- | ------ | ---- |
| `fileName` | 必填 | 0 包中的文件名 |
| `source` | 必填 | `YModemSource` 数据源（见下） |
| `onDataReady` | 必填 | 每封装好一个包回调一次，用于发送 |
| `fileMd5` | `''` | 可选 MD5，附加在 0 包中 |
| `sendSize` | `1024` | 数据块大小：`128`（SOH）或 `1024`（STX） |
| `maxRetryTimes` | `6` | 单个包最大重发次数 |
| `packageTimeout` | `6 s` | 等待接收方响应的超时时间 |
| `responseSettleDelay` | `200 ms` | 拆包响应的额外等待时间（`ACK`+`C`、`MD5_OK`） |
| `onProgress` | null | `(sent, total)` 已确认的文件字节数 |
| `onSuccess` / `onFailed` | null | 传输结果回调 |
| `onLog` | null | 协议状态机日志 |

### `YModemSource`

```dart
abstract class YModemSource {
  int get length;
  Future<void> open();
  Future<int> read(Uint8List buffer, int start, int count);
  Future<void> close();
}
```

内置实现：`YModemFileSource(path)`（从磁盘流式读取）和
`YModemBytesSource(bytes)`（内存数据）。

### `YModemPacket` / `Crc16`

底层组包与校验工具，如需扩展引擎（例如实现接收端）可直接使用：
`createFileNamePackage`、`createDataPackage`、`createEndPackage`、
`eotPackage` 以及查表实现的 `Crc16.calc`。

## 示例应用

```bash
cd example
flutter run
```

示例（Android / iOS / Windows / macOS / Linux）演示完整 OTA 流程：

1. 扫描 BLE 设备（`flutter_blue_plus` + Windows 端
   `flutter_blue_plus_winrt`）
2. 连接、协商 MTU、选择写/通知特征（默认服务 `FFE0`、特征 `FFE1`，
   可在 `lib/device_page.dart` 中修改常量适配你的硬件）
3. 选择固件文件
4. 可选：发送握手数据、设置块大小、填写 MD5
5. 实时查看进度、状态与协议十六进制日志

### 各平台说明

- **Android**：清单已预配置蓝牙权限（含 Android 12+ 的
  `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`），首次扫描时申请运行时权限。
- **iOS**：`Info.plist` 已预配置 `NSBluetoothAlwaysUsageDescription`。
- **macOS**：两个 entitlement 文件已预配置蓝牙权限
  （`com.apple.security.personal-information.bluetooth`）。
- **Linux**：运行时需要 BlueZ（`sudo apt install bluez`）。
- **Windows**：开箱即用（WinRT 后端）。

## 兼容性

- `flutter_ymodem_lib` 插件本体：**Flutter >= 3.0 / Dart >= 2.17**。
- 示例应用：Dart >= 3.0 / Flutter >= 3.7（受 `flutter_blue_plus` 2.3.12
  要求限制）。

## 常见问题

- **接收方无响应**：确认已 `setNotifyValue(true)` 并把通知喂给
  `onReceiveData()`。
- **接收方报 CRC 错误**：降低吞吐，加大 `chunkDelay`（15–20ms）或改用
  `sendSize: 128`。
- **`ACK` 和 `C` 分两次通知到达**：引擎已通过 `responseSettleDelay` 处理。
- **进度一直为 0**：接收方没有 ACK 数据包，通常是写特征选错或 MTU 分包
  大小不对。

## 许可证

MIT，见 [LICENSE](LICENSE)。协议逻辑移植自 ArdWang 的
[YModemlib_Android](https://github.com/ArdWang/YModemlib_Android)。

## 更新日志

[CHANGELOG.md](CHANGELOG.md)（[中文版 changelog_cn.md](changelog_cn.md)）

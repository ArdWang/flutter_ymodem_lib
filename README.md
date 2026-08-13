# flutter_ymodem_lib

A **pure Dart** implementation of the **YModem** file transfer protocol for
Flutter, ported from the well-known Android library
[YModemlib_Android](https://github.com/ArdWang/YModemlib_Android)
(`com.bw.yml.YModem`) and designed for **BLE OTA firmware upgrades**.

Because the whole engine is written in Dart, it works identically on
**Android, iOS, Windows, macOS and Linux** (and even on embedded/desktop
Dart) with **zero native code** and **no extra dependencies**.

> 中文文档请见 [readme_cn.md](readme_cn.md)。

| Platform | Support |
| -------- | ------- |
| Android  | ✅ (Dart-only plugin, no native code) |
| iOS      | ✅ |
| Windows  | ✅ |
| macOS    | ✅ |
| Linux    | ✅ |

The plugin itself requires **Flutter >= 3.0 / Dart >= 2.17** — it also works
with old Flutter versions.

## Features

- Sender side of the YModem protocol (the OTA host role):
  - optional custom hello / handshake data (`start('Customized Data')`),
  - package 0 with file name, size and optional MD5,
  - data packages with 128 (SOH) or 1024 (STX) byte blocks,
  - EOT / final empty package handshake,
  - `MD5_OK` / `MD5_ERR` final response support.
- CRC-16/XMODEM (CCITT, poly `0x1021`, big-endian in the frame).
- Automatic retransmission on `NAK` / timeout (up to 6 times by default,
  configurable), `CAN` cancellation handling, `stop()` support.
- Handles responses split over several BLE notifications
  (`ACK` + `C` arriving separately, split `MD5_OK` text).
- Transport-agnostic: BLE, classic Bluetooth, serial, TCP... anything.
- Streaming file source — no need to load the whole firmware into memory.
- Fully unit tested (CRC vectors, package layout, end-to-end transfers
  against a fake receiver, retries, cancellation).

## Getting started

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_ymodem_lib: ^0.0.1
```

### Minimal usage

```dart
import 'package:flutter_ymodem_lib/flutter_ymodem_lib.dart';

final ymodem = YModem(
  fileName: 'firmware.bin',
  source: YModemFileSource('/path/to/firmware.bin'),
  onDataReady: (package) => sendOverYourTransport(package),
  onProgress: (sent, total) => print('$sent / $total bytes'),
  onSuccess: () => print('OTA done ✔'),
  onFailed: (reason) => print('OTA failed: $reason'),
);

// Start directly with package 0:
ymodem.start();
// ...or send custom hello data first and wait for "C":
// ymodem.start('Customized Data');

// Feed every response from the receiver back to the engine:
ymodem.onReceiveData(receivedBytes);

// Abort at any time:
await ymodem.stop();
```

## BLE integration (flutter_blue_plus)

The engine never touches the transport — you connect it yourself. The
[`example/`](example) app shows a complete implementation with
[`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus) (whose
Windows backend is the
[`flutter_blue_plus_winrt`](https://pub.dev/packages/flutter_blue_plus_winrt)
package):

```dart
// 1. Pick the write + notify characteristics of your OTA service
//    (e.g. service FFE0, characteristic FFE1).
// 2. Request a larger MTU: the bigger, the faster.
final mtu = await device.requestMtu(247);

// 3. Split every package into (MTU - 3) byte chunks.
Future<void> writeChunked(List<int> data) async {
  final chunkSize = mtu - 3;
  for (var i = 0; i < data.length; i += chunkSize) {
    final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
    await characteristic.write(data.sublist(i, end), withoutResponse: true);
    await Future.delayed(const Duration(milliseconds: 8));
  }
}

// 4. Wire everything together.
final ymodem = YModem(
  fileName: basename(filePath),
  source: YModemFileSource(filePath),
  onDataReady: (package) => writeChunked(package),
  onProgress: (sent, total) => updateProgressUi(sent, total),
  onSuccess: () => showDone(),
  onFailed: (reason) => showError(reason),
);
ymodem.start('Customized Data'); // or ymodem.start()

notifyCharacteristic.lastValueStream.listen((data) {
  ymodem.onReceiveData(data);
});
```

> **Note**: `flutter_blue_plus` >= 2.3 requires a `License` parameter on
> `device.connect()`. Use `License.nonprofit` for personal/educational use
> and `License.commercial` for commercial products (see the
> flutter_blue_plus LICENSE).

## Protocol flow

```
(optional) hello data              >>>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< C
SOH 00 FF "name" "size" "md5" ... CRC CRC >>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK C
STX 01 FE data[1024] CRC CRC        >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK
... one package per ACK ...
EOT                                 >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< NAK
EOT                                 >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK
SOH 00 FF NUL[128] CRC CRC          >>>>>>>>>>>>>>>>>>>>>>
                                     <<<<<<<<<<<<<<<<<<<< ACK (or MD5_OK)
```

## API overview

### `YModem` (the engine)

| Parameter | Default | Description |
| --------- | ------- | ----------- |
| `fileName` | required | File name sent in package 0 |
| `source` | required | A `YModemSource` (see below) |
| `onDataReady` | required | Called with every package ready to send |
| `fileMd5` | `''` | Optional MD5, appended to package 0 |
| `sendSize` | `1024` | Data block size: `128` (SOH) or `1024` (STX) |
| `maxRetryTimes` | `6` | Max resends of one package before aborting |
| `packageTimeout` | `6 s` | Time to wait for the receiver's response |
| `responseSettleDelay` | `200 ms` | Extra wait for split responses (`ACK`+`C`, `MD5_OK`) |
| `onProgress` | null | `(sent, total)` acknowledged file bytes |
| `onSuccess` / `onFailed` | null | Transfer result callbacks |
| `onLog` | null | Protocol state machine logs |

### `YModemSource`

```dart
abstract class YModemSource {
  int get length;
  Future<void> open();
  Future<int> read(Uint8List buffer, int start, int count);
  Future<void> close();
}
```

Ready-made implementations: `YModemFileSource(path)` (streams from disk) and
`YModemBytesSource(bytes)` (in-memory).

### `YModemPacket` / `Crc16`

Low-level building blocks if you want to extend the engine (e.g. a receiver):
`createFileNamePackage`, `createDataPackage`, `createEndPackage`,
`eotPackage` and the table-driven `Crc16.calc`.

## Example app

```bash
cd example
flutter run
```

The example (Android / iOS / Windows / macOS / Linux) demonstrates the full
OTA workflow:

1. scan for BLE devices (`flutter_blue_plus` + the
   `flutter_blue_plus_winrt` Windows backend),
2. connect, negotiate the MTU and pick the write / notify characteristics
   (defaults: service `FFE0`, characteristic `FFE1` — adjust the constants
   in `lib/device_page.dart` for your hardware),
3. pick a firmware file,
4. optionally send hello data, set the block size and an MD5,
5. watch the progress, the status and a live hex log of the protocol.

### Platform notes

- **Android**: Bluetooth permissions (incl. `BLUETOOTH_SCAN` /
  `BLUETOOTH_CONNECT` for Android 12+) are pre-configured in the manifest;
  runtime permissions are requested on first scan.
- **iOS**: `NSBluetoothAlwaysUsageDescription` is pre-configured in
  `Info.plist`.
- **macOS**: the Bluetooth entitlement
  (`com.apple.security.personal-information.bluetooth`) is pre-configured in
  both entitlement files.
- **Linux**: needs BlueZ (`sudo apt install bluez`) at runtime.
- **Windows**: works out of the box (WinRT backend).

## Compatibility

- `flutter_ymodem_lib` itself: **Flutter >= 3.0 / Dart >= 2.17**.
- The example app: Dart >= 3.0 / Flutter >= 3.7, because that is what
  `flutter_blue_plus` 2.3.12 requires.

## Troubleshooting

- **Receiver answers nothing / timeouts**: check that the notifications are
  enabled on the RX characteristic (`setNotifyValue(true)`) and that every
  received notification is fed into `ymodem.onReceiveData()`.
- **CRC errors on the receiver**: lower the throughput — increase
  `chunkDelay` (e.g. 15–20 ms) or use `sendSize: 128`.
- **`ACK` + `C` arrive as two notifications**: handled by the engine via
  `responseSettleDelay`.
- **Progress stays at 0 %**: the receiver never ACKs the data packages —
  usually a mismatch of the write characteristic or the MTU chunking.

## License

MIT — see [LICENSE](LICENSE). The protocol logic is a Dart port of
[YModemlib_Android](https://github.com/ArdWang/YModemlib_Android) by ArdWang.

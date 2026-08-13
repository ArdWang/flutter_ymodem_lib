/// A pure Dart implementation of the YModem file transfer protocol for
/// Flutter, working on Android, iOS, Windows, macOS and Linux without any
/// native code — ideal for BLE OTA firmware upgrades.
///
/// Typical usage together with [flutter_blue_plus](https://pub.dev/packages/flutter_blue_plus):
///
/// ```dart
/// final ymodem = YModem(
///   fileName: 'firmware.bin',
///   source: YModemFileSource('/path/to/firmware.bin'),
///   onDataReady: (package) => characteristic.write(package, withoutResponse: true),
///   onProgress: (sent, total) => print('$sent / $total bytes'),
///   onSuccess: () => print('OTA done'),
///   onFailed: (reason) => print('OTA failed: $reason'),
/// );
///
/// // Start (optionally with custom hello/handshake data):
/// ymodem.start('Customized Data');
///
/// // Feed every BLE notification from the device back to the engine:
/// notifyCharacteristic.lastValueStream.listen(ymodem.onReceiveData);
/// ```
library flutter_ymodem_lib;

export 'package:flutter_ymodem_lib/src/crc16.dart';
export 'package:flutter_ymodem_lib/src/flutter_ymodem_plugin.dart';
export 'package:flutter_ymodem_lib/src/ymodem.dart';
export 'package:flutter_ymodem_lib/src/ymodem_packet.dart';
export 'package:flutter_ymodem_lib/src/ymodem_source.dart';

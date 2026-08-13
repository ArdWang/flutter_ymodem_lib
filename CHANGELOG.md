## 0.0.2

* Add the `crcTrailingZeros` option (engine, packet builders and
  `Crc16.calc`): `0` (default) uses the standard CRC-16/XMODEM as the
  Android reference library, `2` replicates the `Cccal_CRC16` CRC variant
  of the iOS library YModemlib_iOS, required by the bootloader firmware of
  some devices.
* Improve pub.dev metadata: add `homepage` / `repository`, shorten the
  package description.
* Use `package:` imports in `lib/` (Dart file conventions).

## 0.0.1

* Initial release.
* Pure Dart YModem sender engine ported from
  [YModemlib_Android](https://github.com/ArdWang/YModemlib_Android):
  * hello handshake, package 0 (file name / size / MD5), 128 (SOH) and
    1024 (STX) data packages, EOT and final package handshake,
    `MD5_OK` / `MD5_ERR` support;
  * CRC-16/XMODEM (big-endian in the frame), plus an optional
    `crcTrailingZeros: 2` variant compatible with the iOS library
    YModemlib_iOS (`Cccal_CRC16`);
  * automatic retransmission on `NAK` / timeout, `CAN` handling,
    `stop()` cancellation;
  * split BLE notification responses (`ACK` + `C`, split `MD5_OK`).
* Streaming `YModemSource` with `YModemFileSource` and
  `YModemBytesSource` implementations.
* Registered as a Dart-only plugin for Android, iOS, Windows, macOS and
  Linux (zero native code).
* Full example app for all five platforms with `flutter_blue_plus`
  (2.3.12, Windows backend `flutter_blue_plus_winrt` 0.0.20), file
  picking, MTU negotiation, chunked writes and a live protocol log.
* Unit tests: CRC vectors, package layout, end-to-end transfers against a
  fake receiver, retries, timeout and cancellation.

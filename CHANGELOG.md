## 0.0.1

* Initial release.
* Pure Dart YModem sender engine ported from
  [YModemlib_Android](https://github.com/ArdWang/YModemlib_Android):
  * hello handshake, package 0 (file name / size / MD5), 128 (SOH) and
    1024 (STX) data packages, EOT and final package handshake,
    `MD5_OK` / `MD5_ERR` support;
  * CRC-16/XMODEM (big-endian in the frame);
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

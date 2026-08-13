import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Writes YModem packages to a BLE characteristic.
///
/// Every package is split into chunks of `MTU - 3` bytes (the maximum payload
/// of one ATT write) and written with `withoutResponse: true`, with a small
/// delay between chunks so slow receivers don't drop bytes. Writes are
/// serialized on an internal queue: the YModem engine already waits for the
/// receiver's ACK before handing out the next package, but the queue also
/// protects against re-entrant writes.
class YModemBleTransmitter {
  YModemBleTransmitter({
    required this.device,
    required this.characteristic,
    this.chunkDelay = const Duration(milliseconds: 8),
    this.onLog,
  });

  final BluetoothDevice device;
  final BluetoothCharacteristic characteristic;

  /// Delay between two consecutive chunks. Increase it if the receiver
  /// reports CRC errors on big packages.
  final Duration chunkDelay;

  final void Function(String message)? onLog;

  Future<void> _queue = Future<void>.value();
  int _sentBytes = 0;

  /// Number of payload bytes written since this transmitter was created.
  int get sentBytes => _sentBytes;

  /// Sends [data] to the characteristic, chunk by chunk.
  ///
  /// The returned future completes when the whole package has been handed to
  /// the BLE stack. Concurrent calls are serialized automatically.
  Future<void> send(Uint8List data) {
    _queue = _queue.then((_) => _sendInternal(data));
    return _queue;
  }

  Future<void> _sendInternal(Uint8List data) async {
    final mtu = device.mtuNow;
    // An ATT write can carry at most (MTU - 3) payload bytes.
    final chunkSize = mtu > 23 ? mtu - 3 : 20;
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final end = offset + chunkSize < data.length
          ? offset + chunkSize
          : data.length;
      await characteristic.write(
        data.sublist(offset, end),
        withoutResponse: true,
      );
      _sentBytes += end - offset;
      if (chunkDelay > Duration.zero && end < data.length) {
        await Future<void>.delayed(chunkDelay);
      }
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_ymodem_lib/src/ymodem_packet.dart';
import 'package:flutter_ymodem_lib/src/ymodem_source.dart';

/// Called when a complete YModem package has been encapsulated and is ready
/// to be sent to the receiver (e.g. written to a BLE characteristic).
typedef YModemDataReady = void Function(Uint8List data);

/// Progress callback: [sent] bytes of file data acknowledged so far,
/// [total] file size in bytes.
typedef YModemProgressCallback = void Function(int sent, int total);

/// Called once the whole file has been correctly sent and acknowledged.
typedef YModemSuccessCallback = void Function();

/// Called when the transmission failed after all retries.
typedef YModemFailedCallback = void Function(String reason);

/// Optional log callback for debugging the protocol state machine.
typedef YModemLogCallback = void Function(String message);

/// Exception reported by [YModem.start] / [YModem.onFailed].
class YModemException implements Exception {
  YModemException(this.message);

  final String message;

  @override
  String toString() => 'YModemException: $message';
}

class _YModemCancelled implements Exception {
  const _YModemCancelled();
}

/// The sender side of the YModem protocol, ported from the well-known
/// Android library `YModemlib` (com.bw.yml.YModem) to pure Dart.
///
/// Protocol flow (sender point of view):
///
/// ```
/// (optional) hello data            >>>>>>>>>>>>>>>>>>>>>>>
///                                    <<<<<<<<<<<<<<<<<<<< C
/// SOH 00 FF "name.c" "size" "" ... CRC CRC >>>>>>>>>>>>>>
///                                    <<<<<<<<<<<<<<<<<<<< ACK C
/// STX 01 FE data[1024] CRC CRC      >>>>>>>>>>>>>>>>>>>>>>
///                                    <<<<<<<<<<<<<<<<<<<< ACK
/// ... (one package per ACK) ...
/// EOT                               >>>>>>>>>>>>>>>>>>>>>>
///                                    <<<<<<<<<<<<<<<<<<<< NAK
/// EOT                               >>>>>>>>>>>>>>>>>>>>>>
///                                    <<<<<<<<<<<<<<<<<<<< ACK
/// SOH 00 FF NUL[128] CRC CRC        >>>>>>>>>>>>>>>>>>>>>>
///                                    <<<<<<<<<<<<<<<<<<<< ACK (or MD5_OK)
/// ```
///
/// The engine never touches any transport: every package is handed to
/// [onDataReady] and the receiver's responses must be fed back through
/// [onReceiveData]. This keeps the engine compatible with BLE, classic
/// Bluetooth, serial ports, sockets, ... on every platform.
///
/// ```dart
/// final ymodem = YModem(
///   fileName: 'firmware.bin',
///   source: YModemFileSource('/path/to/firmware.bin'),
///   onDataReady: (package) => writeToBle(package),
///   onProgress: (sent, total) => print('$sent/$total'),
///   onSuccess: () => print('done'),
///   onFailed: (reason) => print('failed: $reason'),
/// );
/// ymodem.start();                    // or ymodem.start('Customized Data')
/// ...
/// ymodem.onReceiveData(bleNotificationBytes);
/// ```
class YModem {
  YModem({
    required this.fileName,
    required YModemSource source,
    required this.onDataReady,
    this.fileMd5 = '',
    this.sendSize = 1024,
    this.crcTrailingZeros = 0,
    this.maxRetryTimes = 6,
    this.packageTimeout = const Duration(seconds: 6),
    this.responseSettleDelay = const Duration(milliseconds: 200),
    this.onProgress,
    this.onSuccess,
    this.onFailed,
    this.onLog,
  }) : _source = source {
    if (sendSize != 128 && sendSize != 1024) {
      throw ArgumentError('sendSize must be 128 or 1024, got $sendSize');
    }
    if (fileName.isEmpty) {
      throw ArgumentError('fileName must not be empty');
    }
    if (maxRetryTimes < 1) {
      throw ArgumentError('maxRetryTimes must be >= 1');
    }
  }

  /// File name (without any path) sent inside package 0.
  final String fileName;

  /// Optional MD5 string appended to package 0. When it is set, the receiver
  /// may answer with the text `MD5_OK` or `MD5_ERR` after the last package
  /// instead of a plain ACK.
  final String fileMd5;

  /// Data block size of every data package: 128 (SOH) or 1024 (STX).
  final int sendSize;

  /// Number of extra zero bytes processed by the CRC-16 after each payload.
  ///
  /// * `0` (default): standard CRC-16/XMODEM, as used by the Android
  ///   reference library `YModemlib_Android`.
  /// * `2`: the CRC variant of the iOS library `YModemlib_iOS`
  ///   (`Cccal_CRC16`), required by the bootloader firmware of some devices
  ///   (e.g. GoDream-based hardware).
  final int crcTrailingZeros;

  /// How many times a single package may be resent (NAK / timeout /
  /// unexpected response) before the transmission is aborted.
  /// Mirrors the reference library default (6).
  final int maxRetryTimes;

  /// How long to wait for the receiver response to a sent package.
  final Duration packageTimeout;

  /// Extra time to wait for additional bytes after a response that may be
  /// followed by more bytes, e.g. `ACK` + `C` split into two BLE
  /// notifications, or a `MD5_OK` text split into several ones.
  final Duration responseSettleDelay;

  /// Every encapsulated package is handed to this callback.
  final YModemDataReady onDataReady;

  /// Progress of the acknowledged file data only (excludes headers and CRCs).
  final YModemProgressCallback? onProgress;

  /// Called when the transmission finished successfully.
  final YModemSuccessCallback? onSuccess;

  /// Called when the transmission failed (after all retries, on CAN, ...).
  final YModemFailedCallback? onFailed;

  /// Optional log callback, useful for debugging the protocol state machine.
  final YModemLogCallback? onLog;

  final YModemSource _source;

  int _errorTimes = 0;
  int _bytesSent = 0;
  bool _running = false;
  bool _stopped = false;
  Completer<Uint8List>? _responseCompleter;
  final List<int> _rxBuffer = <int>[];

  /// Whether a transmission is currently running.
  bool get isRunning => _running;

  /// Bytes of file data acknowledged by the receiver so far.
  int get bytesSent => _bytesSent;

  /// Starts the transmission.
  ///
  /// * If [helloData] is not null, its UTF-8 bytes are sent first and the
  ///   engine waits for `C` before sending package 0. Some bootloaders need
  ///   this handshake (the reference library used `"Data BOOTLOADER"`).
  /// * If it is null, the transmission starts directly with package 0.
  ///
  /// The returned future completes when the transmission has finished
  /// successfully, failed ([onFailed] / [YModemException]), or was cancelled
  /// with [stop]. On success and on failure the callbacks are invoked before
  /// the future completes.
  Future<void> start([String? helloData]) async {
    if (_running) {
      _log('start() ignored: a transmission is already running');
      return;
    }
    _running = true;
    _stopped = false;
    _errorTimes = 0;
    _bytesSent = 0;
    try {
      await _source.open();
      _log(
        'transmission started: file=$fileName size=${_source.length} '
        'md5=${fileMd5.isEmpty ? 'none' : fileMd5} block=$sendSize',
      );
      if (helloData != null) {
        await _stepHello(Uint8List.fromList(utf8.encode(helloData)));
      }
      await _stepFileName();
      await _stepFileBody();
      await _stepEot();
      await _stepEnd();
      _log('transmission finished successfully');
      onSuccess?.call();
    } on _YModemCancelled {
      _log('transmission cancelled');
    } on YModemException catch (e) {
      _log('transmission failed: ${e.message}');
      onFailed?.call(e.message);
    } finally {
      _running = false;
      _stopped = false;
      _responseCompleter = null;
      _rxBuffer.clear();
      await _source.close();
    }
  }

  /// Feeds the receiver's response bytes (e.g. every BLE notification).
  ///
  /// A response may be delivered in several chunks; bytes are buffered and
  /// handed to the state machine as a whole.
  void onReceiveData(List<int> data) {
    if (data.isEmpty) return;
    _rxBuffer.addAll(data);
    final completer = _responseCompleter;
    if (completer != null && !completer.isCompleted) {
      final buffered = Uint8List.fromList(_rxBuffer);
      _rxBuffer.clear();
      completer.complete(buffered);
    }
  }

  /// Stops / cancels the running transmission.
  ///
  /// The future returned by [start] completes without invoking [onFailed].
  Future<void> stop() async {
    if (!_running && _responseCompleter == null) return;
    _log('stop() requested');
    _stopped = true;
    final completer = _responseCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(Uint8List(0));
    }
  }

  // -------------------------------------------------------------------------
  // Steps of the state machine
  // -------------------------------------------------------------------------

  Future<void> _stepHello(Uint8List hello) async {
    _log('STEP_HELLO: sending hello data (${hello.length} bytes)');
    await _sendAndWaitSuccess(
      hello,
      stepName: 'STEP_HELLO',
      isSuccess: (resp) => resp.isNotEmpty && resp.first == YModemPacket.stC,
    );
  }

  Future<void> _stepFileName() async {
    _log('STEP_FILE_NAME: sending package 0');
    final package = YModemPacket.createFileNamePackage(
      fileName,
      _source.length,
      fileMd5: fileMd5,
      crcTrailingZeros: crcTrailingZeros,
    );
    await _sendAndWaitSuccess(
      package,
      stepName: 'STEP_FILE_NAME',
      isSuccess: _isAckC,
    );
  }

  Future<void> _stepFileBody() async {
    _log('STEP_FILE_BODY: sending file data');
    final buffer = Uint8List(sendSize);
    var sequence = 1;
    while (true) {
      _checkStopped();
      final read = await _source.read(buffer, 0, sendSize);
      _checkStopped();
      if (read <= 0) {
        _log('STEP_FILE_BODY: file data fully read');
        return;
      }
      final package = YModemPacket.createDataPackage(
        buffer,
        read,
        sequence,
        crcTrailingZeros: crcTrailingZeros,
      );
      sequence = (sequence + 1) & 0xFF;
      await _sendAndWaitSuccess(
        package,
        stepName: 'STEP_FILE_BODY',
        isSuccess: (resp) =>
            resp.length == 1 && resp.first == YModemPacket.ack,
      );
      _bytesSent += read;
      onProgress?.call(_bytesSent, _source.length);
    }
  }

  Future<void> _stepEot() async {
    _log('STEP_EOT: sending EOT');
    await _sendAndWaitSuccess(
      YModemPacket.eotPackage,
      stepName: 'STEP_EOT',
      isSuccess: (resp) => resp.isNotEmpty && resp.first == YModemPacket.ack,
    );
  }

  Future<void> _stepEnd() async {
    _log('STEP_END: sending the final empty package');
    await _sendAndWaitSuccess(
      YModemPacket.createEndPackage(crcTrailingZeros: crcTrailingZeros),
      stepName: 'STEP_END',
      isSuccess: _isEndSuccess,
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Sends [package] and waits for a response that satisfies [isSuccess].
  ///
  /// The package is resent on timeout / NAK / any response that does not
  /// satisfy [isSuccess], up to [maxRetryTimes] times. A CAN response or too
  /// many failed attempts throw a [YModemException].
  Future<Uint8List> _sendAndWaitSuccess(
    Uint8List package, {
    required String stepName,
    required FutureOr<bool> Function(Uint8List resp) isSuccess,
  }) async {
    while (true) {
      _checkStopped();
      onDataReady(package);
      final resp = await _waitResponse();
      _checkStopped();
      if (resp != null) {
        if (resp.isNotEmpty && resp.first == YModemPacket.can) {
          throw YModemException('received CAN from the receiver');
        }
        if (await isSuccess(resp)) {
          _errorTimes = 0;
          return resp;
        }
      }
      _errorTimes++;
      final reason = resp == null ? 'timeout' : 'response ${_describe(resp)}';
      _log('$stepName: resending package ($reason, try $_errorTimes/$maxRetryTimes)');
      if (_errorTimes >= maxRetryTimes) {
        throw YModemException(
          '$stepName failed after $maxRetryTimes retries ($reason)',
        );
      }
    }
  }

  /// Waits for the next receiver response. Returns `null` on timeout.
  Future<Uint8List?> _waitResponse() async {
    final completer = Completer<Uint8List>();
    _responseCompleter = completer;
    _flushBufferInto(completer);
    try {
      return await completer.future.timeout(packageTimeout);
    } on TimeoutException {
      return null;
    } finally {
      _responseCompleter = null;
    }
  }

  /// Waits [responseSettleDelay] for extra bytes after a response that may
  /// continue (split `ACK`+`C`, split `MD5_OK` text). Returns the extra
  /// bytes, or `null` if nothing arrived in time.
  Future<Uint8List?> _settleWait() async {
    final completer = Completer<Uint8List>();
    _responseCompleter = completer;
    _flushBufferInto(completer);
    try {
      return await completer.future.timeout(responseSettleDelay);
    } on TimeoutException {
      return null;
    } finally {
      _responseCompleter = null;
    }
  }

  void _flushBufferInto(Completer<Uint8List> completer) {
    if (_rxBuffer.isEmpty) return;
    final buffered = Uint8List.fromList(_rxBuffer);
    _rxBuffer.clear();
    if (!completer.isCompleted) completer.complete(buffered);
  }

  void _checkStopped() {
    if (_stopped) throw const _YModemCancelled();
  }

  /// Success predicate for package 0: `ACK` immediately followed by `C`.
  /// The `C` may arrive in a separate notification: in that case we wait
  /// [responseSettleDelay] for it.
  Future<bool> _isAckC(Uint8List resp) async {
    final ack = YModemPacket.ack;
    final c = YModemPacket.stC;
    if (resp.length >= 2 && resp[0] == ack && resp[1] == c) return true;
    if (resp.length == 1 && resp[0] == ack) {
      final more = await _settleWait();
      if (more != null && more.isNotEmpty && more.first == c) return true;
    }
    return false;
  }

  /// Success predicate for the final package: a plain ACK, or — when an MD5
  /// was provided — the `MD5_OK` text (possibly split over several
  /// notifications).
  Future<bool> _isEndSuccess(Uint8List resp) async {
    if (resp.isNotEmpty && resp.first == YModemPacket.ack) return true;
    if (fileMd5.isEmpty) return false;
    var text = latin1.decode(resp, allowInvalid: true);
    if (text.contains('MD5_OK')) return true;
    if (text.contains('MD5_ERR')) {
      throw YModemException('MD5 check failed on the receiver');
    }
    final more = await _settleWait();
    if (more != null) {
      text += latin1.decode(more, allowInvalid: true);
      if (text.contains('MD5_OK')) return true;
      if (text.contains('MD5_ERR')) {
        throw YModemException('MD5 check failed on the receiver');
      }
    }
    return false;
  }

  String _describe(Uint8List resp) {
    return '[${resp.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}]';
  }

  void _log(String message) => onLog?.call(message);
}

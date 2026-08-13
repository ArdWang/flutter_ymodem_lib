import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ymodem_lib/flutter_ymodem_lib.dart';

/// A spec-compliant fake YModem receiver driven synchronously through the
/// engine's [YModem.onDataReady] callback.
///
/// It strictly verifies every received package (header, complement, CRC)
/// and simulates the requested receiver behaviours.
class FakeReceiver {
  FakeReceiver({
    this.nakFirstDataFrame = false,
    this.replyCanOnFrame0 = false,
    this.replyMd5Ok = false,
    this.silent = false,
    this.onDataFrameAcked,
  });

  /// Reply with NAK to the first data frame (forces one resend).
  final bool nakFirstDataFrame;

  /// Reply with CAN to package 0.
  final bool replyCanOnFrame0;

  /// Reply with the text "MD5_OK" to the final package.
  final bool replyMd5Ok;

  /// Never answer anything.
  final bool silent;

  /// Invoked after every successfully ACKed data frame.
  final void Function(int ackedFrames)? onDataFrameAcked;

  /// All file data bytes received in data frames.
  final List<int> received = <int>[];

  /// File size parsed from package 0.
  int fileSize = -1;

  /// Number of data frame arrivals (duplicates from resends included).
  int dataFrameCount = 0;

  /// Number of data frames that were acknowledged.
  int ackedFrameCount = 0;

  bool frame0Seen = false;
  bool endFrameSeen = false;
  bool helloSeen = false;

  /// When [nakFirstDataFrame] is set: the bytes of the NAKed frame and of the
  /// resent one, used to verify that the engine resent the identical frame.
  Uint8List? nackedFrame;
  bool resentFrameMatches = false;

  int _eotCount = 0;
  bool _bodyStarted = false;

  void onData(List<int> data, YModem ymodem) {
    if (silent) return;

    // EOT?
    if (data.length == 1 && data[0] == YModemPacket.eot) {
      _eotCount++;
      ymodem.onReceiveData(
        [_eotCount == 1 ? YModemPacket.nak : YModemPacket.ack],
      );
      return;
    }

    // Hello data?
    if (data[0] != YModemPacket.soh && data[0] != YModemPacket.stx) {
      helloSeen = true;
      ymodem.onReceiveData([YModemPacket.stC]);
      return;
    }

    final payloadLength = data[0] == YModemPacket.stx ? 1024 : 128;
    final seq = data[1];

    // Verify the header complement.
    expect(data[2], (~seq) & 0xFF, reason: 'header complement mismatch');
    // Verify the CRC (big-endian).
    final payload = data.sublist(3, 3 + payloadLength);
    final crc = Crc16.calc(payload);
    expect(data[3 + payloadLength], (crc >> 8) & 0xFF, reason: 'CRC hi mismatch');
    expect(data[3 + payloadLength + 1], crc & 0xFF, reason: 'CRC lo mismatch');

    if (seq == 0 && !_bodyStarted) {
      // Package 0: file name / size / md5.
      frame0Seen = true;
      if (replyCanOnFrame0) {
        ymodem.onReceiveData([YModemPacket.can]);
        return;
      }
      fileSize = _parseFileSize(payload);
      ymodem.onReceiveData([YModemPacket.ack, YModemPacket.stC]);
      return;
    }

    if (seq == 0) {
      // The final empty package.
      endFrameSeen = true;
      if (replyMd5Ok) {
        ymodem.onReceiveData('MD5_OK'.codeUnits);
      } else {
        ymodem.onReceiveData([YModemPacket.ack]);
      }
      return;
    }

    // Data frame.
    _bodyStarted = true;
    dataFrameCount++;
    if (nakFirstDataFrame && dataFrameCount == 1) {
      nackedFrame = Uint8List.fromList(data);
      ymodem.onReceiveData([YModemPacket.nak]);
      return;
    }
    if (nackedFrame != null && resentFrameMatches == false) {
      resentFrameMatches =
          _bytesEqual(nackedFrame!, Uint8List.fromList(data));
    }
    received.addAll(payload);
    ackedFrameCount++;
    ymodem.onReceiveData([YModemPacket.ack]);
    onDataFrameAcked?.call(ackedFrameCount);
  }

  static int _parseFileSize(List<int> payload) {
    var i = 0;
    while (i < payload.length && payload[i] != 0) {
      i++;
    }
    i++; // skip the NUL separator
    final sizeBytes = <int>[];
    while (i < payload.length && payload[i] != 0) {
      sizeBytes.add(payload[i]);
      i++;
    }
    return int.parse(utf8.decode(sizeBytes));
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class TransferResult {
  bool success = false;
  bool failed = false;
  String? reason;
  int progressCalls = 0;
  int lastProgressSent = -1;
  int lastProgressTotal = -1;
  final List<Uint8List> sentPackages = <Uint8List>[];
}

/// Runs a full transfer against a [FakeReceiver] and waits for its outcome.
Future<TransferResult> runTransfer(
  Uint8List fileBytes,
  FakeReceiver receiver, {
  String? hello,
  int sendSize = 1024,
  int maxRetryTimes = 6,
  Duration packageTimeout = const Duration(seconds: 6),
  String fileMd5 = '',
  YModem? Function(YModem engine)? exposeEngine,
}) async {
  final result = TransferResult();
  final done = Completer<void>();
  late final YModem ymodem;
  ymodem = YModem(
    fileName: 'test.bin',
    source: YModemBytesSource(fileBytes),
    sendSize: sendSize,
    maxRetryTimes: maxRetryTimes,
    packageTimeout: packageTimeout,
    fileMd5: fileMd5,
    onDataReady: (package) {
      result.sentPackages.add(package);
      receiver.onData(package, ymodem);
    },
    onProgress: (sent, total) {
      result.progressCalls++;
      result.lastProgressSent = sent;
      result.lastProgressTotal = total;
    },
    onSuccess: () {
      result.success = true;
      if (!done.isCompleted) done.complete();
    },
    onFailed: (reason) {
      result.failed = true;
      result.reason = reason;
      if (!done.isCompleted) done.complete();
    },
  );
  exposeEngine?.call(ymodem);
  unawaited(
    ymodem.start(hello).then((_) {
      if (!done.isCompleted) done.complete();
    }),
  );
  await done.future;
  return result;
}

Uint8List testFile(int size) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i * 31 + 7) & 0xFF; // deterministic pseudo-random data
  }
  return bytes;
}

void main() {
  group('YModem engine (end to end against a fake receiver)', () {
    test('sends a complete file with hello handshake (2500 bytes, STX)',
        () async {
      final file = testFile(2500);
      final receiver = FakeReceiver();
      final result = await runTransfer(file, receiver, hello: 'Customized Data');

      expect(result.success, isTrue);
      expect(result.failed, isFalse);
      expect(receiver.helloSeen, isTrue);
      expect(receiver.frame0Seen, isTrue);
      expect(receiver.endFrameSeen, isTrue);
      expect(receiver.fileSize, 2500);
      expect(receiver.dataFrameCount, 3); // 1024 + 1024 + 452
      expect(
        receiver.received.sublist(0, 2500),
        file,
      );
      // Progress reached 100% exactly.
      expect(result.progressCalls, 3);
      expect(result.lastProgressSent, 2500);
      expect(result.lastProgressTotal, 2500);
      // hello + frame0 + 3 data + 2 EOT + end = 8 packages.
      expect(result.sentPackages.length, 8);
    });

    test('sends a file that is an exact multiple of the block size',
        () async {
      final file = testFile(2048);
      final receiver = FakeReceiver();
      final result = await runTransfer(file, receiver);

      expect(result.success, isTrue);
      expect(receiver.dataFrameCount, 2);
      expect(receiver.received, file);
    });

    test('supports 128-byte blocks (SOH)', () async {
      final file = testFile(300);
      final receiver = FakeReceiver();
      final result = await runTransfer(file, receiver, sendSize: 128);

      expect(result.success, isTrue);
      expect(receiver.dataFrameCount, 3); // 128 + 128 + 44
      expect(receiver.received.sublist(0, 300), file);
      // Every data frame has an SOH header.
      final dataFrames = result.sentPackages
          .where((p) => p.length == 3 + 128 + 2 && p[0] == YModemPacket.soh)
          .where((p) => p[1] != 0); // skip frame 0 and the end package
      expect(dataFrames.length, 3);
    });

    test('without hello data it starts directly with package 0', () async {
      final receiver = FakeReceiver();
      final result = await runTransfer(testFile(100), receiver);

      expect(result.success, isTrue);
      expect(receiver.helloSeen, isFalse);
      expect(result.sentPackages.first[0], YModemPacket.soh);
      expect(result.sentPackages.first[1], 0x00); // package 0
    });

    test('resends the identical frame after a NAK', () async {
      final receiver = FakeReceiver(nakFirstDataFrame: true);
      final result = await runTransfer(testFile(2500), receiver);

      expect(result.success, isTrue);
      expect(receiver.dataFrameCount, 4); // one frame arrived twice
      expect(receiver.resentFrameMatches, isTrue);
      expect(receiver.received.sublist(0, 2500), testFile(2500));
    });

    test('fails when the receiver answers CAN', () async {
      final receiver = FakeReceiver(replyCanOnFrame0: true);
      final result = await runTransfer(testFile(100), receiver);

      expect(result.success, isFalse);
      expect(result.failed, isTrue);
      expect(result.reason, contains('CAN'));
    });

    test('fails after the maximum number of retries on timeout', () async {
      final receiver = FakeReceiver(silent: true);
      final result = await runTransfer(
        testFile(100),
        receiver,
        packageTimeout: const Duration(milliseconds: 100),
        maxRetryTimes: 2,
      );

      expect(result.success, isFalse);
      expect(result.failed, isTrue);
      expect(result.reason, contains('retries'));
      expect(result.reason, contains('timeout'));
    });

    test('stop() cancels the transmission without onFailed', () async {
      late YModem engine;
      final receiver = FakeReceiver(
        onDataFrameAcked: (acked) {
          if (acked == 1) {
            unawaited(engine.stop());
          }
        },
      );
      final result = await runTransfer(
        testFile(5000), // many frames, stopped after the first one
        receiver,
        exposeEngine: (e) => engine = e,
      );

      expect(result.success, isFalse);
      expect(result.failed, isFalse); // cancelled silently
      expect(receiver.ackedFrameCount, lessThan(5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.isRunning, isFalse);
    });

    test('accepts a MD5_OK text as the final response', () async {
      final receiver = FakeReceiver(replyMd5Ok: true);
      final result = await runTransfer(
        testFile(2000),
        receiver,
        fileMd5: '0123456789abcdef0123456789abcdef',
      );

      expect(result.success, isTrue);
      expect(result.failed, isFalse);
    });

    test('file name package contains the size and md5', () async {
      final receiver = FakeReceiver();
      final result = await runTransfer(
        testFile(1234),
        receiver,
        fileMd5: 'd41d8cd98f00b204e9800998ecf8427e',
      );
      expect(receiver.fileSize, 1234);
      // The frame 0 payload must contain the md5 text.
      final frame0 = result.sentPackages[0];
      final payload = frame0.sublist(3, 3 + 128);
      expect(
        String.fromCharCodes(payload).contains('d41d8cd98f00b204e9800998ecf8427e'),
        isTrue,
      );
    });
  });

  group('YModem parameter validation', () {
    test('rejects an invalid sendSize', () {
      expect(
        () => YModem(
          fileName: 'a.bin',
          source: YModemBytesSource(Uint8List(10)),
          onDataReady: (_) {},
          sendSize: 512,
        ),
        throwsArgumentError,
      );
    });

    test('rejects an empty file name', () {
      expect(
        () => YModem(
          fileName: '',
          source: YModemBytesSource(Uint8List(10)),
          onDataReady: (_) {},
        ),
        throwsArgumentError,
      );
    });
  });
}

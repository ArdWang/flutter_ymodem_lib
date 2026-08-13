import 'package:flutter_ymodem_lib/src/ymodem.dart';
import 'package:flutter_ymodem_lib/src/ymodem_source.dart';

/// The plugin class registered by `dartPluginClass` for Android, iOS,
/// Windows, macOS and Linux.
///
/// The whole YModem engine is implemented in pure Dart, therefore this
/// class mainly serves as the plugin entry point and as a convenience
/// factory for [YModem] instances:
///
/// ```dart
/// final ymodem = FlutterYModemPlugin.instance.createYModem(
///   fileName: 'firmware.bin',
///   source: YModemFileSource(path),
///   onDataReady: sendOverBle,
/// );
/// ```
class FlutterYModemPlugin {
  FlutterYModemPlugin();

  static FlutterYModemPlugin? _instance;

  /// The shared plugin instance.
  static FlutterYModemPlugin get instance =>
      _instance ??= FlutterYModemPlugin();

  /// Called by the generated plugin registrant of every platform.
  @pragma('vm:entry-point')
  static void registerWith() {
    _instance = FlutterYModemPlugin();
  }

  /// Creates a new [YModem] sender engine. See [YModem] for the parameters.
  YModem createYModem({
    required String fileName,
    required YModemSource source,
    required YModemDataReady onDataReady,
    String fileMd5 = '',
    int sendSize = 1024,
    int crcTrailingZeros = 0,
    int maxRetryTimes = 6,
    Duration packageTimeout = const Duration(seconds: 6),
    Duration responseSettleDelay = const Duration(milliseconds: 200),
    YModemProgressCallback? onProgress,
    YModemSuccessCallback? onSuccess,
    YModemFailedCallback? onFailed,
    YModemLogCallback? onLog,
  }) {
    return YModem(
      fileName: fileName,
      source: source,
      onDataReady: onDataReady,
      fileMd5: fileMd5,
      sendSize: sendSize,
      crcTrailingZeros: crcTrailingZeros,
      maxRetryTimes: maxRetryTimes,
      packageTimeout: packageTimeout,
      responseSettleDelay: responseSettleDelay,
      onProgress: onProgress,
      onSuccess: onSuccess,
      onFailed: onFailed,
      onLog: onLog,
    );
  }
}

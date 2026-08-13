## 0.0.2

* 新增 `crcTrailingZeros` 选项（引擎、组包器与 `Crc16.calc` 均支持）：
  `0`（默认）使用与 Android 参考库一致的标准 CRC-16/XMODEM；`2` 复刻
  iOS 库 YModemlib_iOS 的 `Cccal_CRC16` CRC 变体，部分设备的 bootloader
  固件要求该变体。
* 完善 pub.dev 元数据：补充 `homepage` / `repository`、精简包描述。
* `lib/` 内改用 `package:` 导入（符合 Dart 文件规范）。

## 0.0.1

* 首个版本发布。
* 由 [YModemlib_Android](https://github.com/ArdWang/YModemlib_Android) 移植的
  纯 Dart YModem 发送端引擎：
  * 握手数据、0 包（文件名 / 大小 / MD5）、128（SOH）与 1024（STX）字节
    数据包、EOT 与结束包握手、`MD5_OK` / `MD5_ERR` 支持；
  * CRC-16/XMODEM 校验（帧内大端序），并提供 `crcTrailingZeros: 2` 选项
    兼容 iOS 库 YModemlib_iOS 的 `Cccal_CRC16` CRC 变体；
  * `NAK` / 超时自动重传、`CAN` 处理、`stop()` 终止；
  * 自动处理 BLE 通知拆包响应（`ACK` + `C` 分离到达、`MD5_OK` 文本被拆分）。
* 流式 `YModemSource` 数据源，内置 `YModemFileSource`（磁盘文件）与
  `YModemBytesSource`（内存数据）实现。
* 以纯 Dart 插件方式注册 Android、iOS、Windows、macOS、Linux 五个平台
  （零原生代码）。
* 完整示例应用，覆盖五个平台：`flutter_blue_plus`（2.3.12，Windows 后端
  `flutter_blue_plus_winrt` 0.0.20）扫描连接、文件选择、MTU 协商、分包
  写入、实时协议日志。
* 单元测试：CRC 向量、组包格式、模拟接收端端到端传输、重传、超时与
  取消。

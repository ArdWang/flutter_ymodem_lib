## 0.0.1

* 首个版本发布。
* 由 [YModemlib_Android](https://github.com/ArdWang/YModemlib_Android) 移植的
  纯 Dart YModem 发送端引擎：
  * 握手数据、0 包（文件名 / 大小 / MD5）、128（SOH）与 1024（STX）字节
    数据包、EOT 与结束包握手、`MD5_OK` / `MD5_ERR` 支持；
  * CRC-16/XMODEM 校验（帧内大端序）；
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

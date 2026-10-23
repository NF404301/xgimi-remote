# 架构

`ProjectorWake.swift` 负责 iBeacon 广播和 App Intents；`ADBClient.swift` 用 Network.framework 实现一次一连接的 ADB shell / SYNC 上传；`RemoteModel.swift` 负责状态、遥控、文件、Photos 和日志；`RemoteViews.swift` 提供遥控、应用和设备三页。

开机路径：点击/快捷指令 → 前台 iBeacon → 投影仪接收 → 独立检查联网。广播 API 回调不能证明投影仪已开机。

在线控制路径：同一局域网 → TCP 5555 → ADB shell / SYNC。无云端、无 Mac 常驻中转。相册添加由 iOS Photos 授权管理。

每条网络请求有截止时间与输出大小限制。录屏独立启动并记录 PID；停止前核对进程命令行含本次唯一文件路径，避免误杀其他进程。App 自建远端临时文件下载成功后清除。

待机统一通过 RemoteModel.sendStandby，使用已对照验证过的电源键 26，发送前检查 Awake。不要改回系统休眠键 223 后假定同样可唤醒。

BeaconConfiguration.swift 是纯 Foundation 配置层，验证并归一化 MAC，再生成目标 UUID；公开版默认值为空，本机偏好只在安装者手机保存。

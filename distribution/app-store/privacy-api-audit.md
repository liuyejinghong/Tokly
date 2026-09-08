# Required-reason API核对

本文件记录已检查用途，不代替App Store Connect隐私表单或Apple最终验证。

| 分类 | 原因 | 当前用途 |
| --- | --- | --- |
| File Timestamp | C617.1 | 应用/组件容器内的缓存和快照文件元数据 |
| File Timestamp | 3B52.1 | 用户明确授权的日志目录中的文件元数据与缓存失效判断 |
| User Defaults | CA92.1 | 主应用自己的显示和采集偏好 |
| System Boot Time | 35F9.1 | 进程超时、重试和应用内经过时间/定时器计算 |

商店采集器使用系统SQLite。原捆绑SQLite的statfs/fstatfs调用用于文件系统类型/锁策略，不能虚构成剩余空间检查理由。系统SQLite构建已通过现有Collector测试和合成结果对照，且自身Mach-O中不再引用statfs/fstatfs；仍需对最终Archive再次核对，不把开发构建结果永久沿用。

主应用和Widget分别包含PrivacyInfo.xcprivacy。当前清单声明API使用理由和不追踪；App Privacy数据收集表单还需对最终网络行为、支持邮件和公开隐私政策单独复核，不能仅凭清单推定已完成。

官方依据：
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype

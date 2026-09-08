# Tokly 0.1.0 CPU / 内存评估

状态：最新Release采集器测试已完成；主应用的Release空闲、交互和端到端采集测试尚未完成。当前桌面控制连接断开，等待退出已运行的旧版后切换。不能用此前0.1/build1 Debug的短时样本代替本版本结论。

## 被测对象与方法

- 版本0.1.0，build2，Release；源码提交beb4c13b176362f204249f68a7c6daf65b9b87dc。
- 使用这份已签名应用内的tokens-collector直接运行，非早期collector-probe；指纹见[evidence/release-0.1.0.json](evidence/release-0.1.0.json)。
- macOS26.5.2 arm64；使用当前用户选择的8个来源，共发现4822项来源文件/数据库。报表范围2026-09-01至09-08。
- 热扫描使用应用缓存的独立副本，三次重复；冷扫描仅预放同一公开价表，没有消息缓存。没有新增线程上限。源客户端可能继续写日志，因此不是完全静止的同语料回放。
- 冷指消息缓存冷，不是操作系统文件缓存冷。真实日志及扫描输出只在本机临时目录，仓库只保存测量摘要。
- /usr/bin/time -l取得完整子进程CPU时间、最大RSS和peak memory footprint；另用proc_pid_rusage以约100ms间隔采样热扫描。
- 原生CPU计时通过mach_timebase_info转换（本机125/3），并用Python进程CPU时钟做独立交叉检查。100%表示一个逻辑核心，不能直接当作整机占用百分比。

## 最新Release采集器结果

| 场景 | 墙钟秒 | CPU秒（user+system） | 活动期平均CPU | 最大RSS MiB | 峰值physical footprint MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 热缓存1 | 5.051 | 6.81 | 134.8% | 846.4 | 840.6 |
| 热缓存2 | 4.562 | 6.94 | 152.1% | 840.7 | 834.9 |
| 热缓存3 | 4.580 | 6.89 | 150.4% | 841.0 | 835.3 |
| 冷消息缓存 | 27.989 | 134.10 | 479.1% | 2487.9 | 2777.9 |

独立热扫描采样观察到CPU峰值约491%（约4.9个逻辑核心的瞬时工作量），不是硬上限。采样可能漏掉更短峰值；完整运行CPU时间以time工具结果为准。

RSS与physical footprint不是同一指标，不能互换。冷扫描约2.43GiB RSS、2.71GiB footprint；子进程结束后这些内存不应被当作主应用常驻内存。

按三次热扫描CPU时间中位数6.89秒估算，10分钟一次约41.3CPU秒/小时，折算约1.15%的单核持续工作量；5分钟一次约82.7CPU秒/小时、2.30%。这是频率线性估算，不是电池或整机CPU实测，未包含主应用、WidgetKit、价格下载等成本。

## 判断与待补项

当前采集器热扫描持续数秒、短时内存接近0.83GiB，冷消息缓存峰值达到数GiB。这是需要关注的资源开销，不能以后台空闲CPU低来掩盖。

优先排查完整历史消息加载/解析后再按报表范围过滤的路径；这符合当前调用链，但尚未做分配栈分析，不能直接归因全部内存。任何优化都要保持原计数与去重口径，禁止回退到已知漏计的mtime今日快捷路径。

待完成：最新Release主应用空闲/界面交互/采集全过程的CPU与RSS/footprint、采集后内存是否回落、可单独观测的Widget进程成本。共享系统渲染进程无法简单归因给Tokly，未出现独立Widget进程也不代表组件开销为零。

## 复测入口

对已运行的目标版本采样（先核实它确实是对应版本的进程）：

```sh
python3 scripts/profile-runtime.py --app "$HOME/Applications/Tokly.app" \
  --phase idle --seconds 60 --interval 0.25 \
  --output /private/tmp/tokly-idle.json
python3 scripts/test_profile_runtime.py
```

对采集器使用协议参数调用并以`/usr/bin/time -l`包裹，输出保存在本机临时目录。不要直接将包含真实用量的scan JSON提交到Git。冷/热测试应使用不同临时config目录，不能反复复用已经预热的目录仍标作冷缓存。

原始摘要：[完整运行](evidence/perf-0.1.0-helper.json)、[热扫描采样](evidence/perf-0.1.0-warm-peak.json)。

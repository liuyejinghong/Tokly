# 版本管理

采用用户确认的 `x.y.z`：x 为大版本，y 为新增功能，z 为优化和修复。开发阶段从0.1.0开始；进入正式1.x由用户决定，不自动将功能更新升为大版本。

唯一应用版本来源是Config/Version.xcconfig：MARKETING_VERSION为x.y.z，CURRENT_PROJECT_VERSION为独立递增的构建号。主应用和扩展均引用这份配置。Collector包版本同步产品版本，上游tokens-core保持其自身版本不改。

```sh
python3 scripts/version.py check
python3 scripts/version.py bump patch  # 0.1.0 → 0.1.1，build +1
python3 scripts/version.py bump minor  # 0.1.1 → 0.2.0，build +1
python3 scripts/version.py bump major  # 0.2.0 → 1.0.0，build +1
python3 scripts/version.py bump build  # 产品版本不变，build +1
```

仅在准备新的交付版本时执行一次递增；普通本地重复编译不自动改版本。bump会同步Collector/Cargo.toml和Collector/Cargo.lock，不创建Git标签、不推送、不发布。

发布顺序：更新版本与CHANGELOG → 相关检查 → 提交代码 → Release签名构建 → 核验安装包版本、构建配置、源码提交与实际运行 → 为该源码提交建立不可移动的vX.Y.Z标签及GitHub Release记录。性能证据可以在后续文档提交中追加，必须标明被测源码提交和安装包指纹。

`bash scripts/build-local.sh` 默认Release，`bash scripts/build-local.sh Debug`用于诊断；二者输出分别在.build/TokensSigned/Build/Products/Release和Debug。安装包Info.plist记录ToklyBuildConfiguration和ToklyGitCommit。源码有未提交改动时不要把它作为可追溯发布构建。

已发布版本禁止移动标签或覆盖不同内容；后续修复使用新的z和构建号。私有GitHub Release不代表完成Developer ID公证或公开发行验收。

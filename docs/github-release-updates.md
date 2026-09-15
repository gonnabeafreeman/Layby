# 不经 Apple 公证的 GitHub Release 自更新方案

日期：2026-09-15。状态：**Sparkle 已接入；已完成本地签名包和 appcast 生成验证，尚未完成线上跨版本安装验证。**

## 1. 结论

可以不做 Apple 公证，以公开 GitHub Releases 托管更新清单和更新包，并用 Sparkle 2 完成检测、下载、签名校验、替换和重启。

这不等于 macOS 一定不会拦截首次安装：未公证应用仍可能触发 Gatekeeper。首次安装需按系统的“隐私与安全性 → 仍要打开”流程处理。Sparkle 的 Ed25519 更新签名验证的是更新包发布者，不能替代 Apple 代码签名或公证。[Sparkle 文档](https://sparkle-project.org/documentation/)

已有的无 Sparkle 版本无法仅靠上传 `appcast.xml` 获得自更新能力。用户必须手动安装一个已内置 Sparkle、公钥和 feed 地址的引导版本，之后才能接收后续更新。

## 2. 已落地内容

| 位置 | 实现 |
| --- | --- |
| `Layby.xcodeproj` | 通过 Swift Package Manager 在项目中固定依赖 `Sparkle` `2.9.2`，应用 target 链接该 framework |
| `Layby/Updates/UpdateService.swift` | 持有 `SPUStandardUpdaterController`，启动自动检查并提供手动检查动作 |
| `Layby/App/AppCoordinator.swift` | 应用启动时创建更新服务；菜单增加“检查更新…” |
| `Config/Info.plist` | 配置 stable feed、公钥、签名 feed、安装服务和更新前校验 |
| `Config/Layby.entitlements` | 增加网络客户端权限及 Sparkle sandbox 安装服务的 Mach lookup 名称 |
| `scripts/build-local.sh` | 改为通过 Xcode 构建，确保嵌入 Sparkle framework 与 XPC 服务 |
| `scripts/package-and-release.sh` | 打包后生成并签名 `appcast.xml`，再随 GitHub Release 上传 |

当前写入产物的关键配置为：

```text
SUFeedURL=https://github.com/gonnabeafreeman/Layby/releases/latest/download/appcast.xml
SUEnableAutomaticChecks=true
SUAutomaticallyUpdate=false
SURequireSignedFeed=true
SUVerifyUpdateBeforeExtraction=true
SUEnableInstallerLauncherService=true
```

`SUPublicEDKey` 已写入应用。对应私钥仅保存在本机登录钥匙串，未写入仓库或脚本；发布机器需要保留该钥匙串条目或通过 Sparkle 支持的安全方式提供同一私钥。

## 3. GitHub Release 约定

每个 stable Release 上传：

```text
Layby.zip               Sparkle 更新包，顶层为 Layby.app
Layby.dmg               首次安装和手动恢复用
appcast.xml            固定文件名，供 latest/download 读取
SHA256SUMS             人工检查用，不是更新信任根
```

应用只读取 Latest Release 的 `appcast.xml`。清单中 enclosure 的 URL 固定到该版本 tag，例如：

```text
https://github.com/gonnabeafreeman/Layby/releases/download/v1.1.0/Layby.zip
```

当前脚本为 stable 单通道生成**仅含本次版本**的 appcast。这足以让所有较低、兼容的已安装版本升级到 Latest；若未来要为不同最低 macOS 版本、预发布通道或分阶段发布保留多个 item，应改为维护一个可访问的历史归档目录后再生成 feed，不能手工拼接已签名 XML。

完整发布要求见 [GitHub Release 发布要求](./github-release-publishing.md)。

## 4. 发布前的版本规则

| 字段 | 要求 |
| --- | --- |
| Git tag | `vX.Y.Z`，并指向本次构建 commit |
| `CFBundleShortVersionString` | 与 tag 去掉 `v` 后完全一致 |
| `CFBundleVersion` | 正整数且每个公开更新严格递增 |
| Bundle ID / Ed25519 公钥 | 后续版本保持不变 |
| 更新包 | 最终签名后再归档；签名、压缩或资源有变化都要重新生成 appcast |

脚本会检查 tag、app 内置展示版本、build 和 `HEAD` 的关系。它不会修改 Xcode 版本：报“应用版本和 tag 不一致”时，指的是 `dist/<tag>/Layby.app/Contents/Info.plist` 中的 `CFBundleShortVersionString`，通常由当前工程的 `MARKETING_VERSION` 构建产生。

## 5. 已完成的本地验证

- Xcode Debug 与 Release 构建均成功，最终 `Info.plist` 含全部 `SU*` 配置，Sparkle framework 包含 `Installer.xpc` 与 `Downloader.xpc`。
- 对真实 Xcode Release 构建的 ZIP 运行 `generate_appcast` 成功，生成 enclosure 的 Ed25519 签名和签名 feed。
- 运行 67 项逻辑测试时，`ShelfDockingTests` 的一个既有坐标断言出现 2–3 px 波动；单独重跑该目标通过。该波动与更新服务无关，但仍应在发布前复跑全量测试。

当前本机对签名包执行 `codesign --verify --deep --strict` 返回 `CSSMERR_TP_NOT_TRUSTED`，而 Xcode 的签名构建本身成功。这需要在发布机器上针对最终附件确认其 Apple 证书信任链；不要把该结果视为 Release 放行。

## 6. 首次实际发布和验收

当前 GitHub 已存在 `v1.0.1`，不要覆盖它。发布第一个带 Sparkle 的引导版本时，应使用新的、更高版本，例如将 Xcode 的展示版本改为 `1.0.2`、build 改为大于 `2`，创建 `v1.0.2` tag 后发布。

随后再发布一个更高版本，在已安装引导版本的机器上验证：检查更新、下载、Ed25519 校验、用户确认、退出、替换和重启。还要验证离线、附件缺失、篡改 ZIP、无写权限和从 DMG 运行等失败路径；失败时旧版本必须仍可启动。

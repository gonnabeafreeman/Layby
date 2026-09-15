# GitHub Release 更新发布要求

日期：2026-09-15。状态：**发布脚本已实现**，与 [不经 Apple 公证的自更新方案](./github-release-updates.md) 配套。以下以公开仓库 `gonnabeafreeman/Layby` 为准。

## 1. 每次 Release 必须包含什么

| 附件 | 要求 |
| --- | --- |
| `Layby.zip` | 必须；顶层为 `Layby.app`，完整更新包，保留符号链接及执行权限 |
| `appcast.xml` | 必须；固定文件名，每个 stable Release 都上传；包含版本、兼容性、下载地址、大小与签名 |
| `Layby.dmg` | 建议；供用户首次安装和手动恢复 |
| `SHA256SUMS` | 建议；方便人工或 CI 检查附件一致性，不能替代更新签名 |
| 更新说明 | Release 正文必须有；appcast 可内嵌纯文本说明，避免额外维护 HTML 附件 |

若使用独立 release-notes 文件，必须一起上传，并满足所选 Sparkle 签名 feed 的验证要求。GitHub 自动生成的 Source code ZIP / tar.gz 是源码，不能用作应用更新包。

`package.sh` 生成固定名的 `Layby.zip` 和 `Layby.dmg`；`package-and-release.sh` 保留这两个文件名，再生成 appcast。`scripts/build-local.sh` 通过 Xcode 构建，适合作为开发机的完整依赖嵌入验证；发布构建仍须确认实际产物包含目标架构。未来若拆分架构，需另行增加选择逻辑和兼容测试，不能只改文件名。

## 2. 版本及身份规则

以某个后续版本为例（仅示例）：

| 字段 | 示例 | 规则 |
| --- | --- | --- |
| Git tag | `v1.1.0` | 必须对应实际构建 commit |
| `CFBundleShortVersionString` | `1.1.0` | 与 tag 去掉 `v` 后一致 |
| `CFBundleVersion` | `2` | 每次公开更新严格递增；重发修复包也用更大 build |
| appcast `sparkle:version` | `2` | 与包内 build 一致 |
| appcast `sparkle:shortVersionString` | `1.1.0` | 与包内展示版本一致 |
| Bundle ID | `com.gonnabeafreeman.Layby` | 保持稳定 |
| 应用包名 | `Layby.app` | 保持稳定 |
| 最低系统版本 | `15.6` | appcast 与构建产物一致；提高门槛要保留旧系统兼容项 |

更新判断以 build 为准，不以 Release 标题、发布时间或简单字符串排序为准。每次构建先注入版本，再签名；禁止签名完成后修改 plist。

`package.sh v1.1.0` 只决定目录和文件名，**不会**把应用内置版本改成 1.1.0。`package-and-release.sh` 已在发布前严格校验，不一致立即停止。

## 3. 清单结构及下载规则

下面展示一个 item 的必要信息，**这是未签名模板，不能直接上传生产使用**；签名和字节数必须从最终 ZIP 生成。

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Layby Updates</title>
    <link>https://github.com/gonnabeafreeman/Layby</link>
    <description>Layby stable updates</description>
    <item>
      <title>Layby 1.1.0</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
      <description>此处为本次变更说明</description>
      <enclosure
        url="https://github.com/gonnabeafreeman/Layby/releases/download/v1.1.0/Layby.zip"
        length="REPLACE_WITH_ACTUAL_BYTES"
        type="application/octet-stream"
        sparkle:edSignature="REPLACE_WITH_GENERATED_SIGNATURE" />
    </item>
  </channel>
</rss>
```

使用锁定版本 Sparkle 附带的 `generate_appcast` 生成正式清单；它负责签署归档，并在配置了签名 feed 时生成相应签名。可用 `sign_update` 核对单个包签名。不要自行发明签名 feed XML 格式。[Sparkle 发布文档](https://sparkle-project.org/documentation/publishing/)

签名清单生成前应确定固定 tag 下载 URL 和说明。当前脚本以单一 stable item 生成清单；若后续维护历史 item，需将对应历史归档一起提供给 `generate_appcast` 后重新签名。清单签好后不能再用文本替换 URL；需要变更时重新生成签名。不要把不同 tag 的历史附件统一改成最新 tag 路径。首期只发布全量 ZIP，关闭差分生成，或确保生成的差分条目不会进入清单。

客户端下载 feed 使用：

```text
https://github.com/gonnabeafreeman/Layby/releases/latest/download/appcast.xml
```

清单里的包 URL 始终固定到具体 tag。每个新 Release 都上传自己的清单快照，无须覆盖旧 Release 的附件。

## 4. 签名与密钥要求

1. 项目初始化时生成一次 Ed25519 密钥，将公钥写入引导版本及后续版本；私钥放在本机 Keychain 或受保护发布环境中，并做安全备份。
2. CI 只允许受信任发布流程读取私钥；不得在 fork PR、构建日志、仓库文件或发布附件中暴露私钥。
3. 应用签名、打包完成后，再对最终 ZIP 做更新签名。重新打包、改资源或重新签署 app 都会改变 ZIP，需要重新生成更新签名及长度。
4. ad-hoc 模式下 Ed25519 是核心发布者信任根。不要每版换密钥；丢失私钥时应准备手动安装新的引导版本，不能假设 Developer ID 的密钥轮换路径适用于本模式。
5. SHA-256 检查只证明文件与摘要一致；攻击者若能同时替换二者，仍可伪造，不能代替公钥验证。

## 5. 推荐发布流水线

仓库提供 `scripts/package-and-release.sh` 处理第 4、5、6、8 步中的归档、appcast 生成签名、草稿/稳定 Release 创建和附件上传；它不构建 app。

```sh
# 先准备 dist/v1.1.0/Layby.app 和 dist/v1.1.0/release-desc.md
bash scripts/package-and-release.sh --dry-run v1.1.0
bash scripts/package-and-release.sh --draft v1.1.0
bash scripts/package-and-release.sh v1.1.0
```

脚本要求本地 HEAD 正是已推送的同名 tag，并通过 `gh release create --verify-tag` 再次要求 GitHub 已有该 tag。稳定 Release 会标记为 Latest；`--draft` 和 `--prerelease` 不会。它通过临时符号链接将唯一的 `release-desc.md` 同时用于 appcast 内嵌说明，再由 `generate_appcast` 从登录钥匙串读取私钥，生成并签名 `appcast.xml`。脚本上传 `Layby.zip`、`Layby.dmg`、`SHA256SUMS` 和 `appcast.xml`；`release-desc.md` 只用作 Release 正文和 appcast 说明，不会作为附件上传。

1. **锁定输入**：干净的发布 commit、tag、展示版本、递增 build、Sparkle 锁定版本、签名配置及架构。
2. **构建和嵌入**：通过 Xcode 工程生成 Release app，嵌入 Sparkle 和安装 helper，注入最终 plist 与权限。
3. **代码签名验证**：逐层正确签名，再检查 app 与内部工具。ad-hoc 模式需要通过专项兼容实验；Developer ID 模式也不执行公证步骤。
4. **归档**：将 app 放入 `dist/vX.Y.Z/`，运行现有 `package.sh` 的 DMG/ZIP 流程。扩展脚本校验版本、架构、签名及必要配置。
5. **更新签名**：对最终 ZIP 生成 appcast，校验 URL、length、build、最低系统版本及公钥匹配。可生成 SHA256SUMS。
6. **创建 Draft**：先上传 ZIP、DMG、完整 `appcast.xml` 等全部附件，校验附件大小和摘要；此时匿名用户无法读取 draft，不能拿它做正式客户端 feed 测试。
7. **预发布验证**：在独立测试 feed / 可公开访问的测试 Release 中完成 N → N+1，使用与生产相同的最终包。测试条目不得成为生产 Latest。
8. **发布稳定版**：附件齐全后发布 stable Release，并明确将其标为 Latest。避免先切 Latest 再补附件造成更新中断。
9. **发布后检查**：匿名访问 latest appcast 及固定 tag ZIP，检查 HTTPS 重定向、内容和签名；用上一正式版本验证真实升级。

建议启用 GitHub immutable releases：先 Draft 上传全部附件，再 Publish，避免发布后替换 tag 或更新包。该功能仍允许调整 Latest 标记和说明，但附件受保护。[GitHub 不可变 Release 文档](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

## 6. 放行检查表

- [ ] 实际 Release 仓库与应用 URL、README、appcast 一致，匿名可读。
- [ ] tag、展示版本、build、最低系统版本和归档内容一致。
- [ ] Universal 包及内部依赖支持 arm64 / x86_64；未误传源码压缩包。
- [ ] 最终 plist 包含正确公钥、feed 和更新器设置；entitlement 展开正确。
- [ ] app、framework、XPC 和 helper 签名验证通过，无本地样本出现的异常。
- [ ] 从浏览器下载的产物可按文档完成首次安装；从 N 版本可完成自更新。
- [ ] ZIP 更新签名、feed 签名和字节数匹配；最终签名后未再修改文件。
- [ ] Latest Release 的固定名 `appcast.xml` 返回有效清单，所有 enclosure 可下载。
- [ ] 跨版本、异常、目录权限和临时文件场景按方案文档验收。
- [ ] Release 说明写明变更、系统要求、是否公证和可能需要重新授权。

只读验证命令示例，路径应替换为本次实际产物：

```sh
plutil -p dist/v1.1.0/Layby.app/Contents/Info.plist
lipo -archs dist/v1.1.0/Layby.app/Contents/MacOS/Layby
codesign -dv --verbose=4 dist/v1.1.0/Layby.app
codesign -d --entitlements - dist/v1.1.0/Layby.app
codesign --verify --deep --strict --verbose=2 dist/v1.1.0/Layby.app
shasum -a 256 dist/v1.1.0/Layby.zip
```

代码签名验证通过不等于 Gatekeeper 放行；未公证场景的系统评估拒绝不应被伪装为通过。实际安装/更新验收需独立执行。

## 7. 引导、故障和回退

- 当前旧版本没有更新器，必须手动下载安装一次引导版本，之后才能接收后续更新。仅上传 appcast 无法给旧程序增加能力。
- 有问题的新版本停止作为 Latest，可以暂时切回上一个完整稳定 Release，阻止尚未升级者继续收到该版本。已升级用户不会因此自动降级。
- 为已升级用户发布更高 build 的修复版，必要时基于旧源码重新构建；不要覆盖旧 tag 或已签名附件。
- 保留之前完整发布包供手动恢复。更新器安装失败后的恢复行为必须实测，不宣称有未经验证的自动回滚能力。
- 发布账户受损时，独立私钥可阻止伪造更新包，但不能保证服务可用性；若私钥也泄露，应停止分发并设计新的可信引导流程。

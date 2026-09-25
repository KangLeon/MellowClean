# MellowClean

**给 Mac 留点余地。** 一个轻量、透明的 macOS 清理工具，带原生 SwiftUI 窗口和命令行。

扫描 → 看懂每一项 → 自己选择 → 清理。没有后台常驻、账号、广告、遥测或第三方依赖。

## 安装

macOS 13+，Apple Silicon 或 Intel。需要 Xcode Command Line Tools（`xcode-select --install`）。Homebrew 从源码构建，无需下载未经公证的预编译应用。

```sh
brew install KangLeon/tap/mellowclean
mellowclean
```

也可以从源码运行：

```sh
git clone https://github.com/KangLeon/MellowClean.git
cd MellowClean
bash scripts/build.sh
open dist/MellowClean.app
```

界面目前为简体中文；CLI 提供英文命令帮助与中文分类说明。MIT 开源。

## 可以做什么

- **缓存清理**：Homebrew 安装包、Xcode DerivedData、Go 编译、npm/pip 下载、Chrome/Firefox 网页缓存、旧崩溃报告。
- **先解释再选择**：每类展示用途、影响、大小、具体项目，支持在 Finder 查看。
- **保留近期内容**：默认保留最近 7 天更新的项目，界面可选 1 / 7 / 30 天；切换后重新扫描生效。
- **两种清理方式**：默认移至废纸篓；可明确选择永久删除并二次确认。
- **大文件定位**：查找下载、桌面、文稿、影片中大于 100 MB 的文件，最多显示最大的 100 项。个人文件只提供 Finder 定位。

> 移至废纸篓不会立刻释放磁盘空间。先检查废纸篓，再由 Finder 清倒；需要恢复时将项目拖回扫描时显示的原位置。永久删除不可撤销。显示的缓存大小是已分配空间估算，APFS 克隆、压缩和快照可能使实际释放量不同。

## 命令行

```sh
mellowclean scan                       # 只读扫描
mellowclean scan --json                # 结构化结果，包含本地路径
mellowclean clean homebrew go          # 预览，输入 TRASH 后移至废纸篓
mellowclean clean homebrew --permanent # 预览，输入 DELETE 后永久删除
mellowclean clean homebrew --yes       # 显式跳过确认，仍默认移至废纸篓
```

分类 ID：`homebrew`、`xcode`、`go`、`npm`、`pip`、`chrome`、`firefox`、`diagnostics`。
CLI 固定保留 7 天。无参数启动窗口。不会接受任意待删除路径。

## 清理边界

只清理当前用户下写在代码里的缓存路径，不请求 sudo，不清理系统目录、照片、聊天记录、密码、浏览器用户资料、Xcode Archives、模拟器、开发运行环境或项目依赖。

每个候选项目都必须完整检查。符号链接、硬链接、近期变化、权限不足或过大而无法完整检查的目录会跳过；检测到相关工具在运行时也会跳过。执行前再次检查运行进程和文件元数据，扫描后变化的内容不会删除。清理失败逐项报告，不把失败计入成功数量。

进程检测使用工具名，无法识别所有改名进程、外部脚本或后台写入者；扫描与清理之间仍存在文件系统竞争窗口。请先退出相关应用，勿在构建或安装过程中清理。它不是针对同一账号下恶意进程的安全隔离工具。

大文件扫描不读取文件内容，跳过隐藏文件、应用包及常见依赖目录。每个个人目录最多扫描 20 秒或 20 万个条目；达到限制或没有访问权限会提示结果不完整。不会自动申请完全磁盘访问权限。

## 开发与验证

```sh
swift test
bash scripts/build.sh
dist/bin/mellowclean --version
codesign --verify --deep --strict dist/MellowClean.app
```

测试使用临时目录，覆盖允许路径、近期文件、运行中应用、符号链接、硬链接、扫描后变化、伪造候选和重复候选。CI 在 macOS 上测试并构建。安装脚本只做本机构建和 ad-hoc 签名，不代表 Apple Developer ID 签名或公证。

Homebrew 配方在 [KangLeon/homebrew-tap](https://github.com/KangLeon/homebrew-tap)，使用版本归档和 SHA-256 校验。发布新版本时，更新 `Info.plist`、CLI 版本、标签和配方校验值。

## English

MellowClean is a small, local-first Mac cleaner with a native Chinese-language UI and a CLI. It reviews an explicit cache allowlist, protects recent content, skips known running tools and defaults to Trash. Large personal files are discoverable but never automatically deleted. No telemetry, privileged helper or external dependencies. Requires macOS 13+ and Swift 5.9+ build tools. See the commands above for installation and testing.

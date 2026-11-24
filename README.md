# Head3DCapture

极简 iOS 数据采集 App（SwiftUI + AVFoundation + Metal），用前置 **TrueDepth** 相机采集：
`rgb.jpg`（前置 RGB）、`depth.tiff`（32-bit float，单位米，`Float32`/`CV_32FC1` 兼容）、`intrinsics.json`（深度/RGB 内参、外参、分辨率等）。下半屏是 Metal 实时点云（可彩色 / 伪彩，绕质心旋转）。

> 详细开发与 CI 约定见 [`AGENT.md`](AGENT.md)。

---

## 1. 构建与下载 IPA

```bash
git push origin master                 # 触发 GitHub Actions（Build Unsigned iOS IPA，macos-15）
node scripts/fetch-ipa.mjs             # 等待最新一次 run 并下载到 ./artifacts/Head3DCapture.ipa
node scripts/fetch-ipa.mjs --dispatch  # 或强制重跑一次
```

产物是**未签名**的 arm64 真机包，需用 Sideloadly / AltStore 等自签后安装。

---

## 2. 数据保存位置（含「文件」App 看不到的问题）

**存放位置**：App 沙盒 `Documents/Head3D/<时间戳>/`，每次采集一个子目录，内含
`rgb.jpg`、`depth.tiff`、`intrinsics.json`（都做过写盘回读校验，大小会显示在状态栏）。

**「文件」App 里的等价路径**：`我的 iPhone › Head3D采集 › Head3D › <时间戳>`
（由 `UIFileSharingEnabled` + `LSSupportsOpeningInPlace` + `UISupportsDocumentBrowser` 暴露，App 名取自 `CFBundleDisplayName`）。

### ⚠️ iOS 18 已知回归
即使上述 Info.plist 键都为 `true`，部分设备的「文件」App **不显示** App 的 Documents（目录空白），
但数据其实已经写好 —— 可在 **设置 › 通用 › iPhone 储存空间 › Head3D采集 › 文稿** 中看到。

本项目的四层应对（从轻到重）：

| 手段 | 位置 | 说明 |
|---|---|---|
| `UISupportsDocumentBrowser = true` | `Info.plist` | 把容器声明为文档库，绕过被忽略的旧 flag |
| **ⓘ 存储诊断** | 采集页控制行 | 显示运行时 plist 标志、沙盒绝对路径、最近写入文件的大小、`Documents` 全量扫描，可一键复制 |
| **同步目录**（推荐） | 诊断页 | 选一次普通文件夹（iCloud Drive / 我的 iPhone 任意位置），保存安全作用域书签，**之后每次采集自动复制过去**；与系统 bug 无关，100% 可见 |
| **导出** | 采集页控制行 | 用 `UIDocumentPickerViewController(forExporting:)` 把最近一次采集拷到任意位置 |

保存成功时状态栏显示 `已保存 · 640×480 · 3.42 MB`；若回读发现文件缺失/为空则显示 `保存校验失败`，不会假装成功。

---

## 3. 点云显示

- 稠密度（抽样步长 1–8）、距离带（近端/远端）可在**屏幕下方滑杆**实时调节，点云左上角显示当前点数 / 上限 / 深度图分辨率。
- 显示做了 **顺时针 90° 旋转** 与 **左右镜像**，与上方镜像的 RGB 预览方向一致；旋转支点是**点云质心**，转起来更跟手。
- 保存的文件**不做**任何旋转/镜像，保持传感器原始朝向（数据契约见 `AGENT.md`）。

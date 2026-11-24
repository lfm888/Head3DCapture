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

## 2. 数据保存位置

App 沙盒 `Documents/Head3D/<时间戳>/`，每次采集一个子目录，内含 `rgb.jpg`、`depth.tiff`、`intrinsics.json`。
「文件」App 中的等价路径：`我的 iPhone › Head3D采集 › Head3D › <时间戳>`。

保存后会**回读校验**文件大小，状态栏显示 `已保存 · 640×480 · 3.42 MB`；若文件缺失/为空则显示 `保存校验失败`。

**距离带会写进 `depth.tiff`**：屏幕上「近端/远端」滑杆设定范围之外的像素写成 `NaN`（范围内保留原始米值），所以保存的深度数据与下方点云完全一致；`intrinsics.json` 里同时记录 `depth_min_m` / `depth_max_m` / `depth_band_applied` / `depth_invalid_value`。

> 找不到文件、或「文件」App 里目录是空的 → 见 [FAQ Q2](#q2-保存成功但文件app-里目录是空的)。

---

## 3. 点云显示

- 稠密度（抽样步长 1–8）、距离带（近端/远端）可在**屏幕下方滑杆**实时调节，点云左上角显示当前点数 / 上限 / 深度图分辨率。
- 显示做了 **顺时针 90° 旋转** 与 **左右镜像**，与上方镜像的 RGB 预览方向一致；旋转支点是**点云质心**，转起来更跟手。
- 保存的文件**不做**任何旋转/镜像，保持传感器原始朝向（数据契约见 `AGENT.md`）。

---

## FAQ

### Q1: RGB 相机与深度之间没有标定外参，为什么彩色点云能直接映射上色？

因为**不需要**外参——系统已经把深度图配准到 RGB 相机了。

1. `AVDepthData` 不是 IR 传感器的原始深度，而是 iOS 输出前就已 **register 到前置 RGB（reference camera）** 的深度图。所以同一个像素坐标 `(u, v)` 在深度图和 RGB 图里指的是**同一条视线**。
2. `cameraCalibrationData.intrinsicMatrix` 是按 `intrinsicMatrixReferenceDimensions`（即 RGB 参考分辨率，如 1920×1440）标定的，缩放后就是深度图分辨率下的内参（我们存为 `fx/fy/cx/cy`）。
3. `cameraCalibrationData.extrinsicMatrix`（深度相机 → RGB）实测为**单位阵**——这正好印证了上面“已配准、共用同一坐标系”的结论。iOS 不公开两颗物理传感器之间的独立标定。
4. 因此上色只需**按比例归一化取样**，不做任何重投影：

   ```
   scale = rgbWidth / depthWidth          // 同一水平视场
   ru    = u * scale
   rv    = (v - depthHeight/2) * scale + rgbHeight/2   // 垂直居中（RGB 常是 16:9 裁切）
   color = RGB_Frame[rv, ru]
   ```
   代码：`TrueDepthCaptureManager.makePointCloud(...)` 里 `colorScale` 那一段，RGB 帧来自 `AVCaptureVideoDataOutput`（`32BGRA`，与深度同朝向、不旋转）。

   如果将来拿到非单位外参（`intrinsics.json` 里的 `extrinsic_depth_to_rgb_3x4`），正确做法是 `p_ref = R·p + t` 再用 RGB 的 `K` 投影，然后按上面同样的比例取色。

---

### Q2: 保存成功，但「文件」App 里目录是空的？

这是 **iOS 18 的已知回归**：即使 `UIFileSharingEnabled` / `LSSupportsOpeningInPlace` 都是 `true`，「文件」App 也可能不列出 App 的 Documents（数据实际已写入，可在 **设置 › 通用 › iPhone 储存空间 › Head3D采集 › 文稿** 中看到）。

本项目的四层应对（从轻到重）：

| 手段 | 位置 | 说明 |
|---|---|---|
| `UISupportsDocumentBrowser = true` | `Info.plist` | 把容器声明为文档库，绕过被忽略的旧 flag |
| **ⓘ 存储诊断** | 采集页控制行 | 显示运行时 plist 标志、沙盒绝对路径、最近写入文件大小、`Documents` 全量扫描，可一键复制 |
| **同步目录**（推荐） | 诊断页 | 选一次普通文件夹（iCloud Drive / 我的 iPhone 任意位置），保存安全作用域书签，**之后每次采集自动复制过去**；与系统 bug 无关，100% 可见 |
| **导出** | 采集页控制行 | `UIDocumentPickerViewController(forExporting:)` 把最近一次采集拷到任意位置 |

---

### Q3: 点云点数只有一两万，不是说要几十万吗？

上限 = `深度图宽 × 高 ÷ 步长²`，实际再被距离带和无效像素（NaN）削减。三处可调/可查：

- 点云左上角显示 `深度图 640×480 · 上限 307,200 点 · 步长 1`，一眼看出瓶颈在哪。
- **步长**滑杆（1–8）：1 = 逐像素（30 万上限），3 = 1/9。
- **近端/远端**滑杆：把人脸之外的背景裁掉。
- 若显示的分辨率是 `160×120` 而不是 `640×480`，说明深度格式选择退化（`configureSession()` 取的是 `supportedDepthDataFormats` 里**像素数最大**的 Float32 档位，该列表是从小到大排列的）。

注：投射的 ~3 万个 IR 散斑是**投影图案数量**，不是深度图分辨率；系统会插值出一整幅致密深度图。

---

### Q4: 点云朝向/镜像/旋转手感不对，改哪里？

| 现象 | 改动 |
|---|---|
| 上下或前后颠倒 | `PointCloudSettings.rotationDegrees`（默认 `90`，试 `-90`） |
| 左右与预览不一致 | `PointCloudSettings.mirrorHorizontally`（默认 `true`，试 `false`） |
| 旋转时画面“漂”而不是绕人转 | 检查渲染器是否仍用 `T(-centroid)` 作支点（`PointCloudRenderer.draw`） |
| 点云太大/太小 | `PointCloudRenderer.distance` 默认值（现为 `0.65`） |

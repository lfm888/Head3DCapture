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

> 找不到文件、或「文件」App 里目录是空的 → 见 [FAQ Q2](#q2-保存成功但文件app-里目录是空的)。

---

## 3. 点云显示

- 稠密度（抽样步长 1–8）、距离带（近端/远端）可在**屏幕下方滑杆**实时调节，点云左上角显示当前点数 / 上限 / 深度图分辨率。
- 显示做了 **顺时针 90° 旋转** 与 **左右镜像**，与上方镜像的 RGB 预览方向一致；旋转支点是**点云质心**，转起来更跟手。
- 保存的文件**不做**任何旋转/镜像，保持传感器原始朝向（数据契约见 `AGENT.md`）。

---

## 4. 数据集格式（下游项目必读）

### 目录结构
```
Documents/Head3D/<时间戳>/
├── rgb.jpg          前置 RGB（全分辨率）
├── depth.tiff       深度（米，float32，无效=NaN）
└── intrinsics.json  内参/外参/尺寸元数据
```

### `depth.tiff`

| 属性 | 值 |
|---|---|
| 尺寸 | 深度图原尺寸（Face ID 机型通常 **640×480**，传感器横向朝向） |
| 类型 | 单通道 IEEE float32（OpenCV `CV_32FC1`），单位 **米** |
| 编码 | TIFF `CIFormat.Lf` + `linearGray`，无压缩 |
| 有效值 | `np.isfinite(d) & (d > 0)`；其余为 `NaN`（传感器空洞） |
| **是否按 UI 距离带裁剪** | **否**。`depth.tiff` 永远是**全量有效深度** |
| **可视化-only 参数（不写进数据）** | 「近端/远端」距离带、抽样步长、顺时针 90° 旋转、左右镜像 |

> 也就是说：屏幕上的点云是「按距离带+步长抽样+旋转+镜像」后的**视图**；磁盘上的 `depth.tiff` 始终是原始的、未裁剪、未旋转的米制深度图。需要裁剪就在下游自己做（见 FAQ Q5）。

### `rgb.jpg`
- `AVCapturePhotoOutput` 全分辨率 JPEG（如 3024×4032），**可能带 EXIF Orientation**。读取时用 `PIL.ImageOps.exif_transpose(img)` 或 OpenCV `IMREAD_IGNORE_ORIENTATION`，否则与深度方向不一致。
- 深度已由系统配准到这台 RGB 相机的视线（见 FAQ Q1），所以同一像素 `(u,v)` 归一化后一一对应；但两者**分辨率/长宽比不同**，换算按宽度比 + 垂直居中。
- 若要把 RGB 叠加到深度分辨率：`scale = rgbW/depthW`，`rv = (v - depthH/2)*scale + rgbH/2`。

### `intrinsics.json` 字段

| key | 含义 |
|---|---|
| `depth_width` / `depth_height` | 深度图尺寸（与 `depth.tiff` 一致） |
| `depth_accuracy` / `depth_quality` | 深度精度（absolute/relative）/质量 |
| `fx` `fy` `cx` `cy` | **已缩放到深度图分辨率**的深度内参 |
| `reference_width` / `reference_height` | `K` 的原始标定分辨率（RGB 参考尺寸）；需要原始量级时 `fx * refW / depthW` 反推 |
| `pixel_size_mm` | 传感器像素尺寸 |
| `extrinsic_depth_to_rgb_3x4` | 深度→RGB 的 `[R\|t]`（行主序），TrueDepth 下为**单位阵** |
| `rgb_width` / `rgb_height` | `rgb.jpg` 实际像素尺寸 |
| `rgb_fx` `rgb_fy` `rgb_cx` `rgb_cy` `rgb_intrinsics_3x3` | 前置 RGB 相机内参（来自视频帧 attachment，单位为 `color_sampling_width×height` 的像素） |
| `color_sampling_width` / `color_sampling_height` | 彩色上色时采样的实时 RGB 流分辨率（≠ `rgb.jpg`） |
| `point_cloud_rotation_deg` | **仅**可视化用的旋转角（数据未旋转） |
| `saved_folder` | 相对 `Documents` 的目录名，如 `Head3D/20261124_190814_455` |

> 字段策略：只**追加**、不改名、不删；下游按 key 读取、忽略未知 key。

### 反投影（Python / OpenCV 示例）

```python
import json, numpy as np, cv2

d = cv2.imread("depth.tiff", cv2.IMREAD_UNCHANGED).astype(np.float32)   # HxW, 米
meta = json.load(open("intrinsics.json"))
fx, fy, cx, cy = meta["fx"], meta["fy"], meta["cx"], meta["cy"]

valid = np.isfinite(d) & (d > 0)
v, u = np.nonzero(valid)                 # 图像坐标（u 右, v 下）
z = d[v, u]
x = (u - cx) * z / fx
y = (v - cy) * z / fy                    # 图像坐标 v 向下；想“y 向上”取 -y

# 若需要按 UI 那样的距离带，自己裁：
near, far = 0.25, 0.90
d[(d < near) | (d > far)] = np.nan
```

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

---

### Q5: `depth.tiff` 里有大量 `NaN` / 有效像素很少，是被距离带裁掉了吗？

**不是。** 设备端**从不对** `depth.tiff` 做距离带裁剪（见 §4「数据集格式」），滑杆只影响屏幕上的点云。

`NaN` 全部来自深度本身：TrueDepth 在贴得太近（≲0.2 m）、太远（≳1.5 m 明显变差）、反光/纯黑吸光面、无纹理区域都会输出无效值。先量一下：

```python
import cv2, numpy as np
d = cv2.imread("depth.tiff", cv2.IMREAD_UNCHANGED)
print(d.dtype, d.shape, "NaN占比", np.isnan(d).mean())
print("有效值域", np.nanmin(d), np.nanmax(d))
```

- `NaN` 占比很高但 `nanmin/nanmax` 是合理的米制数值 → 拍的时候太近/太远或表面不配合，重拍即可。
- 如果你**希望**下游拿到的就是裁剪过的数据，请在自己的预处理里做（别指望设备端）：
  ```python
  d[(d < near) | (d > far)] = np.nan
  ```
- 屏幕上显示的点数 = `有效像素 ÷ 步长²`，所以「步长 3 + 距离带较窄」时点数自然只有几千，与 `depth.tiff` 的完整度无关。

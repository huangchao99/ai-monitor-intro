# AI 智能视频监控系统 — 总体介绍

> 本文档面向后来参与此项目的开发者或 AI 助手，阅读本文可快速了解整个系统的架构、各组件的位置、功能及关键要点。

---

## 一、系统概述

这是一套基于 Rockchip RK3576 工控机（ARM64，Linux 6.1.99）的**工业级智能视频监控系统**，具备：

- 多路 RTSP 摄像头接入与视频分发
- 基于 NPU 硬件加速的 AI 行为检测（离岗、吃香蕉、闭眼、打哈欠、PPE 合规、打电话/玩手机/抽烟等）
- 插件化算法引擎，支持零代码新增行为检测，支持插件上传/删除
- Web 管理界面（控制台、摄像头、任务、告警、算法模型、语音报警、报警上传）
- 报警抓图存档与处理跟踪
- **语音报警**：报警触发时通过摄像头喇叭播放对应语音（Java TTS）
- **报警上传**：定时将新报警图片上传到指定服务器，断网续传

---

## 二、整体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        用户浏览器                                        │
│                    Vue3 前端 (localhost:5173)                            │
└──────────────────┬──────────────────────────────────┬───────────────────┘
                   │ REST API                          │ HTTP-FLV 直播流
                   ▼                                   ▼
┌──────────────────────────────┐    ┌──────────────────────────────────────┐
│  Go 后端 (localhost:8090)    │    │  ZLMediaKit 视频路由器 (localhost:80) │
│  - 摄像头/任务/告警 CRUD      │    │  - 统一拉取 RTSP 视频流               │
│  - ZLM 流管理                │───▶│  - 转发为 HTTP-FLV / HLS / RTSP      │
│  - 转发任务控制到 Python      │    │  - ZMQ 不经过 ZLM（推理走独立通道）   │
└──────────────────────────────┘    └──────────────────────────────────────┘
                   │                                   │
                   │ HTTP                              │ RTSP 拉流
                   ▼                                   ▼
┌──────────────────────────────┐    ┌──────────────────────────────────────┐
│ Python 算法调度服务           │    │         摄像头 RTSP 源               │
│ (localhost:9500)              │    │  rtsp://admin:xxx@192.168.x.x/...   │
│ - 插件化行为判断引擎           │    └──────────────────────────────────────┘
│ - 管理任务/插件/状态机         │                    │
│ - ZMQ 订阅推理结果             │                    │ RTSP（直接拉流推理）
│ - 写告警记录 + 抓图            │    ┌───────────────▼──────────────────────┐
└─────────────────┬────────────┘    │   C++ Infer Server (localhost:8080)  │
                  │ HTTP            │   - RTSP 解码（FFmpeg-RK 硬件加速）   │
                  │                 │   - RKNN NPU 推理（yolo11n）          │
                  └────────────────▶│   - ZeroMQ 发布推理结果 (:5555)       │
                    REST + ZMQ SUB  └──────────────────────────────────────┘
                                                    │
                                    ┌───────────────▼──────────────────────┐
                                    │       aimonitor.db (SQLite)          │
                                    │   共享数据库，各组件读写              │
                                    └──────────────────────────────────────┘
```

**关键数据流：**
1. 用户在前端添加摄像头 → Go 后端调 ZLM `addStreamProxy` → ZLM 拉 RTSP 并对外提供 HTTP-FLV
2. 用户启动任务 → Go 后端调 Python `/api/task/start` → Python 调 C++ infer server 注册流 → C++ 独立拉 RTSP 做推理
3. C++ 推理结果通过 ZeroMQ PUB 发布 → Python ZMQ SUB 接收 → 行为插件判断 → 写 alarms 表 + 存快照图
4. 报警触发后：若配置了语音映射 → Python 调用 `voice_alarm` 调度器播放音频；新报警自动入队 `alarm_upload_queue`
5. Go 后台上传 Worker 定时检查队列 → 将未上传报警（含图片）POST 到配置的 URL → 断网续传
6. 前端轮询 Go 后端 `/api/alarms` 显示告警记录

---

## 三、各组件详细说明

### 3.1 ZLMediaKit 视频路由器

| 项目 | 详情 |
|------|------|
| **位置** | `/home/hzhy/ZLMediaKit/` |
| **二进制** | `/home/hzhy/ZLMediaKit/release/linux/Debug/MediaServer` |
| **配置文件** | `/home/hzhy/ZLMediaKit/release/linux/Debug/config.ini` |
| **HTTP API** | `http://localhost:80/index/api/...` |
| **API 密钥** | `vEq3Z2BobQevk5dRs1zZ6DahIt5U9urT` |
| **ZMQ 推送** | `tcp://0.0.0.0:5555`（推理结果，由 C++ infer server 推送） |

**功能：** ZLM 是整个视频流的接入枢纽。通过 `addStreamProxy` API，ZLM 主动拉取摄像头的 RTSP 流，然后对外以多种协议分发：

- HTTP-FLV（前端直播预览）：`http://localhost:80/live/{stream_key}.live.flv`
- HLS：`http://localhost:80/live/{stream_key}/hls.m3u8`
- RTSP 转发：`rtsp://localhost:554/live/{stream_key}`

**已有流：** 系统中已有 cam01~cam04 四路流在推送（来自外部设备推送或内部代理）。

**常用 API：**
```bash
# 查看所有流
curl "http://localhost/index/api/getMediaList?secret=vEq3Z2BobQevk5dRs1zZ6DahIt5U9urT"

# 添加 RTSP 代理流
curl "http://localhost/index/api/addStreamProxy?secret=vEq3Z2BobQevk5dRs1zZ6DahIt5U9urT&vhost=__defaultVhost__&app=live&stream=cam1&url=rtsp://..."

# 删除代理流
curl "http://localhost/index/api/delStreamProxy?secret=vEq3Z2BobQevk5dRs1zZ6DahIt5U9urT&key={proxy_key}"
```

---

### 3.2 C++ Infer Server（AI 推理引擎）

| 项目 | 详情 |
|------|------|
| **位置** | `/home/hzhy/infer-server/infer-server/` |
| **二进制** | 在 `build/` 目录下（需编译） |
| **HTTP API** | `http://localhost:8080/api/...` |
| **ZMQ 发布** | `tcp://0.0.0.0:5555`（推理帧结果） |
| **API 文档** | `/home/hzhy/infer-server/infer-server/docs/api_reference.md` |

**功能：** 专为 Rockchip 平台优化的推理服务器，处理流程：RTSP → FFmpeg-RK 硬件解码 → RGA 图像处理 → RKNN NPU 推理（yolo11n）→ ZeroMQ 发布结果

**模型文件：**
- 权重：`/home/hzhy/yolo11n-rk3576.rknn`（YOLO11n，COCO 80 类）
- 标签：`/home/hzhy/yolo11n-labels.txt`
- 关键类别：`person`(0)、`banana`(46)、`cell phone`(67)

**ZMQ 推理结果格式（每帧）：**
```json
{
  "cam_id": "task_1",
  "frame_id": 1523,
  "timestamp_ms": 1707734400000,
  "original_width": 1920,
  "original_height": 1080,
  "results": [{
    "task_name": "yolo_detect",
    "inference_time_ms": 15.6,
    "result_type": "detections",
    "detections": [{
      "class_id": 0,
      "class_name": "person",
      "confidence": 0.89,
      "bbox": { "x1": 100.5, "y1": 200.3, "x2": 350.7, "y2": 650.1 }
    }],
    "faces": [{
      "confidence": 0.95,
      "bbox": { "x1": 100, "y1": 200, "x2": 350, "y2": 650 },
      "ear": 0.28,
      "mar": 0.35,
      "eye_width_ratio": 0.8
    }]
  }]
}
```
`faces` 为可选字段，用于闭眼/打哈欠等需要 EAR/MAR 的插件；`ear`（眼宽比）、`mar`（嘴宽比）、`eye_width_ratio`（侧脸过滤）由人脸模型或后处理输出。

**注意：** 使用 RKNN 推理时建议用 jemalloc 启动，避免与 glibc malloc 冲突：
```bash
LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ./infer_server config/server.json
```

---

### 3.3 Python 算法调度服务

| 项目 | 详情 |
|------|------|
| **位置** | `/home/hzhy/ai-monitor-service/` |
| **启动** | `cd /home/hzhy/ai-monitor-service && python3 main.py` |
| **监听端口** | `0.0.0.0:9500` |
| **API 文档** | `/home/hzhy/ai-monitor-service/README.md` |

**功能：** 行为分析引擎，是系统的智能核心。

**目录结构：**
```
ai-monitor-service/
├── main.py             # FastAPI 入口，lifespan 自动恢复 status=1 任务
├── config.py           # 配置（支持环境变量覆盖）
├── db.py               # aiosqlite 异步数据库访问
├── schemas.py          # 内部数据结构（含 FaceMetric 人脸指标）
├── infer_client.py     # httpx 调用 C++ infer server HTTP API
├── zmq_subscriber.py   # pyzmq 异步 ZMQ 订阅器（单后台 task）
├── task_manager.py    # 任务生命周期 + ZMQ 帧路由到插件
├── alarm_manager.py    # 触发报警 → 抓图 → 写 DB → 触发语音报警
├── voice_alarm.py      # 语音报警调度器（Java TTS，/home/hzhy/Audio）
└── plugins/
    ├── __init__.py     # importlib 动态扫描注册插件
    ├── base.py         # BehaviorPlugin 抽象基类（含 filter_valid_faces 人脸过滤）
    ├── no_person.py    # 离岗检测
    ├── eat_banana.py   # 吃香蕉检测
    ├── eye_close.py    # 闭眼检测（EAR 阈值）
    ├── yawning.py      # 打哈欠检测（MAR 上升沿 + 滑动窗口计数）
    ├── ppe_detect.py   # PPE 合规（未戴安全帽/未戴口罩/未穿救生衣）
    └── behavior_detect.py # 行为违规（打电话/玩手机/抽烟）
```

**REST 接口：**
| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/task/start` | POST | 启动任务（body: `{"task_id": 1}`） |
| `/api/task/stop` | POST | 停止任务 |
| `/api/task/running` | GET | 查询所有运行中任务 |
| `/api/health` | GET | 服务健康状态 |
| `/api/plugins` | GET | 列出插件文件（含 algo_key 解析） |
| `/api/plugins` | POST | 上传插件 .py 文件 |
| `/api/plugins/{filename}` | DELETE | 删除插件（禁止删除 base.py 等受保护文件） |

**插件化设计（最重要的设计亮点）：**

在 `plugins/` 目录下新增一个 `.py` 文件，设置 `algo_key` 类属性对应数据库 `algorithms.algo_key`，实现 `process_frame()` 方法，**无需修改任何其他代码**，新算法即刻生效。

状态机：`NORMAL → TRACKING（持续检测到行为）→ 达到 duration 秒 → 触发报警 → COOLDOWN（alarm_interval 秒）→ NORMAL`

**已实现插件：**
- `no_person`：连续 `duration` 秒区域内无人 → 报警
- `eat_banana`：person + banana bbox 重叠持续 `duration` 秒 → 报警（避免桌上放香蕉误报）
- `eye_close`：EAR < ear_threshold 持续 duration 秒 → 报警（支持 min_face_size、eye_width_ratio_threshold 人脸过滤）
- `yawning`：MAR 上升沿计数，滑动窗口内达到 yawn_count 次 → 报警
- `no_hardhat` / `no_mask` / `no_safety_vest`：PPE 违规检测（需专用模型输出对应类别）
- `call` / `phone` / `smoke`：行为违规检测（需专用模型输出对应类别）

**人脸检测支持：** C++ infer server 若输出 `faces`（含 EAR/MAR/eye_width_ratio），`frame_info.face_metrics` 会传给插件；基类 `filter_valid_faces()` 可过滤侧脸、过小人脸。

**语音报警：** 启动时初始化 `voice_alarm` 调度器；报警触发后 `alarm_manager` 查询 `voice_alarm_algo_map` 获取音频文件名，调用 `scheduler.trigger(audio_file)`，由 Java jar 在 `/home/hzhy/Audio` 目录播放。

**调试模式：** `python main.py --debug-face-metrics` 可周期性打印 ear/mar/eye_width_ratio 便于调参。

---

### 3.4 Go 后端管理服务

| 项目 | 详情 |
|------|------|
| **位置** | `/home/hzhy/ai-monitor-backend/` |
| **启动** | `/home/hzhy/ai-monitor-backend/start.sh` |
| **监听端口** | `0.0.0.0:8090` |
| **Go 路径** | `/home/hzhy/go/bin/go`（需 `export PATH=$PATH:/home/hzhy/go/bin`） |

**功能：** 系统的控制中心，对前端提供完整 REST API，协调各组件。

**目录结构：**
```
ai-monitor-backend/
├── main.go               # Gin 路由 + CORS + DB 初始化 + 后台上传 Worker
├── config/config.go      # 配置（支持环境变量覆盖）
├── model/model.go        # 所有 struct（含 VoiceAlarm、AlarmUpload 等）
├── store/store.go        # SQLite 全量 CRUD（含 voice_alarm_algo_map、alarm_upload_queue 等）
├── zlm/client.go         # ZLM HTTP API 封装
├── pyservice/client.go   # Python 服务 HTTP 客户端
├── uploader/uploader.go  # 报警上传后台 Worker（定时检查、断网续传）
└── api/
    ├── camera.go         # 摄像头 CRUD + ZLM 流控制 + 摄像头截图代理
    ├── task.go           # 任务 CRUD + 启停（转 Python）+ 算法列表
    ├── alarm.go          # 告警分页查询 + 状态更新
    ├── algo_manage.go    # 算法模型管理（模型/算法/插件 CRUD、插件上传）
    ├── voice_alarm.go    # 语音报警配置（开关、设备、算法-语音映射、音频文件）
    └── alarm_upload.go   # 报警上传配置（开关、上传地址、队列、手动触发）
```

**REST API 汇总：**
```
GET/POST   /api/cameras                  # 摄像头列表/创建（创建时自动启动 ZLM 流）
PUT/DELETE /api/cameras/:id              # 更新/删除摄像头
POST       /api/cameras/:id/stream/start # 手动启动 ZLM 代理流
POST       /api/cameras/:id/stream/stop  # 停止 ZLM 代理流
GET        /api/cameras/:id/snapshot     # 获取摄像头当前帧截图（JPEG）
GET        /api/algorithms               # 算法字典（含 param_definition）
GET/POST   /api/tasks                    # 任务列表/创建
DELETE     /api/tasks/:id                # 删除任务
POST       /api/tasks/:id/start          # 启动任务（→ Python）
POST       /api/tasks/:id/stop           # 停止任务（→ Python）
GET        /api/alarms                   # 告警列表（?task_id=&status=&page=&size=）
PUT        /api/alarms/:id               # 更新告警状态
GET        /api/health                   # 健康检查（含 ZLM/Python 连通性）

# 算法模型管理（/api/algo-manage）
GET/POST   /api/algo-manage/models       # 模型 CRUD
PUT/DELETE /api/algo-manage/models/:id   # 模型更新/删除
GET/POST   /api/algo-manage/algorithms   # 算法 CRUD（含 model_ids 关联）
PUT/DELETE /api/algo-manage/algorithms/:id
GET/POST   /api/algo-manage/plugins      # 插件列表/上传（转发 Python）
DELETE    /api/algo-manage/plugins/:filename
POST       /api/algo-manage/upload-file  # 模型文件上传

# 语音报警（/api/voice-alarm）
GET/PUT    /api/voice-alarm/settings     # 全局开关、设备 IP/用户/密码
GET/PUT    /api/voice-alarm/algo-map/:algo_id   # 算法-语音映射
DELETE     /api/voice-alarm/algo-map/:algo_id
GET/POST   /api/voice-alarm/audio-files # 音频文件列表/上传
DELETE     /api/voice-alarm/audio-files/:name

# 报警上传（/api/alarm-upload）
GET/PUT    /api/alarm-upload/settings    # 开关、上传地址、设备 ID
GET        /api/alarm-upload/queue       # 上传队列（待上传/成功/失败）
POST       /api/alarm-upload/run-now     # 立即执行一次上传
```

**`/api/cameras/:id/snapshot` 实现说明：**
调用 ZLM 的 `getSnap` API，使用摄像头真实 RTSP 地址由 ZLM 用 ffmpeg 截帧（`/opt/ffmpeg-rk/bin/ffmpeg`），返回 JPEG。响应 `Content-Type` 不为 `image/jpeg` 时（如 ZLM 返回 logo.png）一律返回 503，前端显示"画面不可用"提示。

**编译：**
```bash
export PATH=$PATH:/home/hzhy/go/bin
export GOPATH=/home/hzhy/gopath
export GOPROXY=https://goproxy.cn,direct
cd /home/hzhy/ai-monitor-backend
go build -o ai-monitor-backend .
```

---

### 3.5 Vue3 前端

| 项目 | 详情 |
|------|------|
| **位置** | `/home/hzhy/ai-monitor-frontend/` |
| **启动** | `/home/hzhy/ai-monitor-frontend/start.sh`（dev 模式） |
| **访问地址** | `http://localhost:5173` |
| **技术栈** | Vite 4 + Vue3 + Element Plus + mpegts.js + Vue Router 4 + Pinia + axios |

**七个功能页面：**

1. **控制台**（`src/views/Dashboard.vue`）
   - 左侧多画面预览区：支持 1×1 / 2×2 / 3×2 / 3×3 布局，每格可独立选择任务播放 HTTP-FLV
   - 右侧实时告警面板：今日/累计告警统计 + 最近 20 条滚动列表

2. **设备管理**（`src/views/Cameras.vue`）
   - 摄像头 CRUD（增删改查）
   - ZLM 推流启/停控制
   - 实时直播预览（mpegts.js 播放 HTTP-FLV）
   - 流状态展示（推流中/未启动/异常）

3. **任务管理**（`src/views/Tasks.vue`）
   - 任务 CRUD
   - 创建时可绑定多个算法，**算法参数从 `algorithms.param_definition` 字段动态渲染**（不再硬编码），支持 number / slider / select 等控件类型
   - ROI 检测区域使用 `RoiDrawer.vue` 组件，在摄像头当前帧上**鼠标点击画多边形**，自动转换为归一化坐标
   - 任务启停（调 Go API → Go 转 Python）
   - 一键跳转查看该任务告警

4. **事件告警**（`src/views/Alarms.vue`）
   - 分页告警列表
   - 按任务/状态筛选
   - 内联图片预览（报警快照）
   - 标记为已处理

5. **算法模型**（`src/views/AlgoManage.vue`）
   - **模型管理**：RKNN 模型 CRUD（路径、标签、阈值、输入尺寸等）
   - **算法配置**：算法 CRUD、关联模型、param_definition 编辑
   - **插件管理**：插件列表、上传 .py 文件、删除插件

6. **语音报警**（`src/views/VoiceAlarm.vue`）
   - 全局语音报警开关
   - 发声设备配置（IP、用户名、密码，用于摄像头喇叭播放）
   - 算法-语音映射：为每种算法选择对应音频文件
   - 音频文件上传/管理

7. **报警上传**（`src/views/AlarmUpload.vue`）
   - 全局报警上传开关
   - 上传配置（设备 ID、上传地址）
   - 上传队列查看（待上传/成功/失败）
   - 手动触发立即上传

**组件：**
- `src/components/VideoPlayer.vue`：mpegts.js 封装，hasAudio=false 绕过 PCMA 音频问题
- `src/components/RoiDrawer.vue`：ROI 画区域组件，从 `/api/cameras/:id/snapshot` 加载截图作为背景，Canvas 交互式多边形绘制，输出归一化 `[[x,y],...]` JSON

**Vite 代理配置（仅开发模式）：** `/api` 和 `/snapshots` 请求代理到 Go 后端 `:8090`，视频流直接访问 ZLM `:80`。

**生产环境部署方式（Go 直接托管前端）：**

开发阶段使用 `npm run dev`（Vite dev server，`:5173`）。正式部署时无需 Node.js，由 Go 后端直接托管编译产物：

```bash
# 第一步：构建前端静态文件
cd /home/hzhy/ai-monitor-frontend
npm run build
# 产物输出到 dist/ 目录
```

然后在 Go `main.go` 中添加以下路由（在现有路由之后）：

```go
// 托管前端静态资源
r.Static("/assets", "/home/hzhy/ai-monitor-frontend/dist/assets")
r.StaticFile("/favicon.ico", "/home/hzhy/ai-monitor-frontend/dist/favicon.ico")
// Vue Router history 模式：未匹配路由均返回 index.html
r.NoRoute(func(c *gin.Context) {
    c.File("/home/hzhy/ai-monitor-frontend/dist/index.html")
})
```

部署后只需启动 Go 后端，通过 `http://工控机IP:8090` 直接访问 Web 界面。前端 JS 中的 `/api/` 和 `/snapshots/` 请求会自动打到同一个 Go 服务，无需 Nginx 或额外代理。

---

### 3.6 数据库

| 项目 | 详情 |
|------|------|
| **文件** | `/home/hzhy/aimonitor.db`（SQLite 3） |
| **建表 SQL** | `/home/hzhy/aimonitor.sql` |
| **测试数据** | `/home/hzhy/aimonitor_insert_value.sql` |

**表结构：**

| 表名 | 说明 | 主要字段 |
|------|------|---------|
| `cameras` | 摄像头信息 | id, name, rtsp_url, location, status |
| `zlm_streams` | ZLM 代理流状态 | camera_id, stream_key, proxy_key, status |
| `algorithms` | 算法字典（预设） | id, algo_key, algo_name, category, **param_definition** |
| `models` | RKNN 模型注册表（Python 启动任务时从此读取模型信息） | id, model_name, model_path, labels_path, model_type, input_width, input_height, conf_threshold, nms_threshold |
| `algo_model_map` | 算法与模型的关联（决定每个算法用哪些模型） | id, algo_id, model_id |
| `tasks` | 监控任务 | id, task_name, camera_id, status(0停/1运行/2异常), error_msg |
| `task_algo_details` | 任务-算法配置 | task_id, algo_id, roi_config, algo_params(JSON), alarm_config(JSON) |
| `alarms` | 报警记录 | task_id, algo_name, alarm_time, image_url, status(0未处理/1已处理), alarm_details |
| `system_settings` | 系统配置（KV） | key, value（语音报警开关、设备 IP/用户/密码；报警上传开关、URL、设备 ID） |
| `voice_alarm_algo_map` | 算法-语音映射 | algo_id, audio_file |
| `alarm_upload_queue` | 报警上传队列 | alarm_id, status(0待上传/1成功/2失败), retry_count, last_error |

**`algorithms.param_definition` 字段：** 算法参数的元数据 JSON 数组，前端据此动态渲染配置表单：
```json
[
  { "key": "confidence", "label": "置信度阈值", "type": "number", "default": 0.35, "min": 0.1, "max": 1.0, "step": 0.05 },
  { "key": "duration",   "label": "持续时间(秒)", "type": "number", "default": 30, "min": 1, "max": 300, "step": 1 },
  { "key": "skip_frame", "label": "跳帧数",    "type": "number", "default": 10, "min": 1, "max": 30,  "step": 1 }
]
```
字段为空或 `null` 时，前端不渲染动态参数，仅显示通用的"冷却时间"配置。

**algo_params JSON 字段（写入 `task_algo_details.algo_params`）：**
```json
{
  "confidence": 0.35,   // 检测置信度阈值
  "duration": 30,       // 行为持续多少秒才触发报警
  "skip_frame": 10      // 每 N 帧推理一次
}
```

**alarm_config JSON 字段：**
```json
{
  "alarm_interval": 60  // 报警冷却时间（秒），冷却内不重复报警
}
```

**roi_config JSON 字段：** 归一化多边形坐标 `[[0.1,0.1],[0.9,0.9],...]`，`[]` 表示全屏

---

## 四、服务端口总览

| 服务 | 端口 | 协议 | 说明 |
|------|------|------|------|
| ZLMediaKit HTTP API | 80 | HTTP | 流管理 REST API |
| ZLMediaKit RTSP | 554 | RTSP | RTSP 转发 |
| ZLMediaKit RTMP | 1935 | RTMP | RTMP 转发 |
| ZLMediaKit WebRTC | 8000 | UDP | WebRTC |
| C++ Infer Server | 8080 | HTTP | 推理控制 REST API |
| C++ Infer Server ZMQ | 5555 | ZMQ PUB | 推理结果推送 |
| Go 后端 | 8090 | HTTP | 管理 REST API |
| Python 算法服务 | 9500 | HTTP | 任务控制 REST API |
| Vue 前端（开发） | 5173 | HTTP | Web 管理界面 |

---

## 五、启动顺序

完整启动系统需按以下顺序启动各组件：

```bash
# 1. ZLMediaKit（已在后台运行，通常开机自启）
# 检查: ps aux | grep MediaServer

# 2. C++ Infer Server
cd /home/hzhy/infer-server/infer-server/build
LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ./infer_server ../config/server.json

# 3. Python 算法调度服务
cd /home/hzhy/ai-monitor-service
python3 main.py
# 或: uvicorn main:app --host 0.0.0.0 --port 9500

# 4. Go 后端
/home/hzhy/ai-monitor-backend/start.sh

# 5. Vue 前端（开发模式）
/home/hzhy/ai-monitor-frontend/start.sh
# 访问 http://localhost:5173
```

---

## 六、关键技术要点

### 硬件平台
- 工控机：Rockchip RK3576，ARM64，Linux 6.1.99
- 内核为单内核镜像（monolithic kernel），不支持可加载内核模块
- 已内置驱动：RTL8822CU（WiFi）
- NPU：RKNN（RKNN Runtime 推理）

### Go 开发环境
- Go 1.22.5 安装在 `/home/hzhy/go/`，非系统 PATH
- 使用前：`export PATH=$PATH:/home/hzhy/go/bin`
- 模块缓存：`/home/hzhy/gopath/`
- 国内代理：`export GOPROXY=https://goproxy.cn,direct`
- SQLite 驱动用 `modernc.org/sqlite`（纯 Go，无需 CGO/gcc）

### Python 环境
- Python 3.10
- 虚拟环境：`/home/hzhy/ai-monitor-service/venv/`
- 关键包：fastapi、uvicorn、pyzmq、aiosqlite、httpx

### 视频流技术
- ZLM 统一接入，前端播放用 mpegts.js（flv.js 的继任者）播放 HTTP-FLV
- HTTP-FLV 延迟约 1~3s，比 HLS（5~10s）低
- C++ infer server 直接从 RTSP 拉流推理，不经过 ZLM（避免额外延迟）
- ZMQ 采用 PUB/SUB 模式，Python 订阅所有频道后按 `cam_id` 路由

### 数据库并发
- SQLite WAL 模式，支持多读单写
- Python 端用 aiosqlite 异步访问；Go 端 `SetMaxOpenConns(1)` 避免写冲突

---

## 七、扩展新行为检测

只需在 `/home/hzhy/ai-monitor-service/plugins/` 目录新建 `xxx.py`：

```python
from plugins.base import BehaviorPlugin, PluginState
from schemas import AlarmEvent, Detection
import time

class PlayPhonePlugin(BehaviorPlugin):
    algo_key = "play_phone"  # 必须与 algorithms.algo_key 匹配

    def __init__(self, algo_params: dict, alarm_config: dict, roi_config: list, **kwargs):
        super().__init__(algo_params, alarm_config, roi_config, **kwargs)
        # confidence_threshold 不再由基类提取，各插件在此自行声明
        self.confidence_threshold: float = algo_params.get("confidence", 0.35)

    def process_frame(self, detections, frame_info):
        now = time.monotonic()
        # 检测到 person + cell phone 同框持续 duration 秒
        has_phone_person = any(
            d.class_name == "cell phone" and d.confidence >= self.confidence_threshold
            for d in detections
        ) and any(
            d.class_name == "person" and d.confidence >= self.confidence_threshold
            for d in detections
        )
        if has_phone_person:
            self._start_tracking(now)
        else:
            self._reset_tracking()
            return None
        if self._check_duration(now):
            return self._try_alarm(now, "打电话", f"持续 {self.duration:.0f}s 检测到玩手机行为")
        return None
```

然后在数据库 `algorithms` 表插入该算法记录，在 `task_algo_details` 配置参数即可，无需重启服务（动态加载）。

---

## 八、文件总览

```
/home/hzhy/
├── aimonitor.db                  ← 共享 SQLite 数据库（所有组件读写）
├── aimonitor.sql                 ← 建表 SQL
├── aimonitor_insert_value.sql    ← 测试数据 SQL
├── yolo11n-rk3576.rknn           ← YOLO11n RKNN 模型权重
├── yolo11n-labels.txt            ← COCO 80 类标签
├── CLAUDE.md                     ← AI 助手速读文档（关键要点摘要）
├── ai-monitor-intro.md           ← 本文档（总体介绍）
├── Audio/                        ← 语音报警音频目录（Java TTS jar + 音频文件）
│
├── ZLMediaKit/                   ← ZLM 源码及可执行文件
│   └── release/linux/Debug/MediaServer  ← ZLM 主程序
│
├── infer-server/infer-server/    ← C++ 推理服务源码
│   ├── docs/api_reference.md     ← C++ infer server API 文档
│   └── build/infer_server        ← 编译产物（主程序）
│
├── ai-monitor-service/           ← Python 算法调度服务
│   ├── main.py                   ← FastAPI 入口（:9500）
│   ├── voice_alarm.py            ← 语音报警调度器
│   ├── plugins/                  ← 行为检测插件目录
│   └── snapshots/                ← 报警抓图存储目录
│
├── ai-monitor-backend/           ← Go REST 后端
│   ├── main.go                   ← Gin 入口（:8090）
│   ├── uploader/                 ← 报警上传后台 Worker
│   ├── start.sh                  ← 一键启动脚本
│   └── ai-monitor-backend        ← 编译产物（binary）
│
└── ai-monitor-frontend/          ← Vue3 前端
    ├── src/views/                ← 七个主页面（含 AlgoManage、VoiceAlarm、AlarmUpload）
    ├── start.sh                  ← 一键启动脚本（dev 模式）
    └── dist/                     ← 生产构建产物
```

# AI 智能视频监控系统 — 总体介绍

> 本文档面向后来参与此项目的开发者或 AI 助手，目的是快速说明当前代码对应的真实系统结构、功能边界、组件位置和关键数据流。本文已按 2026-04-20 当前代码更新。

---

## 一、系统概述

这是一套运行在 Rockchip RK3576 工控机上的工业级智能视频监控系统，核心能力包括：

- 多路 RTSP 摄像头接入、代理和直播预览
- 基于 NPU 的 AI 检测与行为分析
- 任务化配置：一个摄像头可绑定多个算法
- ROI 检测区域配置
- 告警抓图、状态处理、批量删除
- 语音报警
- 报警上传与失败重传
- 定位状态与航行/停泊条件联动
- 模型管理、算法管理、插件管理
- 模型测试
- 系统信息、网络配置、日志查看

当前前端实际菜单为：

- 控制台
- 设备管理
- 任务管理
- 事件告警
- 算法模型
- 模型测试
- 定位管理
- 语音报警
- 报警上传
- 系统管理
  - 系统信息
  - 网络配置
  - 日志查看

---

## 二、整体架构

```text
┌─────────────────────────────────────────────────────────────────────┐
│                           用户浏览器                                 │
│                    Vue3 前端 (默认开发端口 :5173)                     │
└──────────────────────┬───────────────────────────┬──────────────────┘
                       │ REST API                   │ HTTP-FLV 直播流
                       ▼                            ▼
┌──────────────────────────────┐   ┌──────────────────────────────────┐
│ Go 后端 (默认 :8090)         │   │ ZLMediaKit (默认 :80 / :554)     │
│ - 摄像头/任务/告警 CRUD      │   │ - 拉取 RTSP 代理流               │
│ - 算法/模型/插件管理         │──▶│ - 输出 HTTP-FLV / HLS / RTSP     │
│ - 语音报警/报警上传/定位配置 │   │ - getSnap 截图接口               │
│ - 网络/日志/系统信息         │   └──────────────────────────────────┘
│ - 转发任务控制到 Python      │                 ▲
└───────────────┬──────────────┘                 │ RTSP
                │ HTTP                           │
                ▼                                │
┌──────────────────────────────┐                 │
│ Python 算法调度服务 (:9500)  │                 │
│ - 任务生命周期管理           │                 │
│ - 插件化行为判断             │                 │
│ - ZMQ 订阅推理结果           │                 │
│ - 生成告警/抓图/触发语音     │                 │
│ - 模型测试会话管理           │                 │
└───────────────┬──────────────┘                 │
                │ HTTP + ZMQ SUB                 │
                ▼                                │
┌────────────────────────────────────────────────┴───────────────────┐
│ C++ Infer Server (:8080, ZMQ PUB :5555)                            │
│ - RTSP 解码                                                         │
│ - RKNN / YOLO 推理                                                  │
│ - 发布每帧检测结果                                                  │
└────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────────┐
                    │ SQLite / aimonitor.db      │
                    │ 各服务共享业务数据         │
                    └────────────────────────────┘
```

---

## 三、关键数据流

### 3.1 摄像头接入与预览

1. 用户在前端“设备管理”添加摄像头
2. Go 后端写入 `cameras`
3. Go 后端调用 ZLMediaKit `addStreamProxy`
4. ZLM 拉取摄像头 RTSP，并暴露 `live/cam{id}.live.flv`
5. 前端通过 `mpegts.js` 直接播放 HTTP-FLV

说明：

- 视频流不经过 Go 后端转发，避免后端成为带宽瓶颈
- 摄像头截图接口 `/api/cameras/:id/snapshot` 由 Go 后端代理 ZLM `getSnap`

### 3.2 任务启动与推理

1. 用户在前端创建任务，保存任务和算法配置
2. 用户点击启动任务
3. Go 后端调用 Python `/api/task/start`
4. Python 根据任务关联算法、模型、ROI 等信息创建运行态
5. Python 调用 C++ infer server 注册对应流
6. C++ infer server 直接拉 RTSP 推理
7. C++ 通过 ZeroMQ 发布每帧检测结果
8. Python 订阅结果并分发给插件

### 3.3 告警生成

1. 插件根据检测结果、时间窗口、状态机、阈值等判断是否触发事件
2. Python `alarm_manager` 生成告警记录
3. 触发抓图并写入 `alarms`
4. 前端通过 `/api/alarms` 查询告警并展示

### 3.4 语音报警

1. 告警触发后，Python 查询 `voice_alarm_algo_map`
2. 若该算法已绑定音频文件且全局语音报警开启，则触发语音调度
3. 语音配置文件由 Go 后端写入运行目录

### 3.5 报警上传

1. 新告警入队 `alarm_upload_queue`
2. Go 后端上传 Worker 定时检查队列
3. 成功则标记成功，失败则保留并记录错误
4. 前端可查看统计、分页队列，并执行失败项重传

### 3.6 航行状态联动

1. 定位服务持续更新当前位置和速度
2. 系统根据阈值判断当前为 `underway` 或 `moored`
3. 任务中的算法可配置 `nav_condition`
4. 仅在满足条件时允许触发告警

---

## 四、组件说明

### 4.1 Vue3 前端

| 项目 | 详情 |
|------|------|
| 位置 | `/home/hzhy/ai-monitor-frontend/` |
| 入口 | `src/App.vue` |
| 路由 | `src/router/index.js` |
| 启动 | `/home/hzhy/ai-monitor-frontend/start.sh` |
| 默认地址 | `http://localhost:5173` |

当前页面包括：

- `Dashboard.vue` 控制台
- `Cameras.vue` 设备管理
- `Tasks.vue` 任务管理
- `Alarms.vue` 事件告警
- `AlgoManage.vue` 算法模型
- `ModelTest.vue` 模型测试
- `Position.vue` 定位管理
- `VoiceAlarm.vue` 语音报警
- `AlarmUpload.vue` 报警上传
- `SystemInfo.vue` 系统信息
- `NetworkConfig.vue` 网络配置
- `SystemLogs.vue` 日志查看

前端关键特性：

- 侧栏导航 + 顶部服务在线状态
- 控制台支持 1/4/6/9 画面布局
- 任务页面支持动态算法参数表单
- 任务页面支持 ROI 多边形绘制
- 告警页面支持列表/卡片两种视图
- 模型测试支持临时测试会话与检测框叠加

注意：

- 旧文档里“前端只有 4 个页面”已经过时
- 当前前端实际已包含算法、模型测试、定位、上传、语音、网络、日志等页面

### 4.2 Go 后端管理服务

| 项目 | 详情 |
|------|------|
| 位置 | `/home/hzhy/ai-monitor-backend/` |
| 入口 | `main.go` |
| 启动脚本 | `/home/hzhy/ai-monitor-backend/start.sh` |
| 默认端口 | `:8090` |

主要职责：

- 提供前端全部 REST API
- 管理摄像头和 ZLM 代理流
- 管理任务、告警、算法、模型、插件
- 管理语音报警和报警上传设置
- 管理定位设置、系统信息、网络配置、系统日志
- 代理模型测试接口到 Python 服务

当前后端主要路由分组：

- `/api/health`
- `/api/cameras`
- `/api/algorithms`
- `/api/tasks`
- `/api/model-test`
- `/api/alarms`
- `/api/voice-alarm`
- `/api/alarm-upload`
- `/api/position`
- `/api/system`
- `/api/algo-manage`

和旧版相比，新增或明确包含：

- 模型测试代理
- 定位管理
- 系统信息
- 网络配置
- 系统日志
- 批量删除告警
- 告警上传统计、分页队列、失败重传

### 4.3 Python 算法调度服务

| 项目 | 详情 |
|------|------|
| 位置 | `/home/hzhy/ai-monitor-service/` |
| 入口 | `main.py` |
| 默认端口 | `:9500` |

主要职责：

- 恢复和管理运行中的任务
- 订阅推理结果
- 将检测结果路由到各个算法插件
- 生成告警、抓图、触发语音
- 管理模型测试会话

当前关键模块：

- `task_manager.py`
- `alarm_manager.py`
- `voice_alarm.py`
- `position_manager.py`
- `model_test_manager.py`
- `zmq_subscriber.py`

当前插件目录中的主要文件包括：

- `no_person.py`
- `eye_close.py`
- `eye_close_yolo.py`
- `yawning.py`
- `yawning_yolo.py`
- `ppe_detect.py`
- `phone_usage.py`
- `behavior_detect_new.py`
- `fire_smoke_detect.py`

说明：

- 旧文档中的 `behavior_detect.py` 已不再准确，当前代码里是 `behavior_detect_new.py`
- 当前代码中已存在 YOLO 疲劳版插件 `eye_close_yolo` / `yawning_yolo`
- Python 服务除了任务与插件，还承担模型测试和定位状态更新相关职责

### 4.4 C++ Infer Server

| 项目 | 详情 |
|------|------|
| 位置 | `/home/hzhy/infer-server/infer-server/` |
| 默认 HTTP 端口 | `:8080` |
| 默认 ZMQ 发布 | `:5555` |

主要职责：

- 解码 RTSP
- 调用 RKNN 模型进行推理
- 将每帧检测结果以 JSON 形式发布给 Python 服务

推理结果中除常规 detections 外，还可能包含：

- `faces`
- `ear`
- `mar`
- `eye_width_ratio`

这些字段会被疲劳检测相关插件使用。

### 4.5 ZLMediaKit

| 项目 | 详情 |
|------|------|
| 位置 | `/home/hzhy/ZLMediaKit/` |
| 默认 HTTP 端口 | `:80` |
| 默认 RTSP 端口 | `:554` |

主要职责：

- 通过 `addStreamProxy` 代理 RTSP
- 提供 HTTP-FLV / HLS / RTSP 分发
- 提供 `getSnap` 截图

关键说明：

- 直播预览依赖 HTTP-FLV
- 前端播放时通常跳过音频轨，避免摄像头 PCMA 音频导致浏览器不兼容
- ZLM 重启后内存中的代理流会丢失，需要重新注册

---

## 五、数据库概览

共享数据库通常为 `aimonitor.db`。

当前核心表包括：

- `cameras`
- `zlm_streams`
- `algorithms`
- `models`
- `algo_model_map`
- `tasks`
- `task_algo_details`
- `alarms`
- `voice_alarm_algo_map`
- `alarm_upload_queue`
- `system_settings`
- `position_runtime_status`

当前数据库层已承载的不只是传统摄像头/任务/告警，还包括：

- 语音报警开关与设备信息
- 报警上传开关与上传地址
- 航行判定参数
- 当前定位状态
- 算法和模型多对多关系

---

## 六、当前算法能力

当前种子数据和代码中可见的算法能力包括：

- `no_person` 离岗
- `eye_close` 闭眼
- `eye_close_yolo` 闭眼 YOLO 版
- `yawning` 打哈欠
- `yawning_yolo` 打哈欠 YOLO 版
- `eat_banana` 吃香蕉
- `no_hardhat` 未戴安全帽
- `no_mask` 未戴口罩
- `no_safety_vest` 未穿救生衣
- `call` 打电话
- `phone` 玩手机
- `smoke` 吸烟

此外，从插件目录还能看出系统预留或正在演进中的能力：

- 手机使用类检测
- 行为综合检测
- 火/烟检测

说明：

- 前端任务页实际展示什么算法，最终以数据库 `algorithms` 表为准
- 某些插件文件存在，不代表一定已写入当前数据库种子

---

## 七、任务配置模型

任务并不是简单地“摄像头 + 单一算法”，而是：

- 一个任务绑定一个摄像头
- 一个任务可绑定多个算法
- 每个算法有独立的：
  - `algo_params`
  - `alarm_config`
  - `roi_config`

其中当前前端已支持的通用字段包括：

- `alarm_interval`
- `nav_condition`
- `roi`

`nav_condition` 可选值：

- `all`
- `underway`
- `moored`

这意味着任务告警已经具备“按定位状态过滤”的能力，而不只是简单的全时段检测。

---

## 八、模型与插件管理

当前系统的“算法模型”页面已分为三部分：

### 8.1 模型管理

管理内容包括：

- 模型名称
- 模型路径
- 标签文件路径
- 模型类型
- 输入宽高
- 置信度阈值
- NMS 阈值

### 8.2 算法配置

管理内容包括：

- 算法名称
- `algo_key`
- 分类
- 上传标识 `upload_recog_type`
- 关联模型列表
- 动态参数定义 `param_definition`

### 8.3 插件文件

支持：

- 上传 `.py` 插件文件
- 下载插件文件
- 删除非受保护插件
- 解析插件中的 `algo_key`

这部分与旧版“插件上传/删除”描述一致，但当前已经落地到完整前端和后端管理界面中，而不是单独的 Python 裸接口使用。

---

## 九、模型测试

这是当前代码中比较明显的新功能，旧版介绍未覆盖。

作用：

- 从已管理模型中选一个 YOLO 模型
- 从已添加摄像头中选一个摄像头
- 临时发起推理测试
- 实时叠加检测框
- 查看检测目标、推理耗时和帧信息

特点：

- 测试会话有心跳
- 页面离开时会自动释放会话
- 服务端会回收超时会话

这说明系统已经不只是“正式任务运行平台”，也具备一定调试与验模能力。

---

## 十、定位与航行状态

这是当前代码中另一块旧文档未充分覆盖的能力。

功能包括：

- 查看实时定位状态
- 查看经纬度、速度、航向、UTC/北京时间
- 查看定位源与错误状态
- 配置航行速度阈值
- 配置检测间隔

系统会根据速度阈值判断：

- `underway` 航行中
- `moored` 停泊时

并与任务算法中的 `nav_condition` 联动。

---

## 十一、系统管理能力

当前代码中的系统管理已包括：

### 11.1 系统信息

- CPU 占用
- 内存占用
- 磁盘占用
- 当前系统时间

### 11.2 网络配置

支持配置：

- `eth0`
- `eth1`

支持方式：

- DHCP
- 静态 IP

底层通过 `NetworkManager / nmcli` 应用配置。

### 11.3 日志查看

当前支持查看和重启的服务包括：

- 推理服务
- Python 算法服务
- Go 后端服务
- ZLMediaKit 服务
- FRPC 服务

---

## 十二、与旧版说明相比的主要差异

下面这些点是本次更新重点修正的内容：

1. 前端页面数量已大幅增加，不再只有控制台/摄像头/任务/告警几页。
2. 当前系统已包含模型测试、定位管理、系统信息、网络配置、日志查看。
3. Python 插件列表已变化，且增加了 `eye_close_yolo`、`yawning_yolo` 等算法。
4. 任务已支持 `nav_condition` 和 ROI，多算法配置更完整。
5. 报警上传接口以“统计 + 队列 + 失败重传”为主，旧版 `run-now` 描述已不准确。
6. 语音报警、报警上传、定位状态都已进入正式前后端管理页面，不再只是零散接口。

---

## 十三、建议阅读顺序

如果要继续开发或排查问题，建议按下面顺序进入代码：

1. 前端路由：`/home/hzhy/ai-monitor-frontend/src/router/index.js`
2. 后端入口：`/home/hzhy/ai-monitor-backend/main.go`
3. Python 服务入口：`/home/hzhy/ai-monitor-service/main.py`
4. 任务页：`/home/hzhy/ai-monitor-frontend/src/views/Tasks.vue`
5. 算法模型页：`/home/hzhy/ai-monitor-frontend/src/views/AlgoManage.vue`
6. Python 插件目录：`/home/hzhy/ai-monitor-service/plugins/`
7. 数据种子：`/home/hzhy/ai-monitor-release/sql/seed_base.sql`
8. 增量迁移：`/home/hzhy/ai-monitor-release/sql/migration/`

---

## 十四、一句话总结

当前这套系统已经从“基础摄像头 + 任务 + 告警”平台，演进成了一个包含视频接入、AI 推理、插件算法、模型管理、定位联动、语音报警、告警上传、系统运维工具的完整监控业务系统。

# `systemd` 服务设计

> 本文档用于定义 AI 智能视频监控系统在生产部署中的 `systemd` 服务拆分方式、依赖关系、目录约定、推荐单元配置和运维方式。目标是让系统在机器开机后能够自动、稳定、可观测地运行，而不是依赖人工按顺序启动。

---

## 一、为什么要用 `systemd`

对于当前这套系统，组件多、依赖关系明确：

- ZLMediaKit
- C++ 推理服务
- Python 算法调度服务
- Go 后端

如果继续手工启动，会遇到很多问题：

- 启动顺序不稳定
- 某个服务意外挂掉后不会自动恢复
- 日志分散
- 开机后需要人工介入
- 现场运维门槛高

使用 `systemd` 可以解决这些问题：

- 开机自启
- 服务间依赖顺序明确
- 异常自动重启
- 统一日志查看
- 标准化运维

---

## 二、推荐拆分的四个服务

建议拆成以下四个主服务：

- `zlm.service`
- `infer.service`
- `ai-monitor-python.service`
- `ai-monitor-backend.service`

前端正式部署建议由 Go 后端直接托管 `dist`，因此不再单独设置前端服务。

---

## 三、服务职责定义

### 1. `zlm.service`

负责：

- 启动 ZLMediaKit
- 提供 RTSP/HTTP-FLV/HLS 等媒体能力
- 提供 ZLM HTTP API
- 提供截图等基础媒体服务

这是整个系统的视频入口和转发核心。

### 2. `infer.service`

负责：

- 启动 C++ 推理服务
- 从 RTSP 拉流进行推理
- 发布 ZMQ 推理结果
- 提供推理控制 HTTP API

这是系统的 AI 推理核心。

### 3. `ai-monitor-python.service`

负责：

- 启动 Python 算法调度服务
- 接收推理结果
- 进行插件化行为判断
- 写告警、存快照、触发语音报警
- 提供任务控制和健康检查接口

这是业务逻辑核心。

### 4. `ai-monitor-backend.service`

负责：

- 启动 Go 管理后端
- 对前端提供 REST API
- 协调 ZLM 和 Python 服务
- 管理数据库 CRUD
- 托管前端静态资源

这是系统的控制中心和 Web 接口入口。

---

## 四、推荐依赖关系

从功能上看，依赖关系建议如下：

```text
zlm.service
    ↓
infer.service
    ↓
ai-monitor-python.service
    ↓
ai-monitor-backend.service
```

更准确地说：

- `zlm.service` 依赖网络
- `infer.service` 依赖网络和基础运行时
- `ai-monitor-python.service` 依赖 `infer.service`
- `ai-monitor-backend.service` 依赖 `ai-monitor-python.service`

其中：

- Go 后端虽然理论上不一定必须等待 Python 完全可用才能启动，但在你的项目里健康检查、任务控制、算法管理等都涉及 Python 服务，因此建议显式依赖 Python 服务
- 推理服务和 ZLM 在业务上相对独立，但从整体系统启动顺序来说，先让视频相关基础服务起来更稳妥

---

## 五、统一目录假设

下面的设计基于如下目录约定：

- 程序目录：`/opt/ai-monitor/`
- 配置目录：`/etc/ai-monitor/`
- 数据目录：`/var/lib/ai-monitor/`
- 日志目录：`/var/log/ai-monitor/`

例如：

```text
/opt/ai-monitor/bin/
/opt/ai-monitor/python/
/opt/ai-monitor/frontend/dist/
/opt/ai-monitor/models/
/etc/ai-monitor/
/var/lib/ai-monitor/
/var/log/ai-monitor/
```

---

## 六、推荐的 `systemd` 通用设计原则

每个服务建议都遵循以下原则：

- `Type=simple`
- 设置 `WorkingDirectory`
- 用 `Restart=always` 或 `Restart=on-failure`
- 配置合理的 `RestartSec`
- 不要把太多 shell 逻辑塞进 `ExecStart`
- 复杂前置检查放到独立脚本中

同时建议为所有服务统一设置：

- 环境变量文件 `EnvironmentFile=/etc/ai-monitor/app.env`
- 日志走 `journald`
- 必要时单独指定用户和组

---

## 七、`zlm.service` 建议写法

### 服务定位

用于管理 ZLMediaKit 主进程。

### 关键点

- 确保配置文件路径固定
- 确保 `ffmpeg.bin` 已指向 `/opt/ffmpeg-rk/bin/ffmpeg`
- 建议使用绝对路径启动

### 示例

```ini
[Unit]
Description=AI Monitor ZLMediaKit Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/ai-monitor/zlm
ExecStart=/opt/ai-monitor/zlm/MediaServer -c /etc/ai-monitor/zlm.ini
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### 说明

- 如果你的 `MediaServer` 实际路径不同，可按实际路径调整
- 若 ZLM 启动依赖某些目录存在，可在安装阶段创建，不建议在这里写复杂 shell

---

## 八、`infer.service` 建议写法

### 服务定位

用于管理 C++ 推理服务。

### 关键点

- 明确配置文件位置
- 明确模型目录
- 用 `LD_PRELOAD` 注入 `jemalloc`
- 依赖网络和 ZLM

### 示例

```ini
[Unit]
Description=AI Monitor Infer Server
After=network-online.target zlm.service
Wants=network-online.target
Requires=zlm.service

[Service]
Type=simple
WorkingDirectory=/opt/ai-monitor/bin
EnvironmentFile=/etc/ai-monitor/app.env
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libjemalloc.so.2
ExecStart=/opt/ai-monitor/bin/infer_server /etc/ai-monitor/infer-server.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### 说明

- 如果推理服务并不真正依赖 ZLM，也可以把 `Requires=zlm.service` 去掉，只保留 `After=network-online.target`
- 但从你当前整体系统的启动组织上看，先起 ZLM 再起 infer 更容易统一排查

---

## 九、`ai-monitor-python.service` 建议写法

### 服务定位

用于管理 Python 算法调度服务。

### 关键点

- 使用固定 Python 虚拟环境
- 工作目录固定到应用目录
- 依赖推理服务
- 所有路径从配置读取，不要写死 `/home/hzhy/...`

### 示例

```ini
[Unit]
Description=AI Monitor Python Algorithm Service
After=network-online.target infer.service
Wants=network-online.target
Requires=infer.service

[Service]
Type=simple
WorkingDirectory=/opt/ai-monitor/python/app
EnvironmentFile=/etc/ai-monitor/app.env
ExecStart=/opt/ai-monitor/python/venv/bin/python /opt/ai-monitor/python/app/main.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### 如果改成 uvicorn 启动

也可以写成：

```ini
ExecStart=/opt/ai-monitor/python/venv/bin/uvicorn main:app --host 0.0.0.0 --port 9500
```

但前提是你的 Python 服务入口已经完全适配这种启动方式。

### 说明

- 若需要调试参数，例如 `--debug-face-metrics`，不建议直接写死在正式服务文件中
- 更推荐通过 `/etc/ai-monitor/app.env` 控制调试开关

---

## 十、`ai-monitor-backend.service` 建议写法

### 服务定位

用于管理 Go 后端服务，同时托管前端 `dist`。

### 关键点

- 依赖 Python 服务
- 如果后端健康检查依赖 ZLM、Python，应允许自动重试
- 前端正式部署由 Go 托管，不再运行 Vite 开发服务器

### 示例

```ini
[Unit]
Description=AI Monitor Go Backend Service
After=network-online.target ai-monitor-python.service
Wants=network-online.target
Requires=ai-monitor-python.service

[Service]
Type=simple
WorkingDirectory=/opt/ai-monitor/bin
EnvironmentFile=/etc/ai-monitor/app.env
ExecStart=/opt/ai-monitor/bin/ai-monitor-backend
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### 说明

- 如果 Go 后端将前端静态文件编译进程序或从固定目录读取，请确保对应路径在配置中统一
- 不建议正式环境再单独启动 `npm run dev`

---

## 十一、是否要使用专用运行用户

工业项目里通常建议不要全部服务都用 root 运行。

更推荐：

- 通过安装脚本创建专用用户，例如 `ai-monitor`
- 将程序、日志、数据目录授权给这个用户

例如：

- `User=ai-monitor`
- `Group=ai-monitor`

但也要考虑实际情况：

- ZLM、推理服务、设备访问、低端口绑定、某些硬件资源访问，可能需要额外权限

因此可以采用折中方案：

- 先用 root 验证整套服务稳定运行
- 再逐步收缩权限

如果暂时还没有完整梳理硬件访问权限，不要贸然把全部服务都改成普通用户。

---

## 十二、环境变量建议

建议所有服务共享一个统一环境变量文件：

- `/etc/ai-monitor/app.env`

可包含：

```bash
AI_MONITOR_DB_PATH=/var/lib/ai-monitor/aimonitor.db
AI_MONITOR_SNAPSHOT_DIR=/var/lib/ai-monitor/snapshots
AI_MONITOR_MODEL_DIR=/opt/ai-monitor/models
AI_MONITOR_AUDIO_DIR=/opt/ai-monitor/audio
AI_MONITOR_LOG_DIR=/var/log/ai-monitor

AI_MONITOR_ZLM_URL=http://127.0.0.1:80
AI_MONITOR_ZLM_SECRET=your_secret
AI_MONITOR_INFER_URL=http://127.0.0.1:8080
AI_MONITOR_PY_URL=http://127.0.0.1:9500
AI_MONITOR_GO_ADDR=0.0.0.0:8090
```

这样以后部署到不同机器时，主要改配置而不是改服务文件。

---

## 十三、推荐的启动与停止方式

### 首次启用

```bash
systemctl daemon-reload
systemctl enable zlm.service
systemctl enable infer.service
systemctl enable ai-monitor-python.service
systemctl enable ai-monitor-backend.service
```

### 启动

```bash
systemctl start zlm.service
systemctl start infer.service
systemctl start ai-monitor-python.service
systemctl start ai-monitor-backend.service
```

### 停止

```bash
systemctl stop ai-monitor-backend.service
systemctl stop ai-monitor-python.service
systemctl stop infer.service
systemctl stop zlm.service
```

虽然 systemd 可以根据依赖自动处理，但安装、升级和排查阶段手工按顺序操作更容易定位问题。

---

## 十四、推荐的运维排查命令

### 查看状态

```bash
systemctl status zlm.service
systemctl status infer.service
systemctl status ai-monitor-python.service
systemctl status ai-monitor-backend.service
```

### 查看日志

```bash
journalctl -u zlm.service -n 100 --no-pager
journalctl -u infer.service -n 100 --no-pager
journalctl -u ai-monitor-python.service -n 100 --no-pager
journalctl -u ai-monitor-backend.service -n 100 --no-pager
```

### 实时追踪

```bash
journalctl -u ai-monitor-backend.service -f
```

### 开机自启检查

```bash
systemctl is-enabled zlm.service
systemctl is-enabled infer.service
systemctl is-enabled ai-monitor-python.service
systemctl is-enabled ai-monitor-backend.service
```

---

## 十五、推荐的健康检查顺序

服务启动后建议按以下顺序检查：

1. `zlm.service` 是否正常
2. 推理服务 HTTP 接口是否正常
3. Python `/api/health` 是否正常
4. Go `/api/health` 是否正常
5. 前端静态页面是否可访问

若某一层失败，优先看该层日志，不要直接跳到前端现象排查。

---

## 十六、升级时的服务操作建议

升级时不建议直接无脑重启全部服务，建议顺序如下：

1. 停止 Go 后端
2. 停止 Python 服务
3. 停止推理服务
4. 若 ZLM 未变更，可不停
5. 替换二进制和资源
6. 执行数据库迁移
7. 重新加载 `systemd`
8. 启动推理服务
9. 启动 Python 服务
10. 启动 Go 后端
11. 健康检查

如果 ZLM 本身版本也有变化，再额外停启 ZLM。

---

## 十七、当前项目里的特别注意事项

### 1. 前端不要继续作为独立开发服务运行

正式环境应构建成 `dist`，由 Go 后端托管。

### 2. `infer.service` 需要保留 `jemalloc`

你当前文档中已明确 RKNN 推理建议通过 `LD_PRELOAD` 加载 `jemalloc`，因此服务文件中应保留这一点。

### 3. 配置文件不要继续放在开发目录

例如：

- ZLM 配置
- infer server 配置
- Go / Python 运行配置

都应收敛到 `/etc/ai-monitor/`。

### 4. 路径不要继续依赖 `/home/hzhy`

开发目录结构可以保留用于研发，但生产运行路径建议统一迁移到：

- `/opt/ai-monitor`
- `/etc/ai-monitor`
- `/var/lib/ai-monitor`
- `/var/log/ai-monitor`

---

## 十八、最终目标

一套合格的 `systemd` 设计最终应达到这个效果：

- 机器上电后自动启动整套系统
- 任一服务异常退出后自动拉起
- 升级时能标准化停止、替换、启动
- 日志统一可查
- 现场人员只需要掌握少量 `systemctl` 和 `journalctl` 命令即可维护

这也是工业项目从“开发环境运行”走向“正式部署运行”的关键标志之一。

# `install.sh` 设计说明

> 本文档用于定义 AI 智能视频监控系统安装脚本 `install.sh` 的目标、职责、执行顺序和关键检查项。目标不是写一个“能跑一次”的临时脚本，而是写一个可以在同型号新机器上重复执行、稳定交付的标准安装脚本。

---

## 一、脚本目标

`install.sh` 的核心目标是：

- 在一台已刷好基础镜像的目标机器上，完成业务系统的标准安装
- 将发布包中的程序、配置、模型、前端、音频、数据库初始化文件部署到统一目录
- 安装并启用 `systemd` 服务
- 完成首次启动和健康检查

也就是说，基础镜像负责“系统环境”，`install.sh` 负责“应用上线”。

---

## 二、推荐目录约定

建议 `install.sh` 统一把内容安装到以下目录：

- 程序目录：`/opt/ai-monitor/`
- 配置目录：`/etc/ai-monitor/`
- 数据目录：`/var/lib/ai-monitor/`
- 日志目录：`/var/log/ai-monitor/`

建议进一步拆分为：

```text
/opt/ai-monitor/
├── bin/
├── python/
├── frontend/
├── models/
├── audio/
├── scripts/
└── VERSION

/etc/ai-monitor/
├── app.env
├── zlm.ini
├── infer-server.json
├── backend.yaml
└── python.yaml

/var/lib/ai-monitor/
├── aimonitor.db
├── snapshots/
└── backup/

/var/log/ai-monitor/
├── backend/
├── python/
├── infer/
└── zlm/
```

---

## 三、`install.sh` 的职责边界

### 应该负责的事情

- 校验运行用户是否有权限
- 校验目标系统是否符合要求
- 校验基础依赖是否存在
- 创建标准目录
- 拷贝程序与资源文件
- 安装配置模板
- 初始化数据库
- 安装 `systemd` 单元文件
- 启用并启动服务
- 执行健康检查
- 输出安装结果和后续提示

### 不建议负责的事情

- 在线安装大量系统依赖
- 动态编译 C++ / Go / 前端
- 现场联网 `pip install`
- 现场联网 `npm install`
- 临时修改源码

原因很简单：安装脚本应当尽量只做“部署”，而不是承担“构建环境”和“开发调试”的职责。

---

## 四、建议的执行顺序

一个稳妥的 `install.sh` 通常按以下顺序执行。

### 第 1 步：基本信息与参数解析

建议支持以下参数：

- `--prefix`：自定义安装根目录，默认 `/opt/ai-monitor`
- `--config-dir`：默认 `/etc/ai-monitor`
- `--data-dir`：默认 `/var/lib/ai-monitor`
- `--log-dir`：默认 `/var/log/ai-monitor`
- `--init-db`：是否初始化数据库
- `--force`：覆盖已存在文件
- `--skip-start`：安装后不立即启动服务
- `--offline`：明确表示离线部署

同时输出：

- 当前版本号
- 当前目标目录
- 当前运行用户

---

## 五、详细执行步骤

### 1. 检查 root 权限

如果脚本需要写入：

- `/opt`
- `/etc`
- `/var/lib`
- `/var/log`
- `/etc/systemd/system`

那通常需要 root 权限或 sudo 执行。

建议脚本开头直接检查：

```bash
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行 install.sh"
  exit 1
fi
```

### 2. 检查系统与架构

至少检查：

- 是否为 Linux
- 是否为 `aarch64`
- 是否为预期的 RK 平台

可以检查：

- `uname -m`
- `uname -r`
- `/proc/device-tree/`
- 关键设备节点是否存在

例如：

- `/dev/mpp_service`

如果系统平台不对，应立即退出，而不是继续安装。

### 3. 检查基础依赖是否已存在

这一步非常关键，因为你的系统依赖重，安装脚本必须尽快告诉用户“基础镜像是否合格”。

建议至少检查：

- `/opt/ffmpeg-rk/bin/ffmpeg`
- `MediaServer` 是否存在
- `/usr/lib/librknnrt.so`
- `/usr/include/rknn_api.h` 是否存在或运行时库是否存在
- `libjemalloc.so.2`
- Java 是否可执行
- `sqlite3` 是否存在
- 关键目录是否存在

对于每一项，建议输出：

- `OK`
- `MISSING`
- `WARN`

如果关键依赖缺失，应明确退出，并提示“请先刷基础镜像或补齐基础依赖”。

### 4. 创建目录结构

建议由安装脚本统一创建：

- `/opt/ai-monitor/`
- `/opt/ai-monitor/bin/`
- `/opt/ai-monitor/python/`
- `/opt/ai-monitor/frontend/`
- `/opt/ai-monitor/models/`
- `/opt/ai-monitor/audio/`
- `/opt/ai-monitor/scripts/`
- `/etc/ai-monitor/`
- `/var/lib/ai-monitor/`
- `/var/lib/ai-monitor/snapshots/`
- `/var/lib/ai-monitor/backup/`
- `/var/log/ai-monitor/`

并统一设置权限。

如果后续准备引入专用运行用户，例如 `ai-monitor`，这里还应设置：

- 所有者
- 组权限
- 可写目录权限

### 5. 备份旧版本

如果检测到已安装旧版本，建议先备份：

- 旧二进制
- 旧配置
- 旧数据库
- 旧模型
- 旧音频

可以按时间戳放到：

- `/var/lib/ai-monitor/backup/YYYYMMDD-HHMMSS/`

这一步是后续升级和回滚的基础。

### 6. 拷贝发布包内容

将发布包中的内容拷贝到标准目录。

典型包括：

- `bin/ai-monitor-backend` -> `/opt/ai-monitor/bin/`
- `bin/infer_server` -> `/opt/ai-monitor/bin/`
- `python/app/` -> `/opt/ai-monitor/python/app/`
- `python/venv/` -> `/opt/ai-monitor/python/venv/`
- `frontend/dist/` -> `/opt/ai-monitor/frontend/dist/`
- `models/` -> `/opt/ai-monitor/models/`
- `audio/` -> `/opt/ai-monitor/audio/`
- `scripts/` -> `/opt/ai-monitor/scripts/`
- `VERSION` -> `/opt/ai-monitor/VERSION`

这里建议：

- 二进制文件赋予执行权限
- 脚本文件赋予执行权限
- 静态资源保留只读

### 7. 安装配置文件

配置文件建议采用“模板首次安装，升级默认不覆盖”的策略。

例如：

- 若目标文件不存在，则复制模板
- 若目标文件已存在，则保留原配置，并把新模板保存为 `.new`

比如：

- `/etc/ai-monitor/app.env`
- `/etc/ai-monitor/zlm.ini`
- `/etc/ai-monitor/infer-server.json`

这样可以避免升级时把现场配置覆盖掉。

### 8. 初始化数据库

数据库部分建议分情况处理。

#### 首次安装

若 `/var/lib/ai-monitor/aimonitor.db` 不存在，则：

1. 创建数据库文件
2. 执行 `schema.sql`
3. 执行 `seed.sql`
4. 可选导入现场初始化配置

#### 非首次安装

若数据库已存在，则：

- 不要直接覆盖
- 只提示“已存在数据库，跳过初始化”

如果后续引入数据库迁移，则应在升级脚本中执行迁移，而不是在安装脚本中盲目重建。

### 9. 安装 systemd 单元文件

从发布包复制以下文件到：

- `/etc/systemd/system/zlm.service`
- `/etc/systemd/system/infer.service`
- `/etc/systemd/system/ai-monitor-python.service`
- `/etc/systemd/system/ai-monitor-backend.service`

然后执行：

```bash
systemctl daemon-reload
```

并根据需要启用：

```bash
systemctl enable zlm.service
systemctl enable infer.service
systemctl enable ai-monitor-python.service
systemctl enable ai-monitor-backend.service
```

### 10. 启动服务

建议按顺序启动：

1. `zlm.service`
2. `infer.service`
3. `ai-monitor-python.service`
4. `ai-monitor-backend.service`

如果使用了正确的 `systemd` 依赖关系，也可以只启动最后一个服务，让 systemd 自动拉起依赖，但在安装阶段显式按顺序启动通常更直观。

### 11. 执行健康检查

健康检查是安装脚本的重要组成部分，不能只看“服务启动命令没报错”。

建议检查：

- `systemctl is-active zlm.service`
- `systemctl is-active infer.service`
- `systemctl is-active ai-monitor-python.service`
- `systemctl is-active ai-monitor-backend.service`
- `http://127.0.0.1:8080/...` 是否可访问
- `http://127.0.0.1:9500/api/health`
- `http://127.0.0.1:8090/api/health`
- 前端静态文件是否存在
- 数据库文件是否存在

必要时还可以增加：

- ZMQ 端口监听检查
- 关键目录权限检查

### 12. 输出安装摘要

安装完成后建议统一输出：

- 安装版本
- 安装路径
- 配置目录
- 数据目录
- 数据库文件路径
- 服务状态
- 常用排查命令

例如：

```bash
systemctl status ai-monitor-backend.service
journalctl -u ai-monitor-python.service -n 100 --no-pager
```

---

## 六、推荐的失败处理策略

`install.sh` 不应在失败时继续“硬着头皮往下跑”，建议采用严格模式：

```bash
set -euo pipefail
```

同时建议增加：

- 明确的错误提示
- 已完成步骤记录
- 失败步骤定位

例如：

- 依赖缺失时立即退出
- 文件复制失败时立即退出
- `systemd` 启动失败时打印日志查看提示

如果安装过程会修改很多内容，还应在失败时保留备份，便于人工回退。

---

## 七、脚本设计建议

建议脚本内部按函数拆分，例如：

```bash
check_root
check_platform
check_base_dependencies
create_directories
backup_existing_installation
install_binaries
install_python_app
install_frontend
install_models
install_audio
install_configs
init_database
install_systemd_units
start_services
run_health_checks
print_summary
```

这样比把所有命令堆在一个大脚本里更容易维护。

---

## 八、与 `upgrade.sh` 的分工

为了避免一个脚本承担太多职责，建议这样划分：

### `install.sh`

面向：

- 首次安装
- 空机器部署
- 初始目录创建
- 初始数据库建立

### `upgrade.sh`

面向：

- 已安装机器升级
- 替换二进制和资源文件
- 配置兼容处理
- 数据库迁移
- 服务重启与回滚

不要把“首次安装”和“版本升级”混成一个脚本，否则逻辑会越来越复杂。

---

## 九、对当前项目的特别建议

结合本项目现状，`install.sh` 需要特别注意下面几点。

### 1. 不要在安装脚本里在线编译 `ffmpeg-rk`

`ffmpeg-rk` 属于基础环境内容，应在基础镜像阶段就准备好，而不是安装应用时临时编译。

### 2. 不要在现场执行 `npm run dev`

前端正式部署应使用 `dist`，由 Go 后端托管。

### 3. 不要在现场 `pip install` 生产依赖

应提前准备：

- Python 虚拟环境
或
- 离线 wheel 包

### 4. 不要直接覆盖 SQLite 数据库

数据库必须区分：

- 初始化
- 升级
- 现场数据保留

### 5. 不要把 `/home/hzhy/...` 当成产品路径

正式安装应收敛到：

- `/opt/ai-monitor`
- `/etc/ai-monitor`
- `/var/lib/ai-monitor`
- `/var/log/ai-monitor`

---

## 十、最终目标

一个合格的 `install.sh` 最终应满足下面这个标准：

**在一台同型号、已刷基础镜像的新机器上，只需拷贝发布包并执行一次 `sudo ./install.sh`，就可以完成完整安装、服务拉起和健康检查。**

这就是从“开发环境”迈向“可复制交付”的关键一步。

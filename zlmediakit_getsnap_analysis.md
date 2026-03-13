# ZLMediaKit getSnap 返回 Logo 而非摄像头截图 - 问题分析报告

## 问题描述

使用 ZLMediaKit 的 `getSnap` API 从 RTSP 流截取图片时，**无论传递什么 URL 参数，返回的都是 ZLMediaKit 的 Logo 图片**（1024x512 PNG，大小 47255 字节），而非实际的摄像头画面。

## 发现问题

### 1. 配置检查发现关键线索

通过查询 ZLMediaKit 服务器配置，发现以下关键配置项：

```json
{
    "api.defaultSnap": "./www/logo.png",
    "api.snapRoot": "./www/snap/",
    "ffmpeg.snap": "%s -i %s -y -f mjpeg -frames:v 1 -an %s"
}
```

这表明：
- `api.defaultSnap` 被设置为 `./www/logo.png`
- 当截图失败时，会返回这个默认的 logo 图片
- 截图存储根目录为 `./www/snap/`
- 使用 FFmpeg 命令模板进行截图

### 2. 实验验证

进行了大量测试，所有测试都返回相同的 logo 图片（MD5: `32ddfa5715059731ae893ec92fca0311`）：

| 测试 URL 参数 | 结果 |
|------------|------|
| `rtsp://admin:hifleet321@192.168.254.124:554/Streaming/Channels/102` | Logo |
| `http://127.0.0.1:80/live/cam2.live.flv` | Logo |
| `http://127.0.0.1:80/live/cam2/hls.m3u8` | Logo |
| `__defaultVhost__/live/cam2` | Logo |
| `rtsp://invalid:1234/test` (无效URL) | Logo |

**关键发现**：即使是完全无效的 RTSP URL，也返回相同的 logo 图片，而不是错误信息。

### 3. 流状态验证

验证目标流 `cam2` 确实在线且正常：

```bash
curl -s "http://127.0.0.1:80/index/api/isMediaOnline?secret=...&schema=rtsp&vhost=__defaultVhost__&app=live&stream=cam2"
```

返回：
```json
{
    "code": 0,
    "online": true
}
```

确认流确实在线，但 `getSnap` 仍然返回 logo。

### 4. 配置问题分析

从配置项 `ffmpeg.snap` 可以看出：
- ZLMediaKit 依赖 FFmpeg 来截取截图
- 命令模板为：`%s -i %s -y -f mjpeg -frames:v 1 -an %s`
- 这对应：`ffmpeg -i <url> -y -f mjpeg -frames:v 1 -an <output>`

**关键问题**：检查系统 FFmpeg 可用性：

```bash
which ffmpeg
# 返回空，系统中没有 ffmpeg

ls -la /opt/ffmpeg-rk/
# 只有 lib、include 等开发文件，没有 ffmpeg 可执行文件
```

## 问题根因

**`getSnap` API 返回 Logo 而不是实际截图的根本原因是：系统中没有可用的 FFmpeg 可执行文件。**

ZLMediaKit 的 `getSnap` 功能依赖 FFmpeg 来截取视频帧。当 FFmpeg 不可用时：

1. ZLMediaKit 尝试调用 FFmpeg 命令截图
2. 命令执行失败（找不到 ffmpeg）
3. ZLMediaKit 返回配置项 `api.defaultSnap` 中指定的默认图片（logo.png）

这就是为什么无论传递什么 URL，都返回相同的 logo 图片。

## 解决方案


### 配置 ZLMediaKit 使用自定义 FFmpeg 路径

如果 FFmpeg 安装在非标准路径，可以修改 ZLMediaKit 配置：

1. 编辑 `config.ini`
2. 修改 `ffmpeg.bin` 配置项，指定完整路径：

```ini
[ffmpeg]
bin = /opt/ffmpeg-rk/bin/ffmpeg
```

## 验证修复

安装 FFmpeg 后，验证 `getSnap` 是否正常工作：

```bash
# 测试 getSnap API
curl -s "http://127.0.0.1:80/index/api/getSnap?secret=vEq3Z2BobQevk5dRs1zZ6DahIt5U9urT&url=rtsp://admin:hifleet321@192.168.254.124:554/Streaming/Channels/102&timeout_sec=5&expire_sec=1" -o /tmp/test_snap.jpg

# 检查文件类型
file /tmp/test_snap.jpg

# 如果显示 JPEG 且分辨率是 640x360，则修复成功
# 如果仍显示 PNG 1024x512，则问题未解决
```

## 总结

| 项目 | 内容 |
|-----|------|
| **问题** | ZLMediaKit `getSnap` API 返回 Logo 而非实际截图 |
| **根因** | 系统缺少 FFmpeg 可执行文件 |
| **机制** | ZLMediaKit 使用 FFmpeg 截图，失败时返回 `api.defaultSnap` 配置的默认图片 |
| **解决** | 安装 FFmpeg 或配置正确的 FFmpeg 路径 |



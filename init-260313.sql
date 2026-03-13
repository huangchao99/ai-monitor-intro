CREATE TABLE cameras (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,                  -- 摄像头名称 (如: cam01)
    rtsp_url TEXT NOT NULL,              -- RTSP流地址
    location TEXT,                       -- 安装地点 (如: 临港办公室)
    status INTEGER DEFAULT 1 CHECK(status IN (0,1))  -- 1: 在线, 0: 离线
);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE algorithms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    algo_key TEXT UNIQUE,                -- 算法标识 (如: phone_detect, sleep_detect)
    algo_name TEXT NOT NULL,             -- 算法显示名 (如: 玩手机, 闭眼)
    category TEXT                        -- 算法分类 (如: 行为分析, 消防检测)
, param_definition TEXT);
CREATE TABLE tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_name TEXT NOT NULL,             -- 任务名称
    camera_id INTEGER NOT NULL,          -- 关联摄像头
    alarm_device_id TEXT,                -- 告警音柱配置 (存储ID或配置)
    status INTEGER DEFAULT 0 CHECK(status IN (0,1,2)), -- 0:停止, 1:运行中, 2:异常
    error_msg TEXT,                      -- 错误信息 (如: 拉流失败)
    remark TEXT,                         -- 备注
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (camera_id) REFERENCES cameras(id)
);
CREATE TABLE task_algo_details (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,                     -- 关联任务
    algo_id INTEGER,                     -- 关联算法
    roi_config TEXT,                     -- JSON: 识别区域坐标 [[x,y],[x,y]...]
    algo_params TEXT,                    -- JSON: 闭眼时长、置信度等特定参数
    alarm_config TEXT,                   -- JSON: 告警间隔、时间段等
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (algo_id) REFERENCES algorithms(id),
    UNIQUE(task_id, algo_id)
);
CREATE TABLE alarms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,                     -- 关联任务
    algo_name TEXT,                      -- 报警算法名 (冗余存储，方便查询)
    alarm_time DATETIME DEFAULT CURRENT_TIMESTAMP, -- 报警时间
    alarm_location TEXT,                 -- 报警地点 (通常取摄像头的location)
    image_url TEXT,                      -- 抓拍图路径 (如: /uploads/2024/02/27/abc.jpg)
    status INTEGER DEFAULT 0 CHECK(status IN (0,1)),  -- 处理状态: 0:未处理, 1:已处理
    alarm_details TEXT, task_name TEXT NOT NULL DEFAULT '', camera_name TEXT NOT NULL DEFAULT '',                  -- JSON: 存储识别时的具体信息 (如置信度、目标框坐标)
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);
CREATE INDEX idx_alarms_time ON alarms(alarm_time DESC);
CREATE INDEX idx_alarms_task_id ON alarms(task_id);
CREATE INDEX idx_alarms_status ON alarms(status);
CREATE TABLE zlm_streams (
                        id         INTEGER PRIMARY KEY AUTOINCREMENT,
                        camera_id  INTEGER NOT NULL UNIQUE,
                        app        TEXT    NOT NULL DEFAULT 'live',
                        stream_key TEXT    NOT NULL,
                        proxy_key  TEXT    DEFAULT '',
                        status     INTEGER DEFAULT 0,
                        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                        FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
                );
CREATE TABLE models (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model_name TEXT NOT NULL,           -- 模型名称 (如: YOLOv5s_Person)
    model_path TEXT NOT NULL,           -- .rknn 文件路径
    labels_path TEXT,                   -- .names 标签文件路径
    model_type TEXT DEFAULT 'yolov5',    -- 模型架构 (yolov5, yolov8, landmark等)
    input_width INTEGER DEFAULT 640,    -- 推理输入宽
    input_height INTEGER DEFAULT 640,   -- 推理输入高
    conf_threshold REAL DEFAULT 0.25,   -- 默认置信度阈值
    nms_threshold REAL DEFAULT 0.45    -- 默认NMS阈值
);
CREATE TABLE algo_model_map (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    algo_id INTEGER,                    -- 关联 algorithms 表
    model_id INTEGER,                     -- 任务名 (如 person_detection)
    FOREIGN KEY (algo_id) REFERENCES algorithms(id),
    FOREIGN KEY (model_id) REFERENCES models(id)
);
CREATE TABLE system_settings (
                        key   TEXT PRIMARY KEY,
                        value TEXT NOT NULL DEFAULT ''
                );
CREATE TABLE voice_alarm_algo_map (
                        algo_id    INTEGER PRIMARY KEY,
                        audio_file TEXT NOT NULL,
                        FOREIGN KEY (algo_id) REFERENCES algorithms(id) ON DELETE CASCADE
                );
CREATE TABLE alarm_upload_queue (
                        id          INTEGER PRIMARY KEY AUTOINCREMENT,
                        alarm_id    INTEGER NOT NULL UNIQUE,
                        status      INTEGER DEFAULT 0,
                        retry_count INTEGER DEFAULT 0,
                        last_error  TEXT    DEFAULT '',
                        created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
                        updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
                        FOREIGN KEY (alarm_id) REFERENCES alarms(id) ON DELETE CASCADE
                );


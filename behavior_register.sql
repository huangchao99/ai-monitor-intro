-- ============================================================
-- 行为检测算法注册脚本：打电话 / 玩手机 / 抽烟
-- 同时清理旧的 smoking / play_phone 测试数据
-- 执行方式：sqlite3 /home/hzhy/aimonitor.db < /home/hzhy/behavior_register.sql
-- ============================================================

PRAGMA foreign_keys = ON;

-- 1. 清理旧的测试算法（CASCADE 会自动删除 task_algo_details 和 algo_model_map 关联行）
DELETE FROM algo_model_map WHERE algo_id IN (
    SELECT id FROM algorithms WHERE algo_key IN ('smoking', 'play_phone')
);
DELETE FROM task_algo_details WHERE algo_id IN (
    SELECT id FROM algorithms WHERE algo_key IN ('smoking', 'play_phone')
);
DELETE FROM algorithms WHERE algo_key IN ('smoking', 'play_phone');

-- 2. 注册新模型（YOLO11n 行为检测）
INSERT OR IGNORE INTO models (model_name, model_path, labels_path, model_type, input_width, input_height, conf_threshold, nms_threshold)
VALUES (
    'Behavior-YOLOv11n',
    '/home/hzhy/models/aimonitor_yolov11n_0323_rknn_model/aimonitor04-yolov11n-0323-rk3576.rknn',
    '/home/hzhy/models/aimonitor_yolov11n_0323_rknn_model/label.txt',
    'yolov11',
    640,
    640,
    0.25,
    0.45
);

-- 3. 注册三个新算法
INSERT OR IGNORE INTO algorithms (algo_key, algo_name, category, param_definition) VALUES (
    'call',
    '打电话',
    '行为分析',
    '[
      {"key": "skip_frame",  "label": "跳帧频率",        "type": "number", "default": 5,    "min": 1, "max": 100},
      {"key": "confidence",  "label": "置信度",           "type": "slider", "default": 0.35, "min": 0, "max": 1, "step": 0.01},
      {"key": "duration",    "label": "持续检测时长(秒)", "type": "number", "default": 30,   "min": 3, "max": 600}
    ]'
);

INSERT OR IGNORE INTO algorithms (algo_key, algo_name, category, param_definition) VALUES (
    'phone',
    '玩手机',
    '行为分析',
    '[
      {"key": "skip_frame",  "label": "跳帧频率",        "type": "number", "default": 5,    "min": 1, "max": 100},
      {"key": "confidence",  "label": "置信度",           "type": "slider", "default": 0.35, "min": 0, "max": 1, "step": 0.01},
      {"key": "duration",    "label": "持续检测时长(秒)", "type": "number", "default": 30,   "min": 3, "max": 600}
    ]'
);

INSERT OR IGNORE INTO algorithms (algo_key, algo_name, category, param_definition) VALUES (
    'smoke',
    '抽烟',
    '行为分析',
    '[
      {"key": "skip_frame",  "label": "跳帧频率",        "type": "number", "default": 5,    "min": 1, "max": 100},
      {"key": "confidence",  "label": "置信度",           "type": "slider", "default": 0.35, "min": 0, "max": 1, "step": 0.01},
      {"key": "duration",    "label": "持续检测时长(秒)", "type": "number", "default": 30,   "min": 3, "max": 600}
    ]'
);

-- 4. 建立 algo_model_map 关联
INSERT OR IGNORE INTO algo_model_map (algo_id, model_id)
SELECT a.id, m.id FROM algorithms a, models m
WHERE a.algo_key = 'call' AND m.model_name = 'Behavior-YOLOv11n';

INSERT OR IGNORE INTO algo_model_map (algo_id, model_id)
SELECT a.id, m.id FROM algorithms a, models m
WHERE a.algo_key = 'phone' AND m.model_name = 'Behavior-YOLOv11n';

INSERT OR IGNORE INTO algo_model_map (algo_id, model_id)
SELECT a.id, m.id FROM algorithms a, models m
WHERE a.algo_key = 'smoke' AND m.model_name = 'Behavior-YOLOv11n';

-- 验证结果
SELECT '=== algorithms (行为分析) ===' AS info;
SELECT id, algo_key, algo_name, category FROM algorithms WHERE category = '行为分析';

SELECT '=== models ===' AS info;
SELECT id, model_name, model_type FROM models;

SELECT '=== algo_model_map (Behavior) ===' AS info;
SELECT amm.id, a.algo_key, m.model_name
FROM algo_model_map amm
JOIN algorithms a ON amm.algo_id = a.id
JOIN models m ON amm.model_id = m.id
WHERE m.model_name = 'Behavior-YOLOv11n';

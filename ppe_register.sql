-- ============================================================
-- PPE 安全合规检测 —— 模型与算法注册脚本
-- 包含：未戴安全帽 / 未戴口罩 / 未穿救生衣（安全背心）
-- 执行方式：sqlite3 /home/hzhy/aimonitor.db < /home/hzhy/ppe_register.sql
-- ============================================================

PRAGMA foreign_keys = ON;

-- 1. 注册 PPE YOLOv8n 模型
INSERT OR IGNORE INTO models (model_name, model_path, labels_path, model_type, input_width, input_height, conf_threshold, nms_threshold)
VALUES (
    'PPE-YOLOv8n',
    '/home/hzhy/models/ppe-yolov8n_rknn_model/ppe-yolov8n-rk3576.rknn',
    '/home/hzhy/models/ppe-yolov8n_rknn_model/ppe-yolov8n-rk3576.txt',
    'yolov8',
    640,
    640,
    0.25,
    0.45
);

-- 2. 注册三个算法（含前端参数元数据 param_definition）
INSERT OR IGNORE INTO algorithms (algo_key, algo_name, category, param_definition) VALUES (
    'no_hardhat',
    '未戴安全帽',
    '安全合规',
    '[
      {"key": "skip_frame",  "label": "跳帧频率",          "type": "number", "default": 5,    "min": 1, "max": 100},
      {"key": "confidence",  "label": "置信度",             "type": "slider", "default": 0.35, "min": 0, "max": 1, "step": 0.01},
      {"key": "duration",    "label": "持续检测时长(秒)",   "type": "number", "default": 10,   "min": 3, "max": 600}
    ]'
);

INSERT OR IGNORE INTO algorithms (algo_key, algo_name, category, param_definition) VALUES (
    'no_mask',
    '未戴口罩',
    '安全合规',
    '[
      {"key": "skip_frame",  "label": "跳帧频率",          "type": "number", "default": 5,    "min": 1, "max": 100},
      {"key": "confidence",  "label": "置信度",             "type": "slider", "default": 0.35, "min": 0, "max": 1, "step": 0.01},
      {"key": "duration",    "label": "持续检测时长(秒)",   "type": "number", "default": 10,   "min": 3, "max": 600}
    ]'
);

INSERT OR IGNORE INTO algorithms (algo_key, algo_name, category, param_definition) VALUES (
    'no_safety_vest',
    '未穿救生衣',
    '安全合规',
    '[
      {"key": "skip_frame",  "label": "跳帧频率",          "type": "number", "default": 5,    "min": 1, "max": 100},
      {"key": "confidence",  "label": "置信度",             "type": "slider", "default": 0.35, "min": 0, "max": 1, "step": 0.01},
      {"key": "duration",    "label": "持续检测时长(秒)",   "type": "number", "default": 10,   "min": 3, "max": 600}
    ]'
);

-- 3. 建立 algo_model_map 关联（算法 → PPE 模型）
-- 使用子查询，不依赖硬编码 ID
INSERT OR IGNORE INTO algo_model_map (algo_id, model_id)
SELECT a.id, m.id
FROM algorithms a, models m
WHERE a.algo_key = 'no_hardhat' AND m.model_name = 'PPE-YOLOv8n';

INSERT OR IGNORE INTO algo_model_map (algo_id, model_id)
SELECT a.id, m.id
FROM algorithms a, models m
WHERE a.algo_key = 'no_mask' AND m.model_name = 'PPE-YOLOv8n';

INSERT OR IGNORE INTO algo_model_map (algo_id, model_id)
SELECT a.id, m.id
FROM algorithms a, models m
WHERE a.algo_key = 'no_safety_vest' AND m.model_name = 'PPE-YOLOv8n';

-- 验证结果
SELECT '=== models ===' AS info;
SELECT id, model_name, model_type, conf_threshold FROM models;

SELECT '=== algorithms (PPE) ===' AS info;
SELECT id, algo_key, algo_name, category FROM algorithms WHERE category = '安全合规';

SELECT '=== algo_model_map (PPE) ===' AS info;
SELECT amm.id, a.algo_key, m.model_name
FROM algo_model_map amm
JOIN algorithms a ON amm.algo_id = a.id
JOIN models m ON amm.model_id = m.id
WHERE m.model_name = 'PPE-YOLOv8n';

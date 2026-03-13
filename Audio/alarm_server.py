import json
import http.server
import socketserver
import subprocess
import threading
import logging
import queue
from urllib.parse import urlparse
import time
import sys
import socket

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class ReuseAddressTCPServer(socketserver.TCPServer):
    """支持地址重用的TCP服务器"""
    allow_reuse_address = True

class AlarmScheduler:
    """报警调度器 - 串行队列处理报警"""
    
    def __init__(self):
        self.alarm_queue = queue.Queue()  # 报警队列
        self.current_alarm = None  # 当前正在处理的报警
        self.is_processing = False  # 是否正在处理报警
        self.worker_thread = None  # 工作线程
        self.is_running = False  # 调度器运行状态
        self.alarm_count = 0  # 处理的报警总数
        self.process_lock = threading.Lock()  # 处理锁
        
    def add_alarm(self, recog_type):
        """添加报警到队列"""
        try:
            self.alarm_queue.put(recog_type)
            queue_size = self.alarm_queue.qsize()
            logger.info(f"报警添加到队列: {recog_type}, 队列长度: {queue_size}")
            return True, queue_size
        except Exception as e:
            logger.error(f"添加报警到队列失败: {e}")
            return False, 0
    
    def start(self):
        """启动调度器"""
        if self.is_running:
            logger.warning("调度器已经在运行")
            return
        
        self.is_running = True
        self.worker_thread = threading.Thread(target=self._process_queue)
        self.worker_thread.daemon = True
        self.worker_thread.start()
        logger.info("报警调度器已启动")
    
    def stop(self):
        """停止调度器"""
        self.is_running = False
        if self.worker_thread:
            self.worker_thread.join(timeout=5)
            logger.info("报警调度器已停止")
    
    def _process_queue(self):
        """处理队列中的报警"""
        while self.is_running:
            try:
                # 从队列获取报警（阻塞等待，超时1秒检查运行状态）
                recog_type = self.alarm_queue.get(timeout=1)
                
                with self.process_lock:
                    self.current_alarm = recog_type
                    self.is_processing = True
                
                try:
                    # 执行报警命令
                    logger.info(f"开始处理报警: {recog_type}")
                    self._execute_alarm_command(recog_type)
                    logger.info(f"报警处理完成: {recog_type}")
                finally:
                    with self.process_lock:
                        self.current_alarm = None
                        self.is_processing = False
                    
                    # 标记任务完成
                    self.alarm_queue.task_done()
                    self.alarm_count += 1
                    
            except queue.Empty:
                # 队列为空，继续循环
                continue
            except Exception as e:
                logger.error(f"处理报警队列时发生错误: {e}")
                continue
    
    def _execute_alarm_command(self, recog_type):
        """执行Java报警命令"""
        try:
            # 构建命令 - 直接使用RecogType作为参数
            command = f"java -jar arm64LinuxAll.jar {recog_type}"
            logger.info(f"执行命令: {command}")
            
            # 执行命令
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=30  # 30秒超时
            )
            
            # 记录命令执行结果
            if result.returncode == 0:
                logger.info(f"报警命令执行成功: {recog_type}")
                if result.stdout.strip():
                    logger.debug(f"命令输出: {result.stdout}")
            else:
                logger.error(f"报警命令执行失败: {recog_type}")
                if result.stderr.strip():
                    logger.error(f"错误输出: {result.stderr}")
                
        except subprocess.TimeoutExpired:
            logger.error(f"报警命令执行超时: {recog_type}")
        except FileNotFoundError:
            logger.error(f"Java或jar文件未找到，请确保Java已安装且jar文件存在")
        except Exception as e:
            logger.error(f"执行报警命令时发生错误: {e}")
    
    def get_status(self):
        """获取调度器状态"""
        with self.process_lock:
            status = {
                "running": self.is_running,
                "current_alarm": self.current_alarm,
                "is_processing": self.is_processing,
                "queue_size": self.alarm_queue.qsize(),
                "total_processed": self.alarm_count
            }
        return status

# 创建全局调度器实例，用于在测试模式下传递
_global_scheduler = None

def make_handler_class(scheduler):
    """创建带有调度器的Handler类工厂函数"""
    class AlarmHTTPHandler(http.server.BaseHTTPRequestHandler):
        """HTTP请求处理器"""
        
        def __init__(self, *args, **kwargs):
            self.scheduler = scheduler
            super().__init__(*args, **kwargs)
        
        def _send_response(self, status_code, message, extra_data=None):
            """发送HTTP响应"""
            self.send_response(status_code)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {"status": "success" if status_code == 200 else "error", "message": message}
            if extra_data:
                response.update(extra_data)
            self.wfile.write(json.dumps(response).encode('utf-8'))
        
        def _parse_json_from_body(self):
            """从请求体解析JSON数据"""
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                return None
            
            try:
                body = self.rfile.read(content_length)
                json_data = json.loads(body.decode('utf-8'))
                return json_data
            except json.JSONDecodeError as e:
                logger.error(f"JSON解析错误: {e}")
                return None
            except Exception as e:
                logger.error(f"请求体读取错误: {e}")
                return None
        
        def do_POST(self):
            """处理POST请求"""
            try:
                # 解析路径和查询参数
                parsed_path = urlparse(self.path)
                
                # 检查是否是报警端点
                if parsed_path.path != '/alarm':
                    self._send_response(404, "Endpoint not found")
                    return
                
                # 解析JSON数据
                json_data = self._parse_json_from_body()
                if json_data is None:
                    self._send_response(400, "Invalid JSON data")
                    return
                
                # 检查RecogType字段
                if 'RecogType' not in json_data:
                    self._send_response(400, "Missing 'RecogType' field")
                    return
                
                recog_type = json_data['RecogType']
                logger.info(f"接收到报警请求: RecogType={recog_type}")
                
                # 检查调度器是否存在
                if not self.scheduler:
                    logger.error("调度器未初始化")
                    self._send_response(500, "Alarm scheduler not initialized")
                    return
                
                # 添加报警到队列
                success, queue_size = self.scheduler.add_alarm(recog_type)
                
                if success:
                    status = self.scheduler.get_status()
                    queue_position = queue_size
                    if status['is_processing']:
                        queue_position += 1  # 如果正在处理，当前位置要+1
                    
                    extra_data = {
                        "recog_type": recog_type,
                        "queue_position": queue_position,
                        "queue_size": queue_size,
                        "current_alarm": status['current_alarm']
                    }
                    
                    message = f"报警已加入队列，当前位置: {queue_position}"
                    if status['is_processing']:
                        message += f" (当前正在处理: {status['current_alarm']})"
                    
                    self._send_response(200, message, extra_data)
                else:
                    self._send_response(500, "Failed to add alarm to queue")
                
            except Exception as e:
                logger.error(f"处理请求时发生错误: {e}")
                self._send_response(500, f"Internal server error: {str(e)}")
        
        def do_GET(self):
            """处理GET请求（用于健康检查）"""
            parsed_path = urlparse(self.path)
            
            if parsed_path.path == '/health':
                self._send_response(200, "Alarm server is running")
            elif parsed_path.path == '/status':
                # 返回服务器状态信息
                status_info = {
                    "status": "running",
                    "description": "HTTP语音报警服务器",
                    "usage": "直接使用JSON中的RecogType字段作为参数传递给Java程序",
                    "endpoint": "POST /alarm with JSON: {\"RecogType\": \"value\"}",
                    "timestamp": time.time()
                }
                
                # 添加调度器状态
                if self.scheduler:
                    scheduler_status = self.scheduler.get_status()
                    status_info["scheduler"] = scheduler_status
                
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(status_info).encode('utf-8'))
            elif parsed_path.path == '/queue':
                # 返回队列状态
                if not self.scheduler:
                    self._send_response(500, "Alarm scheduler not initialized")
                    return
                
                status = self.scheduler.get_status()
                queue_info = {
                    "queue_status": status,
                    "timestamp": time.time()
                }
                
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(queue_info).encode('utf-8'))
            else:
                self._send_response(404, "Endpoint not found")
        
        def log_message(self, format, *args):
            """重写日志消息格式"""
            logger.info(f"{self.address_string()} - {format % args}")
    
    return AlarmHTTPHandler

class AlarmHTTPServer:
    """HTTP语音报警服务器"""
    
    def __init__(self, host='0.0.0.0', port=8080):
        self.host = host
        self.port = port
        self.server = None
        self.scheduler = AlarmScheduler()  # 创建调度器实例
        # 更新全局调度器引用
        global _global_scheduler
        _global_scheduler = self.scheduler
    
    def start(self):
        """启动服务器"""
        try:
            # 启动报警调度器
            self.scheduler.start()
            
            # 创建自定义Handler类
            handler_class = make_handler_class(self.scheduler)
            
            # 创建服务器实例
            self.server = ReuseAddressTCPServer((self.host, self.port), handler_class)
            
            logger.info(f"语音报警服务器启动在 {self.host}:{self.port}")
            logger.info(f"健康检查: GET http://{self.host}:{self.port}/health")
            logger.info(f"状态查询: GET http://{self.host}:{self.port}/status")
            logger.info(f"队列查询: GET http://{self.host}:{self.port}/queue")
            logger.info(f"报警端点: POST http://{self.host}:{self.port}/alarm")
            logger.info("JSON格式: {\"RecogType\": \"报警类型\"}")
            logger.info("示例: {\"RecogType\": \"xy\"} -> java -jar arm64LinuxAll.jar xy")
            logger.info("示例: {\"RecogType\": \"fire\"} -> java -jar arm64LinuxAll.jar fire")
            logger.info("报警处理模式: 串行队列，按顺序依次处理")
            logger.info("等待客户端连接...")
            
            # 启动服务器
            self.server.serve_forever()
            
        except KeyboardInterrupt:
            logger.info("收到中断信号，正在关闭服务器...")
        except Exception as e:
            logger.error(f"启动服务器时发生错误: {e}")
        finally:
            self.stop()
    
    def stop(self):
        """停止服务器"""
        # 停止调度器
        self.scheduler.stop()
        
        # 停止服务器
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            logger.info("服务器已关闭")

def test_client_example():
    """测试客户端示例代码"""
    import requests
    import time
    
    # 测试数据 - 模拟快速连续报警
    test_cases = [
        {"RecogType": "xy", "description": "吸烟报警"},
        {"RecogType": "fire", "description": "火焰报警"},
        {"RecogType": "smoke", "description": "烟雾报警"},
        {"RecogType": "person", "description": "人员入侵报警"},
    ]
    
    base_url = "http://localhost:8080"
    
    print("测试HTTP语音报警服务器...")
    
    # 测试健康检查
    try:
        response = requests.get(f"{base_url}/health")
        print(f"健康检查: {response.status_code} - {response.json()}")
    except Exception as e:
        print(f"无法连接到服务器: {e}")
        return
    
    # 测试状态查询
    response = requests.get(f"{base_url}/status")
    print(f"状态查询: {response.status_code} - {response.json()}")
    
    # 测试队列状态
    response = requests.get(f"{base_url}/queue")
    print(f"队列状态: {response.status_code} - {response.json()}")
    
    # 测试快速连续报警请求
    print("\n测试快速连续报警（模拟报警间隔0.5秒）...")
    
    # 发送所有报警请求
    responses = []
    for test_case in test_cases:
        print(f"发送报警: {test_case['description']}")
        try:
            response = requests.post(
                f"{base_url}/alarm",
                json={"RecogType": test_case["RecogType"]},
                headers={"Content-Type": "application/json"},
                timeout=5
            )
            responses.append(response)
            print(f"  状态码: {response.status_code}")
            print(f"  响应: {response.json()}")
        except Exception as e:
            print(f"  请求失败: {e}")
        
        time.sleep(0.5)  # 快速连续报警，间隔0.5秒
    
    # 显示所有响应结果
    print("\n所有报警请求结果:")
    for i, response in enumerate(responses):
        print(f"报警{i+1}: {response.json()}")
    
    # 监控队列处理过程
    print("\n监控队列处理过程...")
    for i in range(15):  # 监控15秒
        try:
            response = requests.get(f"{base_url}/queue", timeout=5)
            if response.status_code == 200:
                data = response.json()
                status = data['queue_status']
                print(f"时间 {i}s: 当前报警={status['current_alarm']}, "
                      f"正在处理={status['is_processing']}, "
                      f"队列长度={status['queue_size']}, "
                      f"已处理总数={status['total_processed']}")
            else:
                print(f"时间 {i}s: 获取队列状态失败，状态码: {response.status_code}")
        except Exception as e:
            print(f"时间 {i}s: 查询队列状态失败: {e}")
        
        time.sleep(1)
    
    print("\n测试完成!")

def parse_arguments():
    """解析命令行参数"""
    import argparse
    
    parser = argparse.ArgumentParser(description='HTTP语音报警服务器')
    parser.add_argument('port', nargs='?', type=int, default=8080, 
                       help='服务器端口号 (默认: 8080)')
    parser.add_argument('host', nargs='?', default='0.0.0.0',
                       help='服务器主机地址 (默认: 0.0.0.0)')
    parser.add_argument('--test', action='store_true',
                       help='运行测试模式')
    
    return parser.parse_args()

if __name__ == "__main__":
    # 使用argparse解析命令行参数
    args = parse_arguments()
    
    # 启动服务器
    server = AlarmHTTPServer(host=args.host, port=args.port)
    
    # 如果是测试模式
    if args.test:
        print("启动测试客户端...")
        # 注意：这里需要先启动服务器，然后在另一个线程中运行测试
        import threading
        server_thread = threading.Thread(target=server.start)
        server_thread.daemon = True
        server_thread.start()
        
        # 等待服务器启动
        time.sleep(2)
        
        # 运行测试
        test_client_example()
    else:
        # 正常启动服务器
        server.start()
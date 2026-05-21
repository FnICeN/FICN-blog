+++
date = '2026-04-20T13:59:08+08:00'
draft = false
title = '基于AstrBot+米家实现自然语言控制夜灯设备'
tags = ["AstrBot","python","物联网","LLM"]
categories = ["小玩意"]
showToc = true
math = false
+++

## 准备

我自己有一台接入米家的夜灯，型号是[米家床头灯二代](https://home.miot-spec.com/spec?type=urn:miot-spec-v2:device:light:0000A001:yeelink-bslamp2:1)，官方已经给出了产品规格与各项控制参数

感谢Do1e开源的的[mijiaAPI](https://github.com/Do1e/mijia-api)，这个仓库向调用者提供了傻瓜式的米家电器控制调用接口，只需要调用相应方法、传入对应于设备控制意图的参数，即可通过云端控制米家设备

[AstrBot](https://astrbot.app/)部署于阿里云服务器，已经接入微信的ClawBot。为了插件开发方便，也在本地部署了AstrBot

## 环境配置

首先在AstrBot的根目录下安装依赖，官方提供了uv依赖管理：

```bash
cd AstrBot
uv sync
uv pip install mijiaAPI
```

AstrBot为插件开发者提供了[模板仓库](https://github.com/Soulter/helloworld)，只需使用此模板，然后克隆到本地的AstrBot插件文件夹即可开始开发

```bash
cd AstrBot/data/plugins
git clone <template-registry>
```

为了保证插件的正常运行，之后在插件开发调试中，Python环境都应使用外层目录的astrbot，而不应在插件目录新建环境

## 登录米家

mijiaAPI提供了便捷的登陆方式：

```python
import mijiaAPI from mijiaAPI
api = mijiaAPI("auth.json")
api.login()
```

执行login()时，程序会在终端打印登录二维码，使用登陆了米家账号的设备扫描后即可完成登录，此后程序不再阻塞，继续执行后面的脚本

不过，如果要将登录逻辑引入AstrBot机器人聊天环境存在一些问题：

- 登陆时的阻塞会导致机器人无法回复
- 登陆二维码在终端打印，需要某种方法将登陆手段以机器人回复的形式向用户呈现
- 在满足以上条件的基础上，还要维持原mijiaAPI中的轮询用户登录逻辑，并在用户扫码登录成功后使机器人回复“登陆成功”提示用户

关于阻塞问题的解决方案，我参考了已有的[在AstrBot中调用mijiaAPI的仓库](https://github.com/674537331/astrbot_plugin_mihome)，由[674537331](https://github.com/674537331)开发，核心思路是**创建一个独立的进程沙盒**，在沙盒中运行login()从而避免主进程被阻塞

在超时时间内每隔0.1秒不断读取进程的输出，如果读取到了二维码URL，则立即向用户回复该URL，回复后不结束登录流程，而是继续循环读取输出，直到超时或读取到登陆成功或失败

在子进程中执行登录的脚本_login_worker.py：

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
登录工作脚本，在子进程中执行登录流程
"""
import sys
import os
import time
from pathlib import Path
import logging

# 配置日志
logging.basicConfig(level=logging.INFO, encoding='utf-8')
logging.getLogger("mijiaAPI").setLevel(logging.INFO)

# 强制设置 stdout 编码为 UTF-8
if sys.stdout.encoding != 'utf-8':
    sys.stdout.reconfigure(encoding='utf-8')
if sys.stderr.encoding != 'utf-8':
    sys.stderr.reconfigure(encoding='utf-8')

from mijiaAPI import mijiaAPI


def main():
    if len(sys.argv) != 2:
        print("Usage: python _login_worker.py <auth_path>", flush=True)
        sys.exit(1)
    
    auth_path = Path(sys.argv[1])
    print("[WORKER] 开始初始化认证环境。", flush=True)
    
    try:
        # 确保目录存在
        auth_path.parent.mkdir(parents=True, exist_ok=True)
        
        api = mijiaAPI(auth_path)
        print("[WORKER] API 实例已创建，正在请求小米服务器...", flush=True)
        
        # 执行登录
        result = api.login()
        print("[WORKER] 登录成功", flush=True)
        print("[WORKER_SUCCESS] 授权完毕。", flush=True)
        
        sys.exit(0)
    except Exception as e:
        print(f"[WORKER_ERROR] 登录流程失败: {type(e).__name__}: {e}", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

------

主文件：

```python
@filter.command("登录")
async def login(self, event: AstrMessageEvent):
    """登录指令"""
    try:
        # 先发送一条消息，告知用户登录流程开始
        yield event.plain_result("正在启动登录流程，请稍候...")

        # 执行异步登录，不使用回调函数，而是直接获取二维码
        # 先检查是否已经登录
        if self.client.auth_path.exists():
            try:
                import json
                with open(self.client.auth_path, 'r', encoding='utf-8') as f:
                    auth_data = json.load(f)
                if auth_data.get('serviceToken'):
                    yield event.plain_result("Token有效，无需登录")
                    return
            except Exception:
                pass

        # 启动登录沙盒进程
        import subprocess
        import sys
        import time
        import re

        # 确保认证目录存在
        self.client.auth_path.parent.mkdir(parents=True, exist_ok=True)

        # 启动登录工作进程
        proc = subprocess.Popen(
            [sys.executable, "-u", "_login_worker.py", str(self.client.auth_path)],
            cwd=os.path.dirname(__file__),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8'
        )

        qr_found = False
        qr_url = ""
        start_time = time.time()
        timeout = 60  # 60秒超时

        # 读取进程输出，寻找二维码URL
        while time.time() - start_time < timeout:
            line = proc.stdout.readline()
            if not line:
                break

            logger.debug(f"[Login Worker] {line.strip()}")

            # 提取二维码URL
            if not qr_found:
                match = re.search(r'(https://account\.xiaomi\.com/pass/qr/login\?[^\s\'\"]+)', line)
                if match:
                    qr_url = match.group(1).strip()
                    qr_found = True
                    yield event.plain_result(f"请使用米家APP扫描以下二维码登录：\n{qr_url}")

            # 检查登录是否成功
            if "[WORKER_SUCCESS]" in line:
                yield event.plain_result("登录成功")
                proc.terminate()
                return

            # 检查登录是否失败
            if "[WORKER_ERROR]" in line:
                yield event.plain_result(f"登录失败: {line}")
                proc.terminate()
                return

            time.sleep(0.1)

        # 超时处理
        if not qr_found:
            yield event.plain_result("无法获取二维码，请检查网络")
        else:
            yield event.plain_result("登录超时，请重试")

        proc.terminate()

    except Exception as e:
        logger.error("登录失败: " + str(e))
        yield event.plain_result("登录失败: " + str(e))
```

## 夜灯控制

夜灯的控制逻辑很简单，为LLM注册一个工具Tool，提供参数与参数说明之后调用api.set_devices_prop()或api.run_action()即可，这里我多封装了一层client，实现原理不变

```python
@filter.llm_tool(name="light_power_control")
async def operate_light(self, event: AstrMessageEvent, on: bool):
    '''控制夜灯

    Args:
        on(bool): 是否开灯，True为开灯，False为关灯
    '''
    result = self.client.set_device_property(
        did="<my-did>",
        siid=2,
        piid=1,
        value=on
    )
    # 直接返回结果，让模型接收到工具调用的结果
    return f"夜灯控制结果: {result}"
```

注意这里要用return而不是yield，前者是将调用结果返回给LLM，后者是直接将调用结果响应给用户

## 测试

在微信ClawBot中发送/登录，即可得到二维码，进行认证后就可以通过自然语言下达指令了，LLM会自动决定是否调用控制夜灯的Tool

结合AstrBot的新特性【定时任务】，还可以实现定时开关灯的复杂操作

{{< figure align=center height=30% width=30% src="https://img.fnicen.top/PicGo/light_control_example.png">}}

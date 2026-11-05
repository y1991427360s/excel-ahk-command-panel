# -*- coding: utf-8 -*-
"""Anthropic / OpenAI 两种接口格式的离线回归：用本地模拟服务，不访问外网。
运行：python tests/cad-ai-provider-smoke.py"""
import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

os.environ["NO_PROXY"] = "127.0.0.1"
os.environ["no_proxy"] = "127.0.0.1"
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import cad_ai_text as tool

SECRET = "sk-test-secret-value"
PLAN = {
    "copies": [{"label": "一", "vars": {"u": "1U"}}, {"label": "二", "vars": {"u": "2U"}}],
    "rules": [{"regex": r"^\*", "replace": "{u}"}],
    "must_not_remain": [],
}
seen = []


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})
        if "IMAGE" in json.dumps(body):
            table = "```\n开关柜\t*\t#\n35kV1#风机回路进线柜\t1U\t05\n35kV1#备用柜\t[?]UBY\n```"
            if self.path.endswith("/messages"):
                self.reply(200, json.dumps({"stop_reason": "end_turn", "content": [{"type": "text", "text": table}]}))
            else:
                self.reply(200, json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": table}}]}))
        elif self.path.startswith("/limit") and body["max_tokens"] > tool.ANTHROPIC_MIN_TOKENS:
            self.reply(400, json.dumps({"error": "max_tokens too large"}))
        elif self.path.startswith("/bad"):
            self.reply(401, json.dumps({"error": f"invalid key {SECRET}"}))
        elif self.path.startswith("/html"):
            self.reply(200, "<html>登录页</html>")
        elif self.path.endswith("/messages"):
            self.reply(200, json.dumps({"stop_reason": "end_turn", "content": [
                {"type": "thinking", "thinking": "{不是规则}"},
                {"type": "text", "text": json.dumps(PLAN, ensure_ascii=False)}]}))
        else:
            text = "<think>先想想 {x}</think>" + json.dumps(PLAN, ensure_ascii=False)
            self.reply(200, json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": text}}]}))

    def reply(self, status, text):
        data = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


assert tool.anthropic_endpoint("https://api.anthropic.com") == "https://api.anthropic.com/v1/messages"
assert tool.anthropic_endpoint("https://relay.example/v1/") == "https://relay.example/v1/messages"
assert tool.anthropic_endpoint("https://relay.example/anthropic") == "https://relay.example/anthropic/v1/messages"
assert tool.anthropic_endpoint("https://relay.example/v1/messages") == "https://relay.example/v1/messages"
assert tool.openai_endpoint("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions"
assert tool.openai_endpoint("https://relay.example") == "https://relay.example/v1/chat/completions"
assert tool.openai_endpoint("https://ark.example/api/v3/") == "https://ark.example/api/v3/chat/completions"
assert tool.openai_endpoint("https://relay.example/v1/chat/completions") == "https://relay.example/v1/chat/completions"

server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"
items = tool.parse_template("1.00,2.00 *-101\n1.00,1.00 备注")


def settings(provider, url=base):
    return {"provider": provider, "base_url": url, "model": "test-model", "api_key": SECRET}


plan, (rows, _, _) = tool.plan_with_ai(items, "", "要求", settings("anthropic"))
request = seen[-1]
assert request["path"] == "/v1/messages"
assert request["headers"]["x-api-key"] == SECRET and request["headers"]["anthropic-version"] == "2023-06-01"
assert request["body"]["model"] == "test-model" and request["body"]["max_tokens"] > 0
assert request["body"]["system"] == tool.SYSTEM_PROMPT
assert [row[2] for row in rows] == ["1U-101", "备注", "2U-101", "备注"]

plan, (rows, _, _) = tool.plan_with_ai(items, "", "要求", settings("openai", base + "/v1"))
request = seen[-1]
assert request["path"] == "/v1/chat/completions"
assert request["headers"]["authorization"] == "Bearer " + SECRET
assert [message["role"] for message in request["body"]["messages"]] == ["system", "user"]
assert [row[2] for row in rows] == ["1U-101", "备注", "2U-101", "备注"]

for url, expected in ((base + "/bad", "HTTP 401"), (base + "/html/v1", "不是 JSON"), ("http://127.0.0.1:9/v1", "连接失败")):
    try:
        tool.ask_ai("hi", settings("openai", url))
    except RuntimeError as err:
        assert expected in str(err), err
        assert SECRET not in str(err), err
    else:
        raise AssertionError(url)

with tempfile.TemporaryDirectory() as folder:
    image = Path(folder) / "table.png"
    image.write_bytes(b"\x89PNG" + b"IMAGE")
    import base64
    tool.IMAGE_PROMPT = "IMAGE " + tool.IMAGE_PROMPT
    encoded = base64.b64encode(image.read_bytes()).decode()

    rows = tool.clean_table(tool.ask_image(image, settings("anthropic")))
    block = seen[-1]["body"]["messages"][0]["content"][0]
    assert block == {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": encoded}}, block
    assert rows == ["开关柜\t*\t#", "35kV1#风机回路进线柜\t1U\t05", "35kV1#备用柜\t[?]UBY"], rows
    report = tool.table_report(rows)
    assert "1 处看不清" in report and "第 3 行" in report, report

    tool.ask_image(image, settings("openai", base + "/v1"))
    part = seen[-1]["body"]["messages"][1]["content"][1]
    assert part == {"type": "image_url", "image_url": {"url": "data:image/png;base64," + encoded}}, part

    image.write_bytes(b"not an image")
    try:
        tool.ask_image(image, settings("anthropic"))
    except RuntimeError as err:
        assert "PNG" in str(err)
    else:
        raise AssertionError("不支持的图片应当失败")

assert tool.clean_table("| a | b |\n|---|---|\n| 1 | 2 |") == ["a\tb", "1\t2"]

# 接口不接受大的 max_tokens 时退回小值
assert "copies" in tool.ask_ai("hi", settings("anthropic", base + "/limit"))
assert seen[-1]["body"]["max_tokens"] == tool.ANTHROPIC_MIN_TOKENS

# 居中文字同一列 x 不同、同一行 y 有细微差别时，仍按行整理；合并单元格留在所在行
table = tool.format_table("20.00,100.01 *\n10.00,100.00 名称\n10.50,95.00 1#柜\n20.70,95.01 1U\n"
                          "10.40,90.00 2#柜\n20.60,90.00 2U\n40.00,90.00 1#保护柜\n10.50,85.00 3#柜\n20.70,85.00 3U")
assert table.splitlines() == ["y=100.01：名称 | *", "y=95.01：1#柜 | 1U", "y=90.00：2#柜 | 2U | 1#保护柜", "y=85.00：3#柜 | 3U"], table
assert tool.format_table("a\tb\n1\t2") == "a\tb\n1\t2"
prompt = tool.build_prompt(tool.parse_template("1.00,2.00 *-101\n2.00,2.00 *-101\n3.00,2.00 备注"), "", "")
assert prompt.count("*-101") == 1 and tool.DEFAULT_REQUEST in prompt, prompt

missing = dict(settings("openai"), api_key="")
try:
    tool.ask_ai("hi", missing)
except RuntimeError as err:
    assert "API Key" in str(err)
else:
    raise AssertionError("缺少 Key 应当失败")

with tempfile.TemporaryDirectory() as folder:
    config = Path(folder) / "config.ini"
    assert tool.load_settings(config)["provider"] == "claude_code"
    config.write_text("[general]\nprovider=openai\n[openai]\nbase_url=https://x.example/v1\nmodel=模型a\n", encoding="utf-16")
    loaded = tool.load_settings(config)
    assert (loaded["provider"], loaded["base_url"], loaded["model"], loaded["api_key"]) == ("openai", "https://x.example/v1", "模型a", "")

server.shutdown()
print("OK")

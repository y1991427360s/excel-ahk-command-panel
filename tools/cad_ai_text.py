# -*- coding: utf-8 -*-
"""CAD 文字批量复制改写：AI 只出替换规则，展开和校验由本脚本完成。

输入是中望 QW2 导出的“x,y 文字”：一份模板、一份参照表（可空）、一段要求。
AI 返回 JSON 规则，本脚本逐份套用，输出同样的“x,y 文字”，由中望 QW2P 写回图纸。
这样几百上千行文字不经 AI 重打，不会出现漏行、抄错坐标；校验不过时带着错误重问一次。

用法：
  python cad_ai_text.py --template t.txt --table a.txt --request r.txt --out o.txt --report p.txt
  python cad_ai_text.py --template t.txt --rules rules.json --out o.txt --report p.txt   # 不调用 AI
退出码：0 成功；1 校验不通过（report 里有原因）；2 AI 调用或参数错误。
"""
import argparse
import base64
import configparser
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

LINE_RE = re.compile(r"^\s*(-?\d+(?:\.\d*)?),(-?\d+(?:\.\d*)?) (.*)$")
AI_TIMEOUT_SECONDS = 180
OFFSET_GAP_ROWS = 2
# 带思考的模型会把额度先花在思考上，上限要留够；个别接口不接受大值时退回 ANTHROPIC_MIN_TOKENS
ANTHROPIC_MAX_TOKENS = 32000
ANTHROPIC_MIN_TOKENS = 8192
TABLE_ROW_TOLERANCE = 0.3
DEFAULT_REQUEST = "模板复制成参照表的每一行一份，模板里的占位符和待定文字按表头含义换成这一行的值。"
CONFIG_PATH = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "AutoHotkeyPanel" / "cad-ai-config.ini"
PROVIDER_DEFAULTS = {
    "claude_code": {"label": "Claude Code 登录", "base_url": "", "model": "sonnet"},
    "anthropic": {"label": "Anthropic 兼容接口", "base_url": "https://api.anthropic.com", "model": "claude-sonnet-5-5"},
    "openai": {"label": "OpenAI 兼容接口", "base_url": "https://api.openai.com/v1", "model": ""},
}

SYSTEM_PROMPT = """你是电气二次图纸的文字批量处理助手。用户给出一份模板文字、一张参照表和修改要求，模板要复制多份，每份按参照表的一行改写。

你不重打文字，只输出一个 JSON 规则对象，由程序逐份套用。只输出 JSON，不要代码块，不要解释。

JSON 格式：
{
  "copies": [{"label": "这一份的名字", "vars": {"变量名": "值"}}],
  "rules": [
    {"find": "要替换的字面文字", "replace": "含 {变量名} 的新文字"},
    {"regex": "Python 正则", "replace": "含 {变量名} 的新文字，可用 \\\\1"}
  ],
  "must_not_remain": ["改完后任何一行都不允许再匹配的 Python 正则"],
  "offset": null,
  "notes": ["拿不准、需要用户核对的地方"]
}

要求：
1. 模板给的是去重后的文字，每行一条。参照表是整理好的表格，第一行是表头，单元格用制表符或“|”分隔。
2. 单元格写在“y=数值：”后面时，表示图纸里同一行的文字，从左到右排列。某行的单元格比其他行多，或者某行只有几个单元格，多出来的就是合并单元格：它只出现一次，纵坐标在它跨越的若干行的中间，要分配给它跨越的每一行。例如 5 行一组时它在第 3 行，每组的合并单元格各管一组。
3. copies 的份数和顺序与参照表的数据行一一对应。值照抄表格原文，不要改写、补零或去零。
4. 占位符的范围要写准：同一符号在模板里可能既是占位符又是普通文字。例如 # 在“11ZL-#”里是占位符，在“至1-1#直流馈线柜”里是普通文字，这时要用带上下文的正则，不能全局替换。
5. rules 按顺序作用在每一行上，已被替换出来的文字不会再被后面的规则改动，所以不用担心变量值里的 # 或 * 被二次替换。
6. 占位符改完不得残留，把它们写进 must_not_remain。
7. offset 是相邻两份之间的 [dx, dy] 偏移；要求里没有说就写 null，程序默认向下依次排列。
8. 用户要求与参照表有出入，或者看不准时，按最合理的理解写规则，并在 notes 里说明。
9. 用户的要求可能只有一句话。这时根据表头判断对应关系：表头是 * 或 # 这类符号时，就是模板里同样的占位符；表头是名称时，替换模板里表示同一含义的文字，例如“开关柜名称”对应“35kV 风机回路进线柜+备用柜”，“本段母线保护柜”对应“1(2)#35kV母线保护柜”，“本段母线PT”对应“本段母线PT柜”里的“本段母线PT”。没有对应列的文字保持不变。
10. 参照表的每一列都要在模板里找到要替换的地方。列名是符号时，模板里有这个符号的文字就是替换位置，哪怕只出现在个别文字里。确实用不上的列不要放进 vars，并写进 notes。
11. 判断清楚后立即输出，不要反复推敲；不确定的写进 notes。"""


IMAGE_PROMPT = """你负责把图片里的表格逐字转写成纯文本。只输出表格本身，不要解释，不要代码块。

要求：
1. 第一行是表头，之后每行一条记录，列之间用制表符分隔。
2. 合并单元格的内容填到它跨越的每一行，不留空。
3. 文字照抄，不改写、不补零、不去零，# 和 * 等符号保留原样。注意区分 U 和 V、0 和 O、1 和 I。
4. 看不清的字写成 [?]，不要猜。"""
IMAGE_MAX_BYTES = 3750000


class ValidationFailure(Exception):
    def __init__(self, errors):
        super().__init__("\n".join(errors))
        self.errors = errors


def read_text(path):
    return Path(path).read_text(encoding="utf-8-sig")


def parse_template(text):
    items = []
    errors = []
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        match = LINE_RE.match(raw)
        if not match:
            errors.append(f"第 {number} 行不是“x,y 文字”格式：{raw[:40]}")
            continue
        items.append((float(match[1]), float(match[2]), match[3]))
    if errors:
        raise ValidationFailure(errors)
    if not items:
        raise ValidationFailure(["模板是空的。"])
    return items


def default_offset(items):
    """默认向下排列：相邻两份之间空出 2 倍最常见的行距。"""
    ys = sorted({item[1] for item in items}, reverse=True)
    gaps = [round(a - b, 2) for a, b in zip(ys, ys[1:])]
    pitch = max(set(gaps), key=gaps.count) if gaps else 10.0
    return [0.0, -round(ys[0] - ys[-1] + pitch * OFFSET_GAP_ROWS, 2)]


def fill_vars(template, variables):
    def replace(match):
        name = match[1]
        return variables[name] if name in variables else match[0]
    return re.sub(r"\{([^{}]+)\}", replace, template)


def apply_rule(segments, rule, variables, hits):
    """segments 是 [(文字, 是否已替换)]，已替换的部分不再参与后面的规则。"""
    replacement = rule.get("replace", "")
    if "regex" in rule:
        pattern = re.compile(rule["regex"])
        # 先展开分组再填变量，否则 \1 紧跟变量值 05 会被读成 \105
        expand = lambda match: fill_vars(match.expand(replacement), variables)
    else:
        pattern = re.compile(re.escape(rule["find"]))
        expand = lambda match: fill_vars(replacement, variables)

    result = []
    for text, frozen in segments:
        if frozen:
            result.append((text, True))
            continue
        position = 0
        for match in pattern.finditer(text):
            if match.end() == match.start():
                continue
            if match.start() > position:
                result.append((text[position:match.start()], False))
            result.append((expand(match), True))
            position = match.end()
            hits[0] += 1
        if position < len(text):
            result.append((text[position:], False))
    return result


def rewrite_line(text, rules, variables, rule_hits):
    segments = [(text, False)]
    for index, rule in enumerate(rules):
        segments = apply_rule(segments, rule, variables, rule_hits[index])
    return "".join(part for part, _ in segments)


def expand(items, plan):
    copies = plan.get("copies") or []
    rules = plan.get("rules") or []
    forbidden = plan.get("must_not_remain") or []
    errors = []

    if not copies:
        errors.append("规则里没有 copies。")
    if not rules:
        errors.append("规则里没有 rules。")
    for rule in rules:
        if not ("find" in rule or "regex" in rule) or "replace" not in rule:
            errors.append(f"规则缺少 find/regex 或 replace：{json.dumps(rule, ensure_ascii=False)}")
        if "regex" in rule:
            try:
                re.compile(rule["regex"])
            except re.error as err:
                errors.append(f"正则无效：{rule['regex']}（{err}）")
    used_names = set()
    for rule in rules:
        used_names |= set(re.findall(r"\{([^{}]+)\}", rule.get("replace", "")))
    for number, copy in enumerate(copies, 1):
        missing = used_names - set((copy.get("vars") or {}).keys())
        if missing:
            errors.append(f"第 {number} 份缺少变量：{'、'.join(sorted(missing))}")
    # 从参照表取了值却没有规则用它，多半是漏了替换，比如 11ZL-# 原样留下
    unused = set().union(*[set((copy.get("vars") or {}).keys()) for copy in copies]) - used_names if copies else set()
    if unused:
        errors.append(f"这些变量没有任何规则用到，模板里对应的文字没有替换：{'、'.join(sorted(unused))}")
    if errors:
        raise ValidationFailure(errors)

    offset = plan.get("offset") or default_offset(items)
    rule_hits = [[0] for _ in rules]
    output = []
    for number, copy in enumerate(copies):
        variables = {key: str(value) for key, value in copy["vars"].items()}
        for x, y, text in items:
            new_text = rewrite_line(text, rules, variables, rule_hits)
            output.append((x + offset[0] * number, y + offset[1] * number, new_text, copy.get("label", "")))

    for index, rule in enumerate(rules):
        if rule_hits[index][0] == 0:
            errors.append(f"规则一次也没有命中：{rule.get('find') or rule.get('regex')}")
    for pattern in forbidden + [r"\*"]:
        try:
            regex = re.compile(pattern)
        except re.error as err:
            errors.append(f"must_not_remain 正则无效：{pattern}（{err}）")
            continue
        leftovers = [row[2] for row in output if regex.search(row[2])]
        if leftovers:
            errors.append(f"改完仍有 {len(leftovers)} 行匹配 {pattern}，例如：{leftovers[0]}")
    if errors:
        raise ValidationFailure(errors)
    return output, offset, [hit[0] for hit in rule_hits]


def extract_json(text):
    # 部分 OpenAI 兼容模型会把思考过程写在 <think> 里，其中也可能出现花括号
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("AI 没有返回 JSON。")
    return json.loads(text[start:end + 1])


def find_claude():
    found = shutil.which("claude")
    if found:
        return found
    fallback = Path.home() / ".local" / "bin" / "claude.exe"
    if fallback.exists():
        return str(fallback)
    raise RuntimeError("找不到 claude 命令，请确认 Claude Code 已安装并登录。")


def dpapi_decrypt(encoded):
    """解开面板用 CryptProtectData 加密的 API Key；只有同一台电脑的同一账户能解开。"""
    class Blob(ctypes.Structure):
        _fields_ = [("size", ctypes.c_uint32), ("data", ctypes.POINTER(ctypes.c_char))]

    raw = base64.b64decode(encoded)
    buffer = ctypes.create_string_buffer(raw, len(raw))
    source = Blob(len(raw), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    target = Blob()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)):
        raise RuntimeError("API Key 解密失败，请在“AI 设置”里重新填写。")
    try:
        return ctypes.string_at(target.data, target.size).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(ctypes.cast(target.data, ctypes.c_void_p))


def load_settings(path):
    parser = configparser.RawConfigParser()
    if Path(path).exists():
        parser.read(path, encoding="utf-16")
    provider = parser.get("general", "provider", fallback="claude_code")
    if provider not in PROVIDER_DEFAULTS:
        raise RuntimeError(f"未知的接口类型：{provider}")
    defaults = PROVIDER_DEFAULTS[provider]
    encrypted = parser.get(provider, "api_key_dpapi", fallback="")
    return {
        "provider": provider,
        "base_url": parser.get(provider, "base_url", fallback="").strip() or defaults["base_url"],
        "model": parser.get(provider, "model", fallback="").strip() or defaults["model"],
        "api_key": dpapi_decrypt(encrypted) if encrypted else "",
    }


def describe_settings(settings):
    label = PROVIDER_DEFAULTS[settings["provider"]]["label"]
    return f"{label} · {settings['model']}"


def has_version_path(url):
    return re.search(r"/v\d+[a-z0-9]*$", urllib.parse.urlsplit(url).path) is not None


def anthropic_endpoint(base_url):
    url = base_url.rstrip("/")
    if url.endswith("/messages"):
        return url
    return url + ("/messages" if has_version_path(url) else "/v1/messages")


def openai_endpoint(base_url):
    url = base_url.rstrip("/")
    if url.endswith("/chat/completions"):
        return url
    # 只有域名时补 /v1；带路径的中转地址按用户填写的来
    if not urllib.parse.urlsplit(url).path.strip("/"):
        url += "/v1"
    return url + "/chat/completions"


def post_json(url, headers, payload, secret):
    def hide(text):
        return text.replace(secret, "***") if secret else text

    request = urllib.request.Request(url, json.dumps(payload).encode("utf-8"), method="POST", headers={
        "Content-Type": "application/json", "User-Agent": "cad-ai-text/1.0", **headers})
    try:
        with urllib.request.urlopen(request, timeout=AI_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace").strip()
        raise RuntimeError(f"接口返回 HTTP {err.code}（{url}）：{hide(detail)[:500]}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise RuntimeError(f"连接失败（{url}）：{hide(str(getattr(err, 'reason', err)))}") from None
    try:
        return json.loads(body)
    except ValueError:
        raise RuntimeError(f"接口返回的不是 JSON，请检查请求地址（{url}）：{hide(body)[:200]}") from None


def ask_anthropic(prompt, settings, system):
    def send(max_tokens):
        return post_json(anthropic_endpoint(settings["base_url"]),
                         {"x-api-key": settings["api_key"], "anthropic-version": "2023-06-01"},
                         {"model": settings["model"], "max_tokens": max_tokens, "system": system,
                          "messages": [{"role": "user", "content": prompt}]},
                         settings["api_key"])

    try:
        result = send(ANTHROPIC_MAX_TOKENS)
    except RuntimeError as err:
        if "HTTP 400" not in str(err) or "max_tokens" not in str(err):
            raise
        result = send(ANTHROPIC_MIN_TOKENS)
    if result.get("stop_reason") == "max_tokens":
        # ValueError 由 plan_with_ai 重问一次
        raise ValueError("AI 输出超过长度上限，规则不完整。")
    return "".join(block.get("text", "") for block in result.get("content", []) if block.get("type") == "text")


def ask_openai(prompt, settings, system):
    result = post_json(openai_endpoint(settings["base_url"]),
                       {"Authorization": "Bearer " + settings["api_key"]},
                       {"model": settings["model"],
                        "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}]},
                       settings["api_key"])
    choices = result.get("choices") or []
    if not choices:
        raise RuntimeError(f"接口没有返回 choices：{json.dumps(result, ensure_ascii=False)[:300]}")
    if choices[0].get("finish_reason") == "length":
        raise ValueError("AI 输出超过长度上限，规则不完整。")
    content = choices[0].get("message", {}).get("content") or ""
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content)
    return content


def read_image(path):
    data = Path(path).read_bytes()
    if len(data) > IMAGE_MAX_BYTES:
        raise RuntimeError("图片超过 3.75MB，请裁剪或缩小后再试。")
    if data.startswith(b"\x89PNG"):
        return data, "image/png", "png"
    if data.startswith(b"\xff\xd8"):
        return data, "image/jpeg", "jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return data, "image/webp", "webp"
    raise RuntimeError("只支持 PNG、JPG、WEBP 图片。")


def ask_image(path, settings):
    data, media_type, extension = read_image(path)
    instruction = "转写这张图片里的表格。"
    if settings["provider"] == "claude_code":
        with tempfile.TemporaryDirectory(prefix="cad-ai-image-") as folder:
            target = Path(folder) / f"table.{extension}"
            target.write_bytes(data)
            return ask_claude_code(f"{instruction}图片文件：{target}", settings["model"], IMAGE_PROMPT, "Read", folder)
    encoded = base64.b64encode(data).decode("ascii")
    if settings["provider"] == "anthropic":
        content = [{"type": "image", "source": {"type": "base64", "media_type": media_type, "data": encoded}},
                   {"type": "text", "text": instruction}]
    else:
        content = [{"type": "text", "text": instruction},
                   {"type": "image_url", "image_url": {"url": f"data:{media_type};base64,{encoded}"}}]
    return ask_ai(content, settings, IMAGE_PROMPT)


def clean_table(text):
    """收拾模型的输出：去掉思考段和代码块，Markdown 表格转成制表符。"""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("```") or re.fullmatch(r"[|:\-\s]+", line):
            continue
        if "\t" not in line and "|" in line:
            line = "\t".join(cell.strip() for cell in line.strip("|").split("|"))
        rows.append(line)
    return rows


def table_report(rows):
    counts = [len(row.split("\t")) for row in rows]
    columns = max(set(counts), key=counts.count)
    lines = [f"已识别 {len(rows) - 1} 行数据、{columns} 列，已填入参照表。图片识别可能认错字，请逐项核对后再让 AI 处理。"]
    unclear = sum(row.count("[?]") for row in rows)
    if unclear:
        lines.append(f"有 {unclear} 处看不清，已标成 [?]，请手动改正。")
    uneven = [number for number, count in enumerate(counts, 1) if count != columns]
    if uneven:
        lines.append("这些行的列数不一致，可能漏了合并单元格：第 " + "、".join(map(str, uneven)) + " 行。")
    return "\r\n".join(lines)


def ask_ai(prompt, settings, system=SYSTEM_PROMPT):
    provider = settings["provider"]
    if provider == "claude_code":
        return ask_claude_code(prompt, settings["model"], system)
    if not settings["api_key"]:
        raise RuntimeError("还没有填写 API Key，请打开“AI 设置”。")
    if not settings["model"]:
        raise RuntimeError("还没有填写模型名称，请打开“AI 设置”。")
    return ask_anthropic(prompt, settings, system) if provider == "anthropic" else ask_openai(prompt, settings, system)


def ask_claude_code(prompt, model, system, tools="", image_folder=None):
    # 不读用户/项目设置：免得每次调用都触发 Stop 钩子发通知，也避免全局记忆干扰规则输出
    command = [find_claude(), "-p", "--model", model, "--tools", tools, "--no-session-persistence",
               "--setting-sources", "local", "--system-prompt", system]
    if image_folder:
        command += ["--allowedTools", "Read", "--add-dir", image_folder]
    with tempfile.TemporaryDirectory(prefix="cad-ai-") as workdir:
        env = {key: value for key, value in os.environ.items() if key != "CLAUDECODE"}
        result = subprocess.run(command, input=prompt.encode("utf-8"), capture_output=True, cwd=workdir,
                                timeout=AI_TIMEOUT_SECONDS, env=env,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    stdout = result.stdout.decode("utf-8", "replace")
    if result.returncode != 0:
        detail = (stdout + result.stderr.decode("utf-8", "replace")).strip()
        raise RuntimeError(f"Claude 调用失败（退出码 {result.returncode}）：{detail[:500]}")
    return stdout


def format_table(table):
    """把“x,y 文字”的参照表按 y 分行、按 x 排序，免得 AI 自己还原表格结构。其他格式原样返回。"""
    cells = []
    for line in table.splitlines():
        if not line.strip():
            continue
        match = LINE_RE.match(line)
        if not match:
            return table
        cells.append((float(match[2]), float(match[1]), match[3]))
    if not cells:
        return table
    ys = sorted({cell[0] for cell in cells}, reverse=True)
    gaps = sorted(a - b for a, b in zip(ys, ys[1:]) if a - b > 0.05)
    pitch = gaps[len(gaps) // 2] if gaps else 1.0
    rows = []
    for cell in sorted(cells, key=lambda item: -item[0]):
        if rows and rows[-1][0] - cell[0] <= pitch * TABLE_ROW_TOLERANCE:
            rows[-1][1].append(cell)
        else:
            rows.append((cell[0], [cell]))
    lines = []
    for y, row in rows:
        lines.append(f"y={y:.2f}：" + " | ".join(cell[2] for cell in sorted(row, key=lambda item: item[1])))
    return "\n".join(lines)


def unique_texts(items):
    return "\n".join(dict.fromkeys(item[2] for item in items))


def build_prompt(items, table, request):
    return (f"修改要求：\n{request.strip() or DEFAULT_REQUEST}\n\n模板文字（已去重）：\n{unique_texts(items)}\n\n"
            f"参照表：\n{format_table(table).strip() or '（无）'}\n")


def plan_with_ai(items, table, request, settings):
    prompt = build_prompt(items, table, request)
    last_error = ""
    for _ in range(2):
        try:
            plan = extract_json(ask_ai(prompt, settings))
            return plan, expand(items, plan)
        except (ValueError, ValidationFailure, re.error, IndexError, TypeError, KeyError, AttributeError) as err:
            last_error = str(err)
            prompt = build_prompt(items, table, request) + f"\n上一次的规则校验没有通过：\n{last_error}\n请修正后重新输出完整 JSON。"
    raise ValidationFailure([last_error])


def format_output(rows):
    return "\r\n".join(f"{x:.2f},{y:.2f} {text}" for x, y, text, _ in rows)


def format_report(items, plan, rows, offset, hits):
    copies = plan["copies"]
    lines = [f"共 {len(copies)} 份，每份 {len(items)} 行，合计 {len(rows)} 行；相邻两份偏移 {offset[0]:g},{offset[1]:g}。"]
    notes = plan.get("notes") or []
    if notes:
        lines.append("")
        lines.append("需要核对：")
        lines.extend(f"- {note}" for note in notes)
    lines.append("")
    lines.append("规则命中：")
    for rule, hit in zip(plan["rules"], hits):
        lines.append(f"- {rule.get('find') or rule.get('regex')} → {rule['replace']}（{hit} 处）")
    lines.append("")
    lines.append("各份内容：")
    for copy in copies:
        lines.append(f"- {copy.get('label', '')}：" + "、".join(f"{key}={value}" for key, value in copy["vars"].items()))
    return "\r\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template")
    parser.add_argument("--table")
    parser.add_argument("--request")
    parser.add_argument("--rules", help="已有规则 JSON，不调用 AI")
    parser.add_argument("--out")
    parser.add_argument("--report", required=True)
    parser.add_argument("--config", default=str(CONFIG_PATH))
    parser.add_argument("--test", action="store_true", help="只测试 AI 接口能否连通")
    parser.add_argument("--read-image", help="把图片里的表格识别成制表符分隔的文字")
    args = parser.parse_args()

    report_path = Path(args.report)
    try:
        if args.test:
            settings = load_settings(args.config)
            answer = ask_ai("只回答 OK", settings, "你是接口连通性测试，只回答 OK。").strip()
            report_path.write_text(f"连接成功：{describe_settings(settings)}\r\n模型回复：{answer[:100]}", encoding="utf-8", newline="")
            return 0
        if args.read_image:
            settings = load_settings(args.config)
            rows = clean_table(ask_image(args.read_image, settings))
            if len(rows) < 2:
                raise RuntimeError("没有从图片里识别出表格，所选模型可能不支持图片。")
            Path(args.out).write_text("\r\n".join(rows), encoding="utf-8", newline="")
            report_path.write_text(f"使用 AI：{describe_settings(settings)}\r\n" + table_report(rows), encoding="utf-8", newline="")
            return 0
        template = read_text(args.template)
        items = parse_template(template)
        settings = None
        if args.rules:
            plan = json.loads(read_text(args.rules))
            result = expand(items, plan)
        else:
            table = read_text(args.table) if args.table else ""
            request = read_text(args.request) if args.request else ""
            settings = load_settings(args.config)
            plan, result = plan_with_ai(items, table, request, settings)
    except ValidationFailure as err:
        report_path.write_text("校验没有通过，未生成结果：\r\n" + "\r\n".join(err.errors), encoding="utf-8")
        return 1
    except Exception as err:
        report_path.write_text(f"处理失败：{err}", encoding="utf-8")
        return 2

    rows, offset, hits = result
    Path(args.out).write_text(format_output(rows), encoding="utf-8", newline="")
    used = f"使用 AI：{describe_settings(settings)}\r\n" if settings else ""
    report_path.write_text(used + format_report(items, plan, rows, offset, hits), encoding="utf-8", newline="")
    return 0


if __name__ == "__main__":
    sys.exit(main())

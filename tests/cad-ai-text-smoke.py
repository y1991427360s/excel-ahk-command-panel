# -*- coding: utf-8 -*-
"""cad_ai_text.py 离线回归：不调用 AI。运行：python tests/cad-ai-text-smoke.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import cad_ai_text as tool

items = tool.parse_template((ROOT / "tests" / "cad-ai-text" / "template.txt").read_text(encoding="utf-8"))


def copy(name, u, n, bus, pt):
    return {"label": name, "vars": {"name": name, "u": u, "n": n, "bus": bus, "pt": pt}}


PLAN = {
    "copies": [
        copy("35kV1#风机回路进线柜", "1U", "05", "1#35kV母线保护柜", "35kV 1#PT柜"),
        copy("35kV2#备用柜", "2UBY", "14", "2#35kV母线保护柜", "35kV 2#PT柜"),
    ],
    "rules": [
        {"find": "35kV 风机回路进线柜+备用柜", "replace": "{name}"},
        {"find": "1(2)#35kV母线保护柜", "replace": "{bus}"},
        {"find": "本段母线PT柜", "replace": "{pt}"},
        {"regex": r"^\*", "replace": "{u}"},
        {"regex": r"(ZL-)#$", "replace": r"\1{n}"},
    ],
    "must_not_remain": ["ZL-#", "本段"],
}

rows, offset, hits = tool.expand(items, PLAN)
texts = [row[2] for row in rows]
first = texts[:len(items)]
second = texts[len(items):]

assert len(items) == 135 and len(rows) == 270
assert offset == [0.0, -102.5], offset
# 图三的成品
for expected in ["35kV1#风机回路进线柜", "1U-101A", "至1#35kV母线保护柜", "至35kV 1#PT柜", "1U-130", "11ZL-05", "21ZL-05", "至1-1#直流馈线柜", "至2-1#直流馈线柜"]:
    assert expected in first, expected
for expected in ["2UBY-A431", "至2#35kV母线保护柜", "至35kV 2#PT柜", "11ZL-14"]:
    assert expected in second, expected
# 变量值里的 # 不能被后面的规则二次替换；非占位的数据原样保留
assert first[0] == "35kV1#风机回路进线柜"
assert "485+'" in first and "201" in first and "+KM" in first
assert rows[len(items)][:2] == (items[0][0], items[0][1] - 102.5)

failed = dict(PLAN, must_not_remain=["1U"])
try:
    tool.expand(items, failed)
except tool.ValidationFailure as err:
    assert "1U" in str(err)
else:
    raise AssertionError("残留校验应当失败")

# 11ZL-# 没人替换时不能算通过
skipped = dict(PLAN, rules=PLAN["rules"][:-1], must_not_remain=[])
try:
    tool.expand(items, skipped)
except tool.ValidationFailure as err:
    assert "没有任何规则用到" in str(err) and "n" in str(err)
else:
    raise AssertionError("未使用的变量应当失败")

missing = dict(PLAN, rules=PLAN["rules"] + [{"find": "不存在的文字", "replace": "x"}])
try:
    tool.expand(items, missing)
except tool.ValidationFailure as err:
    assert "没有命中" in str(err)
else:
    raise AssertionError("未命中规则应当失败")

try:
    tool.parse_template("这不是坐标行")
except tool.ValidationFailure:
    pass
else:
    raise AssertionError("格式错误应当失败")

print("OK")

#!/usr/bin/env python3
"""设置项体检：`NoBrainer_data.lua` 里引用的每个键，`NoBrainer_localization.lua` 里都得有。

缺键的后果很隐蔽：DMF 选项界面会直接把原始 key（比如 `enable_debug_messages_tooltip`）
显示给用户，不报错。加设置 / 改文案之后跑一下这个就不会漏。

用法：python tools/check_settings.py
退出码：0 = 全部对得上；1 = 有缺键或解析不出东西。
"""
import re
import sys
import pathlib

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

MOD = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "mods" / "NoBrainer"
DATA = MOD / "NoBrainer_data.lua"
LOC = MOD / "NoBrainer_localization.lua"


def main():
    if not DATA.exists() or not LOC.exists():
        print(f"找不到 {DATA.name} / {LOC.name}")
        return 1

    data = DATA.read_text(encoding="utf-8")
    loc = LOC.read_text(encoding="utf-8")

    setting_ids = sorted(set(re.findall(r'setting_id\s*=\s*"([^"]+)"', data)))
    tooltips = sorted(set(re.findall(r'tooltip\s*=\s*"([^"]+)"', data)))
    titles = sorted(set(re.findall(r'title\s*=\s*"([^"]+)"', data)))
    option_texts = sorted(set(re.findall(r'text\s*=\s*"([^"]+)"', data)))

    # 本地化文件里每个键都是 "key = { en = ... }" 的形式
    defined = set(re.findall(r"^\s*([A-Za-z_][A-Za-z_0-9]*)\s*=\s*\{", loc, re.M))

    print(f"设置项 {len(setting_ids)} 个，本地化键 {len(defined)} 个")

    missing = []
    for kind, names in (("setting_id", setting_ids), ("tooltip", tooltips), ("title", titles), ("option text", option_texts)):
        for name in names:
            if name not in defined:
                missing.append((kind, name))

    if not missing:
        print("OK：data 里引用的每个键在本地化里都有")
        return 0

    print("缺这些键（选项界面会显示原始 key）：")
    for kind, name in missing:
        print(f"  {kind:<11} {name}")

    # 顺带列出"定义了但没人用"的键，方便清理（不影响退出码）
    used = set(setting_ids) | set(tooltips) | set(titles) | set(option_texts)
    unused = sorted(defined - used)
    if unused:
        print("\n定义了但 data 里没人引用（可能是历史遗留，仅供参照）：")
        for name in unused:
            print(f"  {name}")

    return 1


if __name__ == "__main__":
    sys.exit(main())

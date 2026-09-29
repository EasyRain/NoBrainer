#!/usr/bin/env python3
"""游戏 API 体检：大版本更新后，查 NoBrainer 引用的游戏 API 是否还在。

背景：1.13.0 删掉了 `SmartTagExtension:is_particular_target_type()`，而 mod 在每 0.05 秒的循环里
调它 → 一局普通任务刷出 364 个错误块 / 1456 行日志、把日志顶到 9.1 MB。这类"大版本删/改 API"
的问题，靠实测日志只能碰到**实际跑到的那几处**；这个脚本用"上一版 vs 新版"对比把整个引用面扫一遍。

它做三件事（都用**整个游戏树**做证据，而不是猜）：

1. `require("scripts/...")` / `mod:hook_require("scripts/...")` 的路径 → 在新版树里是否还存在；
2. `mod:hook_safe("类名", "方法名")` / `mod:hook("类名", "方法名")` → 类名与方法名是否还出现在新版树里；
3. 源码里所有 `:方法名(` 形式的方法调用 → 在新版树里 0 命中、而在**旧版树**里 >0 命中的，
   就是"旧版有、新版被删"的确凿 API 删除（1.13 那次正属此类）。

匹配方式与排错会话一致：在树里 grep 名字，**0 命中 = 已删除**（LuaJIT 字节码与 Lua 源码里
字符串常量都是明文）。注意是子串匹配，与 grep 行为一致。

用法：
    python tools/check_game_api.py --game-tree <新版游戏树> [--old-tree <旧版游戏树>]

    # 本工作区的实际路径（1.13 vs 1.12）
    python tools/check_game_api.py \
        --game-tree ../../.dtsrc/113-bytecode \
        --old-tree ../../game-data/source/Darktide-Source-Code

游戏树从哪来：见 tools/README.md「游戏 API 体检」一节（limn 解字节码 / 反编译）。
退出码：0 = 没发现问题；1 = 有需要处理的项。
"""
import argparse
import pathlib
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# 这些方法名属于 Lua/引擎自带、不在游戏 Lua 树里，grep 必然 0 命中，不该报出来
STDLIB = {
    "abs", "assert", "byte", "ceil", "char", "clamp", "concat", "cos", "deg", "error", "find",
    "floor", "format", "fmod", "gmatch", "gsub", "huge", "insert", "ipairs", "len", "log",
    "lower", "match", "max", "maxinteger", "min", "mininteger", "next", "pack", "pairs", "pcall",
    "rad", "random", "randomseed", "remove", "rep", "reverse", "select", "setmetatable", "sin",
    "sort", "sqrt", "sub", "tan", "tonumber", "tostring", "type", "unpack", "upper", "xpcall",
}

RE_REQUIRE = re.compile(r'require\(\s*"([^"]+)"\s*\)')
RE_HOOK_REQUIRE_PATH = re.compile(r'mod:hook_require\(\s*"([^"]+)"')
RE_HOOK_CLASS = re.compile(r'mod:hook(?:_safe)?\(\s*"([^"]+)"\s*,\s*"([^"]+)"')
RE_COLON_CALL = re.compile(r":([A-Za-z_][A-Za-z0-9_]*)\s*\(")
RE_NB_DEFINED = re.compile(r"(?:local\s+function\s+|function\s+|^|\W)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function")


def collect_references(mod_dir):
    """从 mod 源码里收集 require 路径、hook 目标、以及 :方法( 形式的方法名。"""
    paths, hooks, methods, defined = set(), set(), set(), set()

    for lua in sorted(mod_dir.glob("*.lua")):
        text = lua.read_text(encoding="utf-8", errors="replace")
        paths.update(RE_REQUIRE.findall(text))
        paths.update(RE_HOOK_REQUIRE_PATH.findall(text))
        hooks.update(RE_HOOK_CLASS.findall(text))
        for name in RE_COLON_CALL.findall(text):
            if name not in STDLIB:
                methods.add(name)
        defined.update(RE_NB_DEFINED.findall(text))

    # mod 自己定义的名字不算游戏 API
    methods -= defined
    return sorted(paths), sorted(hooks), sorted(methods)


def tree_paths(tree):
    return [p for p in tree.rglob("*.lua")]


def scan_tree(tree, names):
    """一趟扫完整棵树，返回在这棵树里出现过的名字集合（子串匹配，与 grep 一致）。

    注意：交替正则必须**长名字优先**，否则 `MinigameBalance` 会先匹配掉 `MinigameBalanceView`
    的开头并把这段字节吃掉，长名字就永远统计不到（本工具第一版就栽在这里）。
    """
    if not names:
        return set()
    ordered = sorted(names, key=len, reverse=True)
    pattern = re.compile("|".join(re.escape(n) for n in ordered).encode("ascii"))
    found = set()
    for path in tree_paths(tree):
        try:
            data = path.read_bytes()
        except OSError:
            continue
        for match in pattern.finditer(data):
            found.add(match.group(0).decode("ascii"))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-tree", required=True, help="新版游戏的 Lua 树（字节码或反编译源码）")
    parser.add_argument("--old-tree", help="旧版游戏的 Lua 树，用来区分'被删'和'本来就没有'")
    parser.add_argument("--mod-dir", default=None, help="NoBrainer 源码目录（默认按脚本位置推断）")
    args = parser.parse_args()

    game_tree = pathlib.Path(args.game_tree).resolve()
    old_tree = pathlib.Path(args.old_tree).resolve() if args.old_tree else None
    mod_dir = pathlib.Path(args.mod_dir).resolve() if args.mod_dir else \
        pathlib.Path(__file__).resolve().parent.parent / "scripts" / "mods" / "NoBrainer"

    if not game_tree.is_dir():
        print(f"找不到新版游戏树：{game_tree}")
        return 1
    if not mod_dir.is_dir():
        print(f"找不到 mod 源码目录：{mod_dir}")
        return 1

    paths, hooks, methods = collect_references(mod_dir)
    print(f"mod 源码：{mod_dir}")
    print(f"新版游戏树：{game_tree}" + (f"\n旧版游戏树：{old_tree}" if old_tree else ""))
    print(f"收集到 require 路径 {len(paths)} 个、hook 目标 {len(hooks)} 个、:方法( 名 {len(methods)} 个\n")

    problems = 0

    # ---- 1. require 路径是否还在 ----
    print("== 1. require / hook_require 的路径 ==")
    missing_paths = []
    for path in paths:
        candidate = game_tree / (path + ".lua")
        if not candidate.exists():
            # 有的模块 require 的是目录里的文件而省略 .lua，或路径本身带后缀
            if not (game_tree / path).exists():
                missing_paths.append(path)
                continue
        print(f"  OK    {path}")
    for path in missing_paths:
        print(f"  缺失  {path}")
    problems += len(missing_paths)
    if not paths:
        print("  （没收集到）")

    # ---- 2. hook 目标是否还在 ----
    print("\n== 2. 按类名挂钩的类 / 方法 ==")
    class_hits = scan_tree(game_tree, sorted({c for c, _ in hooks}))
    method_hits = scan_tree(game_tree, sorted({m for _, m in hooks}))
    missing_hooks = []
    for class_name, method in hooks:
        ok_class = class_name in class_hits
        ok_method = method in method_hits
        if ok_class and ok_method:
            print(f"  OK    {class_name}.{method}")
        else:
            which = []
            if not ok_class:
                which.append("类名")
            if not ok_method:
                which.append("方法名")
            missing_hooks.append((class_name, method, "/".join(which)))
            print(f"  缺失  {class_name}.{method}   （{'、'.join(which)}在新版树里 0 命中）")
    problems += len(missing_hooks)

    # ---- 3. :方法( 调用：新版没有、旧版有的就是被删的 API ----
    print("\n== 3. 源码里 :方法( 形式的调用 ==")
    game_hits = scan_tree(game_tree, methods)
    absent_now = [m for m in methods if m not in game_hits]
    print(f"  新版树里 0 命中：{len(absent_now)} / {len(methods)}")

    removed, unknown = [], []
    if old_tree and old_tree.is_dir() and absent_now:
        old_hits = scan_tree(old_tree, absent_now)
        for name in absent_now:
            (removed if name in old_hits else unknown).append(name)
    else:
        unknown = absent_now

    if removed:
        print("\n  ⚠️ 旧版有、新版没有（确认被删 / 改名，必须处理）：")
        for name in removed:
            print(f"      {name}")
    if unknown:
        print("\n  旧版同样 0 命中（多半是 mod 自己的表方法、原生 API 或拼写；供参考）：")
        for name in unknown:
            print(f"      {name}")
    problems += len(removed)

    print()
    if problems:
        print(f"结论：{problems} 项需要处理（模块缺失 {len(missing_paths)} / hook 失效 {len(missing_hooks)} / 确认被删的 API {len(removed)}）")
        return 1
    print("结论：没发现被删的游戏 API —— mod 引用的模块、hook 目标与 :方法( 调用在新版树里都能找到")
    return 0


if __name__ == "__main__":
    sys.exit(main())

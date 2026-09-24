#!/usr/bin/env python3
"""NoBrainer 钩子体检：仓库里注册的每个钩子，在真机日志里到底挂上了没有。

为什么需要它：NoBrainer 大部分钩子是 mod:hook_safe("类名", "方法")。Darktide Mod Framework 是先查 _G、
再查 _G.CLASS（游戏自己的类登记表）来解析这个名字的；解析不到就先记成"延迟钩子"，
等 class() 造出这个类、并且第一次 new 的时候补挂。
- 类被改名 / 不再登记 → 日志里只有 "needs to be delayed"，永远等不到 "is now available" → 静默失效。
- 方法被改名 → Darktide Mod Framework 会打一条 error（trying to hook function or method that doesn't exist）。
两种都能从日志里查出来，所以游戏更新后跑一下这个脚本就知道哪块功能已经废了。

用法：
    python tools/check_hooks.py                  # 用最新的 console log，mod 名默认 NoBrainer
    python tools/check_hooks.py <log 路径>
    python tools/check_hooks.py --mod NoBrainer <log 路径>

退出码：全部 OK = 0；有 DEAD / ERROR / MISSING = 1（方便挂进别的检查脚本）。
"""
import os
import re
import sys
import glob
import pathlib

# Windows 上被重定向/管道时 stdout 会用 ANSI 代码页，中文会乱码；统一成 UTF-8。
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

MOD_SOURCES = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "mods" / "NoBrainer"

# 源码里的注册形式
RE_CLASS_HOOK = re.compile(r'mod:hook(_safe)?\(\s*"([^"]+)"\s*,\s*"([^"]+)"')
RE_REQUIRE = re.compile(r'mod:hook_require\(\s*"([^"]+)"\s*,\s*function\s*\(\s*(\w+)\s*\)')
RE_REQUIRE_HOOK = re.compile(r'mod:hook(_safe)?\(\s*(\w+)\s*,\s*"([^"]+)"')

# 日志里的生命周期
RE_APPLIED = re.compile(r"\[MOD\]\[([^\]]+)\]\[INFO\] \(hook(?:_safe)?\): Hooking '([^']+)' from \[([^\]]+)\]")
RE_DELAYED = re.compile(r"\[MOD\]\[([^\]]+)\]\[INFO\] \((hook|hook_safe)\): \[([^.\]]+)\.([^\]]+)\] needs to be delayed")
RE_RESOLVED = re.compile(r"Attempting to hook \d+ delayed hooks? for object (\S+)")
RE_ERR_METHOD = re.compile(
    r"\[MOD\]\[([^\]]+)\]\[ERROR\] \((hook|hook_safe)\): trying to hook function or method that doesn't exist: \[([^.\]]+)\.([^\]]+)\]"
)
RE_ERR_OBJECT = re.compile(
    r"\[MOD\]\[([^\]]+)\]\[ERROR\] \((hook|hook_safe)\): trying to hook object that doesn't exist: (\S+)"
)


def expected_hooks():
    """从仓库源码里读出所有钩子。返回 [(类名或变量名, 方法, 机制, 来源文件)]"""
    found = []
    for path in sorted(MOD_SOURCES.glob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()

        # 先按行号收集 hook_require 的 (行号, 变量名 -> 路径)
        requires = [(text[: m.start()].count("\n"), m.group(2), m.group(1)) for m in RE_REQUIRE.finditer(text)]
        # 某个变量名在它前面最近一次 hook_require 用的路径
        def path_for(var, line_no):
            best = None
            for req_line, req_var, req_path in requires:
                if req_var == var and req_line <= line_no:
                    best = req_path
            return best

        for i, line in enumerate(lines):
            for m in RE_CLASS_HOOK.finditer(line):
                found.append((m.group(2), m.group(3), "class-name", path.name))
            for m in RE_REQUIRE_HOOK.finditer(line):
                var, method = m.group(2), m.group(3)
                if var in ("_G", "CLASS", "mod", "self"):  # 明显不是 hook_require 的类变量
                    continue
                path_str = path_for(var, i)
                if path_str:  # 只有 hook_require 里的才认
                    found.append((var, method, "module-path:" + path_str, path.name))
    return found


def newest_log():
    base = os.path.join(os.environ.get("APPDATA", ""), "Fatshark", "Darktide", "console_logs")
    logs = glob.glob(os.path.join(base, "console-*.log"))
    if not logs:
        return None
    return max(logs, key=os.path.getmtime)


def parse_log(path, mod_name):
    applied, delayed, resolved = set(), set(), set()
    err_method, err_object = set(), set()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = RE_APPLIED.search(line)
            if m and m.group(1) == mod_name:
                applied.add((m.group(3), m.group(2)))
            m = RE_DELAYED.search(line)
            if m and m.group(1) == mod_name:
                delayed.add((m.group(3), m.group(4)))
            m = RE_RESOLVED.search(line)
            if m:
                resolved.add(m.group(1))
            m = RE_ERR_METHOD.search(line)
            if m and m.group(1) == mod_name:
                err_method.add((m.group(3), m.group(4)))
            m = RE_ERR_OBJECT.search(line)
            if m and m.group(1) == mod_name:
                err_object.add(m.group(3))
    return applied, delayed, resolved, err_method, err_object


def session_evidence(log_path):
    """这份日志够不够用来判定钩子失效？

    延迟钩子和按路径注册的钩子要等游戏把对应模块 require 进来才会出现
    （视图 / AuspexScanningEffects / MinigameSystem 都是进游戏后才有）。所以
    "刚重启、只待了一会儿"的日志必然一堆 DEAD/MISSING —— 那是没跑到，不是坏了。
    返回（日志跨度秒数，进图标记次数）。
    """
    stamps = []
    mission_markers = 0
    time_pattern = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.\d{3}")
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = time_pattern.match(line)
            if m:
                stamps.append(int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)))
            if "num_missions_started" in line:
                mission_markers += 1

    if len(stamps) < 2:
        return 0, mission_markers

    duration = stamps[-1] - stamps[0]
    if duration < 0:          # 跨过午夜
        duration += 24 * 3600
    return duration, mission_markers


def main(argv):
    mod_name = "NoBrainer"
    args = list(argv[1:])
    if "--mod" in args:
        i = args.index("--mod")
        mod_name = args[i + 1]
        del args[i : i + 2]

    log_path = args[0] if args else newest_log()
    if not log_path or not os.path.exists(log_path):
        print("找不到日志；用法: python tools/check_hooks.py [日志路径]")
        return 1

    hooks = expected_hooks()
    applied, delayed, resolved, err_method, err_object = parse_log(log_path, mod_name)
    methods_seen = {}
    for class_name, method in applied:
        methods_seen.setdefault(method, set()).add(class_name)

    duration, mission_markers = session_evidence(log_path)
    weak = duration < 180 or mission_markers == 0

    print(f"仓库里注册的钩子: {len(hooks)}   日志: {os.path.basename(log_path)}   mod: {mod_name}")
    print(f"日志跨度 {duration // 60} 分 {duration % 60} 秒，进图标记 {mission_markers} 次"
          + ("   ⚠️ 太短，DEAD/MISSING 不能当结论" if weak else ""))
    print()

    counts = {"OK": 0, "OK(延迟后挂上)": 0, "DEAD": 0, "ERROR": 0, "MISSING": 0}
    for name, method, mechanism, source in hooks:
        path_based = mechanism.startswith("module-path:")
        if (name, method) in err_method or name in err_object:
            status = "ERROR"
            note = "Darktide Mod Framework 报错：方法或类不存在"
        elif (name, method) in applied:
            status = "OK"
            note = "类是在游戏里之后才构造的，延迟后挂上了" if (name, method) in delayed else ""
        elif path_based and method in methods_seen:
            # 按路径挂的钩子，Darktide Mod Framework 打印的"类名"是从全局表里猜的，变量名对不上很正常；
            # 只要这个方法确实被挂上了就算通过（路径写错的话日志里根本不会有这条）。
            status = "OK"
            seen = ", ".join(sorted(methods_seen[method]))
            note = f"按路径钩；日志里挂在了 [{seen}]"
        elif (name, method) in delayed and name not in resolved:
            status = "DEAD"
            note = "一直是延迟状态，类始终没出现 —— 基本就是游戏更新改了类名"
        else:
            status = "MISSING"
            note = "日志里完全没出现（这份日志没跑到，或者钩子根本没注册）"
        counts[status] = counts.get(status, 0) + 1
        flag = "" if status == "OK" else "  <<<"
        print(f"{status:<4} {name}.{method:<28} [{mechanism}] {note}{flag}")

    print()
    print("统计: " + "  ".join(f"{k}={v}" for k, v in counts.items() if v))
    bad = counts["DEAD"] + counts["ERROR"] + counts["MISSING"]
    if weak:
        print("⚠️ 这份日志太短（或没进过图）：上面的 DEAD/MISSING 绝大多数只是还没跑到，不能当成钩子失效。")
        print("   拿一份真正打完一局的日志再跑一次；只有 ERROR 行在任何长度下都算真问题。")
        return 1 if counts["ERROR"] else 0
    if bad:
        print(f"有 {bad} 个钩子需要看：DEAD 多半是类被改名，ERROR 是方法被改名，MISSING 得先确认这份日志跑过没有。")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""嬉皮小剧场「外部智能体接力」命令行助手（只用 Python 标准库）。

主智能体用：  check / status / pending / done / cmd
监听模式用：  wait（用户在软件里点哪一步，智能体就接着做哪一步；见 SKILL.md「监听模式」）
子智能体用：  unpack / answer / fail
目录默认是软件的 AgentBridge（可用 --dir 或环境变量 XIPI_BRIDGE 改）。
"""
import difflib
import argparse, datetime, json, os, sys, time

RELATIVE = "Library/Application Support/Xipixiaojuchang/AgentBridge"


def default_dir():
    """软件的 AgentBridge 目录。沙箱里 $HOME 常被改成别的路径，所以再按系统账号的真实家目录找一遍。"""
    candidates = [os.path.join(os.path.expanduser("~"), RELATIVE)]
    try:
        import pwd
        candidates.append(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, RELATIVE))
    except Exception:
        pass
    for path in candidates:
        if os.path.isdir(path):
            return path
    return candidates[-1]


def bridge_dir(args):
    return os.path.expanduser(args.dir or os.environ.get("XIPI_BRIDGE") or default_dir())


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json_atomic(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(tmp, path)


def parse_time(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def heartbeat_age(status):
    return (datetime.datetime.now(datetime.timezone.utc) - parse_time(status["updatedAt"])).total_seconds()


def load_status(root):
    path = os.path.join(root, "status.json")
    if not os.path.exists(path):
        return None
    try:
        return read_json(path)
    except (OSError, ValueError):
        return None   # 正好在改写：当作暂时读不到


def check_project_filter(root, project, strict=True):
    """`--project` 必须和软件里的项目名（或 id）**完全一样**。写错了（比如只写「72」、软件里叫「项目 72」）就报错并列出现有项目，
    别悄悄当成「别的项目的请求」（2026-10-10：智能体因此把本项目的 3 个请求当成别人的，漏答了）。返回 False = 已经打印了错误。"""
    if not project:
        return True
    status = load_status(root)
    if status is None:
        return True            # 读不到状态：交给各命令自己报「软件没开」
    projects = status.get("projects", [])
    if any(project in (p.get("id"), p.get("name")) for p in projects):
        return True
    if any(project in (r.get("project"), r.get("projectName")) for r in status.get("pendingRequests", [])):
        return True
    mark = "✗" if strict else "⚠"
    print(f"{mark} 软件里没有叫「{project}」的项目：--project 要和项目名或 id 完全一样（项目名是「项目 72」就不能只写「72」）。"
          "（还没导入剧本的项目状态里不会列出。）")
    if projects:
        guess = [p for p in projects if project in (p.get("name") or "") or (p.get("name") or "") in project]
        if guess:
            print("你是不是要找：" + "、".join(f"「{p.get('name')}」(id {p.get('id')})" for p in guess[:5]))
        shown = projects[:8]
        more = f" …共 {len(projects)} 个，完整列表用 `xipi status`" if len(projects) > len(shown) else ""
        print("现有项目：" + "、".join(f"「{p.get('name')}」" for p in shown) + more)
    return not strict       # 等待（wait）只警告、继续等：项目也许马上就会在软件里出现；检查类命令直接报错


def missing_request_notice(root, request_id):
    """请求文件不在时：是真的被取消 / 已答 / 已超时，还是你看的收件目录根本不对？
    目录不对时必须说清楚，别让人当成取消丢掉（2026-10-10：子智能体的默认目录找不到请求，误报 CANCELLED，3 个请求因此漏答）。
    返回 None = 确实是取消 / 已答 / 已超时。"""
    status = load_status(root)
    if status is None:
        return (f"收件目录不对（这不是取消！）：{root} 里没有 status.json，不是软件正在用的 AgentBridge 目录。\n"
                "用 --dir 指定真实的收件目录（派你活的主智能体给你的那个，在 `xipi check` 输出的「目录」里），再运行一次这条命令。"
                "在这之前不要写回答，也不要当成取消丢掉。")
    pending_ids = [r.get("id") for r in status.get("pendingRequests", []) if r.get("id")]
    if request_id in pending_ids:
        return (f"收件目录不对（这不是取消！）：软件的状态文件里这个请求还在等回答，但 {root}/requests 里没有它的文件，"
                "说明你看的目录不是软件正在用的那个。用 --dir 指定真实的收件目录再试，不要当成取消丢掉。")
    # id 写错了一两个字符（手打 / 凭记忆抄的）：和一个还在等回答的请求只差几位，那就是写错了，不是取消
    # （2026-10-11：把 15718ca6-… 写成 15718ca3-…，报了假的「已取消」，这个请求其实一直在等）
    near = difflib.get_close_matches(request_id, pending_ids, n=1, cutoff=0.9)
    if near:
        return (f"这个 id 写错了（这不是取消！）：软件里没有 {request_id}，但有一个差几个字符的请求还在等回答：{near[0]}。\n"
                "请求 id 必须从 `xipi wait` / `xipi pending` 的输出里**逐字复制**，不要凭记忆手打。用这个 id 再做一次，不要当成取消丢掉。")
    try:
        age = heartbeat_age(status)
    except (KeyError, ValueError):
        age = 0
    if age > 300:
        return (f"不确定是不是取消：{root}/status.json 已经 {int(age)} 秒没更新，这个目录可能不是软件正在用的（或软件已退出）。"
                "先用 --dir 指定真实的收件目录再试一次，再决定。")
    return None


# ---------- 主智能体 ----------

def cmd_check(args):
    """预检：软件在线、接力开着。退出码 0 = 可以开工。"""
    root = bridge_dir(args)
    status = load_status(root)
    if status is None:
        print("没有找到 status.json：软件没开，或设置里还没打开「外部智能体接力」。")
        print("让用户：打开软件 → 设置 → 剧本流水线 → 打开「外部智能体接力」→ 保存。")
        return 1
    age = heartbeat_age(status)
    if not status.get("agentMode") or age > 15:
        print(f"状态文件 {int(age)} 秒没更新，或接力已关闭（agentMode={status.get('agentMode')}）：软件没在跑，或接力被关了。")
        return 1
    print(f"OK：软件在线（心跳 {int(age)} 秒前），版本 {status.get('appVersion')}，目录 {root}")
    return 0


def cmd_status(args):
    root = bridge_dir(args)
    status = load_status(root)
    if status is None:
        print("读不到 status.json（软件没开或接力没打开）")
        return 1
    if not check_project_filter(root, args.project):
        return 2
    if args.json:
        projects = [p for p in status["projects"] if not args.project or args.project in (p["id"], p["name"])]
        print(json.dumps({**status, "projects": projects}, ensure_ascii=False, indent=1))
        return 0
    age = int(heartbeat_age(status))
    online = status.get("agentMode") and age <= 15
    print(f"软件{'在线' if online else '【离线或接力已关】'}（心跳 {age} 秒前）· {status.get('appVersion')} · 待回答请求 {len(status['pendingRequests'])}")
    for p in status["projects"]:
        if args.project and args.project not in (p["id"], p["name"]):
            continue
        done_split = sum(1 for e in p["episodes"] if e.get("split"))
        done_named = sum(1 for e in p["episodes"] if e.get("named"))
        done_story = sum(1 for e in p["episodes"] if e.get("storyboardCards", 0) > 0)
        print(f"\n项目「{p['name']}」 id={p['id']}")
        print(f"  {len(p['episodes'])} 集 · 已分割 {done_split} · 已命名 {done_named} · 已推理分镜 {done_story} · 生图卡 {p['imageCards']} · 生视频卡 {p['videoCards']}")
        b = p.get("batch")
        if b:
            state = "已结束" if b["finished"] else "进行中"
            extra = f" · 新建卡片 {b['created']}" if b["kind"] in ("extract", "infer") else ""
            skipped = f" · 没轮到 {b['skipped']} 集" if b["skipped"] else ""
            print(f"  {b['title']}（{b['kind']}）{state}：成功 {b['succeeded']}/{b['total']} · 失败 {len(b['failed'])}{extra}{skipped}")
            for f in b["failed"]:
                print(f"    ✗ {f['label']}：{f['message']}")
        # 注意：status.json 里没有值的字段（比如不挂在某一集上的任务没有 episode / slot）整个不出现，不是 null——一律用 .get
        for j in p.get("jobs", []):
            where = f"第 {j['episode']} 集" if j.get("episode") else (j.get("slot") or "项目")
            flag = "进行中" if j.get("active") else ("失败" if j.get("failed") else "结束")
            print(f"  任务[{flag}] {j.get('step', '')}（{where}）：{j.get('note', '')}")
        missing = [e["number"] for e in p["episodes"] if not e.get("split")]
        if p["episodes"] and missing and len(missing) <= 20:
            print(f"  还没分割的集：{missing}")
        # 分割过、还没命名（各段没有【场景】头行）的集：推理分镜会被软件拒绝，先发 name
        unnamed = [e["number"] for e in p["episodes"] if e.get("split") and not e.get("named")]
        if unnamed:
            print(f"  还没命名（各段的场景 / 角色 / 道具）的集：{unnamed if len(unnamed) <= 20 else str(len(unnamed)) + ' 集'}（推理分镜之前要先 name）")
        # 分割过但没有时间标记（--- 00:00 - 00:30）的集：推理分镜没法核对段数，多半是分割格式不对
        unmarked = [e["number"] for e in p["episodes"] if e.get("split") and not e.get("segments")]
        if unmarked:
            print(f"  ⚠ 分割后没有时间标记的集（格式可能不对）：{unmarked if len(unmarked) <= 20 else str(len(unmarked)) + ' 集'}")
    return 0


def cmd_pending(args):
    root = bridge_dir(args)
    status = load_status(root)
    if status is None:
        print("读不到 status.json")
        return 1
    if not check_project_filter(root, args.project):
        return 2
    now = datetime.datetime.now(datetime.timezone.utc)
    requests = status["pendingRequests"]
    others = []
    if args.project:
        # 只列本次任务那个项目的请求；别的项目的（比如用户在软件里手动导入的剧本）不是你的活，只报个数
        mine = [r for r in requests if args.project in (r.get("project"), r.get("projectName"))]
        others = [r for r in requests if r not in mine]
        requests = mine
    for r in requests:
        age = int((now - parse_time(r["createdAt"])).total_seconds())
        where = f"第 {r['episode']} 集" if r.get("episode") else "-"
        taken = "已领" if r.get("claimed") else "未领"
        print(f"{r['id']}\t{r['kind']}\t{r.get('projectName') or '-'}\t{where}\t{taken}\t等了 {age} 秒")
    if not requests:
        print("（没有待回答的请求）")
    if others:
        names = sorted({r.get("projectName") or r.get("project") or "?" for r in others})
        print(f"另有 {len(others)} 个其他项目的请求（{'、'.join(names)}）：不是你这次的任务，不要分配、不要回答、不要取消。")
    return 0


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def claim_age(root, request_id):
    """认领了多久（秒）；没人认领 = None。"""
    path = os.path.join(root, "claims", request_id + ".json")
    if not os.path.exists(path):
        return None
    try:
        return (datetime.datetime.now(datetime.timezone.utc) - parse_time(read_json(path)["at"])).total_seconds()
    except (OSError, ValueError, KeyError):
        try:
            return time.time() - os.path.getmtime(path)
        except OSError:
            return 0


def waiting_requests(root, project=None, reclaim_after=1800):
    """收件目录里**没人领**的请求（直接看目录，比状态文件更及时）。
    认领超过 reclaim_after 秒、请求还在 = 领的人没干完（崩了 / 对话被关了），算没人领，重新交出来。"""
    folder = os.path.join(root, "requests")
    if not os.path.isdir(folder):
        return [], 0
    free, taken = [], 0
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".json"):
            continue
        try:
            request = read_json(os.path.join(folder, name))
        except (OSError, ValueError):
            continue   # 正好在写
        if project and project not in (request.get("project"), request.get("projectName")):
            continue
        age = claim_age(root, name[:-5])
        if age is None or age > reclaim_after:
            free.append(request)
        else:
            taken += 1
    return free, taken


def cmd_wait(args):
    """监听模式的「等」：阻塞到有没人领的请求出现就返回（并替你登记认领），或超时。
    退出码：0 = 有请求（逐行列在输出里）；4 = 等到超时也没有新请求（再调一次就行）；1 = 软件离线 / 接力没开。"""
    root = bridge_dir(args)
    check_project_filter(root, args.project, strict=False)       # 写错了会先警告，但继续等（项目也许还没导入剧本）
    started = time.time()
    deadline = started + args.timeout
    # --max-active N：同时在做的（已认领、还没答的）请求不超过 N 个。空位由这里按收件目录里的真实情况算，主智能体不用自己数、
    # 也不用记「还有哪些 id 排着队」：一次点 50 集，每次只交出 N − 在做的 个，其余留在软件的队列里，等有人做完腾出位置再领
    # （2026-10-11：原来一次把 50 个全部登记认领，主智能体得记住 46 个排队的 id，排队的认领过了期还会被当成「新请求」重新交出来）
    limit = args.max_active if args.max_active and args.max_active > 0 and not args.no_claim else 0
    busy = queued = 0
    while True:
        status = load_status(root)
        online = bool(status) and bool(status.get("agentMode")) and heartbeat_age(status) <= 15
        if online:
            free, taken = waiting_requests(root, args.project, args.reclaim_after)
            busy, queued = taken, len(free)
            if limit:
                free.sort(key=lambda r: r.get("createdAt") or "")      # 先来的先做
                free = free[:max(0, limit - taken)]
            if free:
                now = datetime.datetime.now(datetime.timezone.utc)
                os.makedirs(os.path.join(root, "claims"), exist_ok=True)
                for r in free:
                    age = int((now - parse_time(r["createdAt"])).total_seconds()) if r.get("createdAt") else 0
                    where = f"第 {r['episode']} 集" if r.get("episode") else "-"
                    print(f"{r['id']}\t{r['kind']}\t{r.get('projectName') or '-'}\t{where}\t等了 {age} 秒")
                    if not args.no_claim:
                        write_json_atomic(os.path.join(root, "claims", r["id"] + ".json"), {"id": r["id"], "at": now_iso()})
                if not args.no_claim:
                    print(f"（上面 {len(free)} 个已替你登记认领，软件左栏 AI 图标会变绿；不会再重复交给你。每个 id 交给一个子智能体做：unpack → 写 → answer。）")
                if taken:
                    print(f"（另有 {taken} 个已被领走在做。）")
                if limit and queued > len(free):
                    print(f"（还有 {queued - len(free)} 个在排队，没有领：同时最多 {limit} 个。有子智能体做完腾出位置后，再 wait 就会交给你。）")
                return 0
        if time.time() >= deadline:
            break
        time.sleep(1)
    if not online:
        print("软件离线，或「外部智能体接力」没开：让用户打开软件 → 设置 → 剧本流水线 → 打开「外部智能体接力」→ 保存。软件回来后再 wait 就行。")
        return 1
    if limit and queued:
        print(f"（等了 {int(time.time() - started)} 秒：{busy} 个已领走在做，同时最多 {limit} 个，另有 {queued} 个在排队，暂时没有空位。有子智能体做完后再 wait。）")
        return 4
    print(f"（等了 {int(time.time() - started)} 秒，没有新的待回答请求。）")
    return 4


def cmd_cmd(args):
    """发一条命令，等软件的受理结果（受理 ≠ 做完，进度看 status）。"""
    root = bridge_dir(args)
    try:
        body = json.loads(args.json_text)
    except ValueError as e:
        print(f"命令不是有效的 JSON：{e}")
        return 2
    cid = f"c{int(time.time())}-{os.getpid()}"
    os.makedirs(os.path.join(root, "commands"), exist_ok=True)
    write_json_atomic(os.path.join(root, "commands", cid + ".json"), {**body, "id": cid})
    result_file = os.path.join(root, "results", cid + ".json")
    deadline = time.time() + args.wait
    while time.time() < deadline:
        if os.path.exists(result_file):
            try:
                result = read_json(result_file)
            except ValueError:
                time.sleep(0.2)
                continue
            print(json.dumps(result, ensure_ascii=False))
            return 0 if result.get("ok") else 1
        time.sleep(0.3)
    print(json.dumps({"ok": False, "message": f"{args.wait} 秒内没有受理结果：软件没开，或接力没打开"}, ensure_ascii=False))
    return 1


# ---------- 子智能体 ----------

def work_dir(root, request_id):
    """工作目录放在收件目录里（智能体已经被授权访问这里；系统临时目录在沙箱里常常没有权限）。软件会定期清理。"""
    return os.path.join(root, "work", request_id)


def cmd_unpack(args):
    """把请求拆成几个普通文本文件（请求里的正文是一整行很长的 JSON，直接读容易被截断），并登记已领取。"""
    root = bridge_dir(args)
    path = os.path.join(root, "requests", args.id + ".json")
    if not os.path.exists(path):
        notice = missing_request_notice(root, args.id)
        if notice:
            print(notice)
            return 4
        print("CANCELLED：请求文件已经不在了（这一步被取消或已超时），不用做，也不要写回答。")
        return 3
    request = read_json(path)
    # 登记「我领了这个请求」：软件据此知道有智能体在干活（左栏 AI 图标变绿），状态文件里也标「已领」
    os.makedirs(os.path.join(root, "claims"), exist_ok=True)
    write_json_atomic(os.path.join(root, "claims", args.id + ".json"),
                      {"id": args.id, "at": datetime.datetime.now(datetime.timezone.utc).isoformat()})
    out = work_dir(root, args.id)
    os.makedirs(out, exist_ok=True)
    for name in ("system", "user"):
        with open(os.path.join(out, name + ".txt"), "w", encoding="utf-8") as f:
            f.write(request[name])
    meta = {k: request.get(k) for k in ("id", "kind", "project", "projectName", "episode", "episodeTitle")}
    meta["images"] = request.get("images", [])
    with open(os.path.join(out, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    print(out)
    print(f"  system.txt  要遵守的完整工作要求（{len(request['system'])} 字）")
    print(f"  user.txt    要处理的内容（{len(request['user'])} 字）")
    print(f"  meta.json   这是哪一步 / 哪个项目 / 哪一集；images 里有路径就读图")
    print(f"  做完把结果正文写进 {os.path.join(out, 'answer.txt')}，再运行：xipi.py answer {args.id}")
    return 0


def cmd_answer(args):
    root = bridge_dir(args)
    if not os.path.exists(os.path.join(root, "requests", args.id + ".json")):
        notice = missing_request_notice(root, args.id)
        if notice:
            print(notice)
            return 4
        print("CANCELLED：请求已被取消，丢弃，没有写回答。")
        return 3
    source = args.file or os.path.join(work_dir(root, args.id), "answer.txt")
    with open(source, encoding="utf-8") as f:
        text = f.read()
    if not text.strip():
        print("回答是空的，没有写。要么写出结果，要么用 fail 说明原因。")
        return 2
    os.makedirs(os.path.join(root, "responses"), exist_ok=True)
    write_json_atomic(os.path.join(root, "responses", args.id + ".json"), {"id": args.id, "ok": True, "text": text})
    print(f"已回答 {args.id}（{len(text)} 字）")
    return 0


def cmd_fail(args):
    root = bridge_dir(args)
    if not os.path.exists(os.path.join(root, "requests", args.id + ".json")):
        notice = missing_request_notice(root, args.id)
        if notice:
            print(notice)
            return 4
        print("CANCELLED：请求已被取消，丢弃。")
        return 3
    os.makedirs(os.path.join(root, "responses"), exist_ok=True)
    write_json_atomic(os.path.join(root, "responses", args.id + ".json"), {"id": args.id, "ok": False, "error": args.reason})
    print(f"已回报失败 {args.id}：{args.reason}")
    return 0


def cmd_done(args):
    """汇报「完成」之前的核对（2026-10-10：智能体把还在等回答的 3 个请求当成「旧的、已取消的」跳过，报了假完成）。
    退出码 0 = 这个项目没有待回答的请求、批量任务也已结束，才可以说完成；5 = 还没完成；1 = 软件离线。"""
    root = bridge_dir(args)
    status = load_status(root)
    if status is None:
        print("读不到 status.json（软件没开或接力没打开）")
        return 1
    if not check_project_filter(root, args.project):
        return 2            # 项目名写错时不能当成「没有待回答的请求」放行
    def is_mine(request):
        return not args.project or args.project in (request.get("project"), request.get("projectName"))
    problems = []
    pending = [r for r in status["pendingRequests"] if is_mine(r)]
    if pending:
        parts = [f"{r['kind']}" + (f"第 {r['episode']} 集" if r.get("episode") else "") + f"（{r['id'][:8]}）" for r in pending[:10]]
        more = f" 等 {len(pending)} 个" if len(pending) > 10 else ""
        problems.append(f"还有 {len(pending)} 个待回答的请求：{'、'.join(parts)}{more}")
    for p in status["projects"]:
        if args.project and args.project not in (p["id"], p["name"]):
            continue
        b = p.get("batch")
        if b and not b.get("finished"):
            problems.append(f"项目「{p['name']}」的批量任务「{b['title']}」（{b['kind']}）还没结束：成功 {b['succeeded']}/{b['total']} · 失败 {len(b['failed'])}")
    if problems:
        print("✗ 还不能说完成：")
        for line in problems:
            print("  - " + line)
        print("列表里还有的请求就是软件在等的，**不是旧的、也不是已取消的**：对每个 id 运行 unpack → 亲手写 → answer；"
              "子智能体报了 CANCELLED 也一样：id 还在这个列表里就没取消（多半是它看的收件目录不对），重派并写明 --dir；真做不了用 fail。做完再运行本命令。")
        return 5
    print("✓ 没有待回答的请求，批量任务也已结束：可以汇报完成（汇报时附上 xipi status 的数字）。")
    return 0


def main():
    parser = argparse.ArgumentParser(description="嬉皮小剧场外部智能体接力助手")
    parser.add_argument("--dir", help="AgentBridge 目录（默认软件的数据目录）")
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("check", help="预检：软件在线、接力开着").set_defaults(run=cmd_check)
    p = sub.add_parser("status", help="进度摘要")
    p.add_argument("--project", help="只看这个项目（id 或名字）")
    p.add_argument("--json", action="store_true", help="输出原始 JSON")
    p.set_defaults(run=cmd_status)
    p = sub.add_parser("pending", help="列出待回答的请求")
    p.add_argument("--project", help="只看这个项目的（id 或名字）；别的项目的只报个数")
    p.set_defaults(run=cmd_pending)
    p = sub.add_parser("done", help="汇报完成之前的核对：没有待回答的请求、批量任务已结束（退出码 0 才能说完成）")
    p.add_argument("--project", help="只核对这个项目（id 或名字）")
    p.set_defaults(run=cmd_done)
    p = sub.add_parser("wait", help="（监听模式）等用户在软件里点出新请求：有就返回并认领，没有等到超时")
    p.add_argument("--timeout", type=float, default=50, help="最多等多少秒（默认 50；超时退出码 4，再调一次就行）")
    p.add_argument("--project", help="只等这个项目的（id 或名字）；默认所有项目")
    p.add_argument("--no-claim", action="store_true", help="只看不认领")
    p.add_argument("--reclaim-after", type=float, default=1800,
                   help="认领超过这么多秒、请求还在，就当没人领（默认 1800；会思考的模型一个请求要好几分钟，10 分钟太短，会把还在做的重新交出来）")
    p.add_argument("--max-active", type=int, default=0,
                   help="同时在做的请求最多这么多个（默认 0 = 不限）：只交出还有空位的那几个，其余留在队列里；不能和 --no-claim 一起用")
    p.set_defaults(run=cmd_wait)
    p = sub.add_parser("cmd", help="发一条命令")
    p.add_argument("json_text", help='例如 \'{"cmd":"split","project":"<id>"}\'')
    p.add_argument("--wait", type=float, default=10, help="等受理结果的秒数")
    p.set_defaults(run=cmd_cmd)
    p = sub.add_parser("unpack", help="（子智能体）把请求拆成文本文件")
    p.add_argument("id"); p.set_defaults(run=cmd_unpack)
    p = sub.add_parser("answer", help="（子智能体）提交回答")
    p.add_argument("id"); p.add_argument("file", nargs="?"); p.set_defaults(run=cmd_answer)
    p = sub.add_parser("fail", help="（子智能体）报告做不了")
    p.add_argument("id"); p.add_argument("reason"); p.set_defaults(run=cmd_fail)
    args = parser.parse_args()
    sys.exit(args.run(args))


if __name__ == "__main__":
    main()

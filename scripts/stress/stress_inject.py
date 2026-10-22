#!/usr/bin/env python3
"""嬉皮小剧场 · 压测卡片注入/清理（一次性工具）

用法:
    python3 stress_inject.py inject   # 备份 + 注入 100 视频卡 + 100 生图卡
    python3 stress_inject.py clean    # 按 key 移除所有压测卡片 + 项目元数据 + 缓存目录

安全设计:
- 注入前 App 必须退出（否则会被 App 的持久化覆盖）
- 注入前全量备份 4 个 json + 偏好设置 plist
- 卡片模型名写 "压测-勿用"（未配置渠道）→ 即使误点生成也只会报"未配置模型"，不会真提交
"""
import json, plistlib, uuid, shutil, subprocess, sys, datetime, pathlib

HOME = pathlib.Path.home()
SUP = HOME / 'Library/Application Support/XipixiaojuchangOpen'
PREF = HOME / 'Library/Preferences/io.github.xipiplay.xipixiaojuchang.plist'
DOMAIN = 'io.github.xipiplay.xipixiaojuchang'

KEY = 'STRESS-100-100'          # 压测项目 key（清理按它）
NAME = '压测100+100'              # 项目显示名
N = 100                          # 视频卡/生图卡各自的数量
FAKE_MODEL = '压测-勿用'           # 不存在的模型名 —— 防误提交的第二道保险
VIDEO_SECONDS = 30               # 视频卡时长（贴近真实对话剧）


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def ref_now():
    ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
    return (datetime.datetime.now(datetime.timezone.utc) - ref).total_seconds()


def load_meta():
    pl = plistlib.load(open(PREF, 'rb'))
    raw = pl.get('projectMetas')
    return json.loads(raw.decode('utf-8')) if raw else {}


def write_meta(metas):
    data = json.dumps(metas, ensure_ascii=False).encode('utf-8')
    subprocess.run(['defaults', 'write', DOMAIN, 'projectMetas', '-data', data.hex()], check=True)


def inject():
    ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    bk = SUP / 'backups' / f'inject-{ts}'
    bk.mkdir(parents=True)
    for f in ('shots.json', 'imageItems.json', 'tasks.json', 'library.json'):
        shutil.copy2(SUP / f, bk / f)
    shutil.copy2(PREF, bk / 'io.github.xipiplay.xipixiaojuchang.plist')
    print('备份 →', bk)

    iso = now_iso()
    shots = json.load(open(SUP / 'shots.json', encoding='utf-8'))
    before_shots = len(shots)
    for i in range(1, N + 1):
        shots.append({
            'id': str(uuid.uuid4()).upper(),
            'projectKey': KEY,
            'model': FAKE_MODEL,
            'providerID': '',
            'prompt': f'【压测卡片 {i}】仅供性能测试，请勿生成。',
            'duration': VIDEO_SECONDS,
            'aspectRatio': '16:9',
            'resolution': 'p720',
            'generateAudio': True,
            'watermark': False,
            'imageRefs': [], 'videoRefs': [], 'audioRefs': [],
            'taskIDs': [],
            'createdAt': iso,
        })
    json.dump(shots, open(SUP / 'shots.json', 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'shots.json: {before_shots} → {len(shots)}')

    items = json.load(open(SUP / 'imageItems.json', encoding='utf-8'))
    before_items = len(items)
    for i in range(1, N + 1):
        items.append({
            'id': str(uuid.uuid4()).upper(),
            'projectKey': KEY,
            'name': f'压测图 {i}',
            'prompt': f'【压测卡片 {i}】仅供性能测试，请勿生成。',
            'model': FAKE_MODEL,
            'aspectRatio': 'ratio16x9',
            'quality': 'k2',
            'status': 'pending',
            'results': [],
            'imageRefs': [],
        })
    json.dump(items, open(SUP / 'imageItems.json', 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'imageItems.json: {before_items} → {len(items)}')

    metas = load_meta()
    metas[KEY] = {'name': NAME, 'createdAt': ref_now(), 'updatedAt': ref_now()}
    write_meta(metas)
    print('项目元数据已写入:', NAME, '| key =', KEY)


def add(count):
    """在现有压测项目上**追加** count 张视频卡 + count 张生图卡（同 key、同名改数字）。"""
    ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    bk = SUP / 'backups' / f'add-{count}-{ts}'
    bk.mkdir(parents=True)
    for f in ('shots.json', 'imageItems.json', 'tasks.json', 'library.json'):
        shutil.copy2(SUP / f, bk / f)
    shutil.copy2(PREF, bk / 'io.github.xipiplay.xipixiaojuchang.plist')
    print('备份 →', bk)

    iso = now_iso()
    shots = json.load(open(SUP / 'shots.json', encoding='utf-8'))
    items = json.load(open(SUP / 'imageItems.json', encoding='utf-8'))
    v = sum(1 for s in shots if s.get('projectKey') == KEY)
    g = sum(1 for i in items if i.get('projectKey') == KEY)
    if v == 0:
        print('⚠️ 压测项目不存在，请先 inject'); return

    for i in range(v + 1, v + count + 1):
        shots.append({
            'id': str(uuid.uuid4()).upper(),
            'projectKey': KEY,
            'model': FAKE_MODEL,
            'providerID': '',
            'prompt': f'【压测卡片 {i}】仅供性能测试，请勿生成。',
            'duration': VIDEO_SECONDS,
            'aspectRatio': '16:9',
            'resolution': 'p720',
            'generateAudio': True,
            'watermark': False,
            'imageRefs': [], 'videoRefs': [], 'audioRefs': [],
            'taskIDs': [],
            'createdAt': iso,
        })
    for i in range(g + 1, g + count + 1):
        items.append({
            'id': str(uuid.uuid4()).upper(),
            'projectKey': KEY,
            'name': f'压测图 {i}',
            'prompt': f'【压测卡片 {i}】仅供性能测试，请勿生成。',
            'model': FAKE_MODEL,
            'aspectRatio': 'ratio16x9',
            'quality': 'k2',
            'status': 'pending',
            'results': [],
            'imageRefs': [],
        })
    json.dump(shots, open(SUP / 'shots.json', 'w', encoding='utf-8'), ensure_ascii=False)
    json.dump(items, open(SUP / 'imageItems.json', 'w', encoding='utf-8'), ensure_ascii=False)

    total_v, total_g = v + count, g + count
    metas = load_meta()
    old = metas.get(KEY, {})
    metas[KEY] = {'name': f'压测{total_v}+{total_g}',
                  'createdAt': old.get('createdAt', ref_now()),
                  'updatedAt': ref_now()}
    write_meta(metas)
    print(f'现在：视频 {total_v} + 生图 {total_g}，项目名「压测{total_v}+{total_g}」')


def clean():
    for f in ('shots.json', 'imageItems.json'):
        arr = json.load(open(SUP / f, encoding='utf-8'))
        kept = [x for x in arr if x.get('projectKey') != KEY]
        removed = len(arr) - len(kept)
        json.dump(kept, open(SUP / f, 'w', encoding='utf-8'), ensure_ascii=False)
        print(f'{f}: 移除 {removed} 条')
    metas = load_meta()
    if KEY in metas:
        del metas[KEY]
        write_meta(metas)
        print('元数据已移除')
    # 项目缓存目录（按显示名）
    for d in (SUP / 'Videos' / NAME,
              pathlib.Path.home() / 'Movies' / NAME):
        if d.exists():
            shutil.rmtree(d)
            print('缓存目录已删:', d)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'inject'
    if cmd == 'add':
        add(int(sys.argv[2]) if len(sys.argv) > 2 else 200)
    else:
        {'inject': inject, 'clean': clean}[cmd]()

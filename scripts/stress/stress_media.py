#!/usr/bin/env python3
"""压测 · 给卡片挂真实媒体（图片/视频/素材引用）——一次性工具

用法:
    python3 stress_media.py attach 100   # 给前 100 张压测分镜挂视频+素材引用、前 100 个压测生图挂结果
    python3 stress_media.py detach       # 撤掉挂载（删假任务、清引用/结果），保留压测卡片骨架

安全设计:
- 注入前 App 必须退出；先全量备份 4 个 json + plist
- 视频/图片只用**本地已有文件**（不下载、不生成、零成本）
- 假任务标 `completed`（不会被轮询），id 前缀 `stress-vid-`，detach 按前缀清理
"""
import json, pathlib, uuid, shutil, sys, datetime

HOME = pathlib.Path.home()
SUP = HOME / 'Library/Application Support/Xipixiaojuchang'
PREF = HOME / 'Library/Preferences/local.xipixiaojuchang.plist'
KEY = 'STRESS-100-100'
VIDEO_DIR = HOME / 'Desktop/缓存文件'
FAKE_TASK_PREFIX = 'stress-vid-'


def iso_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def ref_now():
    """Swift Date 默认编码：2001-01-01 起算秒数（imageItems.json 用）"""
    ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
    return (datetime.datetime.now(datetime.timezone.utc) - ref).total_seconds()


def backup(tag):
    ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    bk = SUP / 'backups' / f'{tag}-{ts}'
    bk.mkdir(parents=True)
    for f in ('shots.json', 'imageItems.json', 'tasks.json', 'library.json'):
        shutil.copy2(SUP / f, bk / f)
    shutil.copy2(PREF, bk / 'local.xipixiaojuchang.plist')
    print('备份 →', bk)


def load(name):
    return json.load(open(SUP / name, encoding='utf-8'))


def save(name, data):
    json.dump(data, open(SUP / name, 'w', encoding='utf-8'), ensure_ascii=False)


def attach(n):
    backup('media')
    vid_pool = sorted(p for p in VIDEO_DIR.rglob('*') if p.suffix.lower() in ('.mp4', '.mov'))
    img_pool = sorted(p for p in (SUP / 'Images').glob('*')
                      if p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.webp'))
    lib = load('library.json')
    lib_img_ids = [str(i['id']) for i in lib
                   if i.get('kind') == 'image' and i.get('localPath')
                   and pathlib.Path(i['localPath']).exists()]
    print(f'池：视频 {len(vid_pool)} | 图片 {len(img_pool)} | 素材引用候选 {len(lib_img_ids)}')
    assert vid_pool and img_pool and lib_img_ids, '素材池为空，中止'

    shots = load('shots.json')
    items = load('imageItems.json')
    tasks = load('tasks.json')
    tasks = [t for t in tasks if not str(t.get('id', '')).startswith(FAKE_TASK_PREFIX)]

    stress_shots = [s for s in shots if s.get('projectKey') == KEY][:n]
    stress_items = [i for i in items if i.get('projectKey') == KEY][:n]
    print(f'目标：分镜 {len(stress_shots)} 张（挂视频+3 个素材引用）| 生图 {len(stress_items)} 个（挂结果图）')

    now_iso = iso_now()
    now_ref = ref_now()
    for i, s in enumerate(stress_shots):
        tid = f'{FAKE_TASK_PREFIX}{i:03d}'
        vid = vid_pool[i % len(vid_pool)]
        tasks.append({
            'id': tid,
            'model': '压测-勿用',
            'providerID': '',
            'prompt': '',
            'duration': 30,
            'aspectRatio': '16:9',
            'resolution': 'p720',
            'generateAudio': True,
            'phase': 'completed',
            'createdAt': now_iso,
            'updatedAt': now_iso,
            'costFen': 0,
            'localVideoPath': str(vid),
            'groupID': KEY,
            'fileName': f'压测-{i + 1:03d}',
        })
        refs = [{'id': str(uuid.uuid4()).upper(),
                 'libraryItemID': lib_img_ids[(i * 3 + j) % len(lib_img_ids)]}
                for j in range(3)]
        s['prompt'] = f"【压测卡片 {i + 1}】仅供性能测试，请勿生成。\n参考素材：图1、图2、图3。"
        s['imageRefs'] = refs
        s['taskID'] = tid
        s['taskIDs'] = [tid]

    for i, it in enumerate(stress_items):
        img = img_pool[i % len(img_pool)]
        it['status'] = 'success'
        it['submittedAt'] = now_ref
        it['results'] = [{
            'id': str(uuid.uuid4()).upper(),
            'localPath': str(img),
            'resultURL': None,
            'createdAt': now_ref,
            'prompt': it.get('prompt'),
            'model': '压测-勿用',
            'aspectRatio': 'ratio16x9',
            'quality': 'k2',
            'imageRefs': [],
        }]

    save('shots.json', shots)
    save('imageItems.json', items)
    save('tasks.json', tasks)
    print(f'完成：{len(tasks)} 个任务（含 {len(stress_shots)} 个假任务）')


def detach():
    backup('media-detach')
    shots = load('shots.json')
    items = load('imageItems.json')
    tasks = load('tasks.json')
    before = len(tasks)
    tasks = [t for t in tasks if not str(t.get('id', '')).startswith(FAKE_TASK_PREFIX)]
    for s in shots:
        if s.get('projectKey') == KEY and str(s.get('taskID', '')).startswith(FAKE_TASK_PREFIX):
            s['taskID'] = None
            s['taskIDs'] = []
            s['imageRefs'] = []
            p = s.get('prompt', '')
            if '\n参考素材：' in p:
                s['prompt'] = p.split('\n参考素材：')[0]
    for it in items:
        if it.get('projectKey') == KEY and any(
                str(r.get('localPath', '')).startswith(str(SUP / 'Images')) for r in it.get('results', [])):
            it['results'] = []
            it['status'] = 'pending'
            it['submittedAt'] = None
    save('shots.json', shots)
    save('imageItems.json', items)
    save('tasks.json', tasks)
    print(f'已撤：任务 {before} → {len(tasks)}；分镜引用/假任务、生图结果已清')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'attach'
    if cmd == 'attach':
        attach(int(sys.argv[2]) if len(sys.argv) > 2 else 100)
    else:
        detach()

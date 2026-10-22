# 压测工具（一次性脚本，2026-09-26 收进仓库）

配合 `开发笔记.md` 的「2026-09-26 压测与治理定案」使用。

## 用法

```bash
# ⚠️ 所有操作前必须退出 App（App 内存里持有全量数据，运行时会覆盖文件）
osascript -e 'quit app "嬉皮小剧场"'

# 1) 造压测卡片：独立项目「压测N+N」，模型名写不存在的「压测-勿用」（误点生成只会报错，不会真提交）
python3 stress_inject.py inject      # 100 视频卡 + 100 生图卡
python3 stress_inject.py add 200     # 追加到 300+300

# 2) 挂真实媒体（可选，重载版）：前 N 张分镜挂本地视频 + 3 个素材引用，前 N 个生图挂结果图
#    视频池 = ~/Desktop/缓存文件 里的全部成片；图片池 = App 的 Images/ 目录
python3 stress_media.py attach 100
python3 stress_media.py detach       # 撤掉挂载（删假任务、清引用/结果）

# 3) 清场
python3 stress_inject.py clean       # 按 projectKey 移除压测卡片 + 项目元数据
```

## 安全约定

- 注入/挂载前**自动全量备份**到 `~/Library/Application Support/XipixiaojuchangOpen/backups/`
- 假数据一律可识别：项目 key `STRESS-100-100`、假任务 id 前缀 `stress-vid-`、模型名 `压测-勿用`
- 全程零成本：只用本地已有文件，不下载、不生成、不提交
- 日期格式别写错：`shots.json` / `tasks.json` 是 ISO8601 字符串；`imageItems.json` 是
  **2001-01-01 起算的秒数**（Swift Date 默认编码）——写错会让整个文件被"损坏备份"清空

## 验收读数

- `[watchdog] 主线程卡顿`（≥100ms）、`stall-*.txt`（≥250ms 自动抓栈）
- `[bodyEval]` 每秒视图重算次数
- 参考基线见 `开发笔记.md`（300+300：修复前 43 次/16.4s → 修复后 3 次/0.78s；挂媒体 12 次/2.3s）

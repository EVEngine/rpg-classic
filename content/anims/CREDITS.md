# 角色 / 怪物素材来源与授权（rpg-classic）

## 当前状态：怪物精灵来自两套 CC0 素材，主角仍是占位

本目录的敌人图集全部由 `tools/import_bestiary_assets.py` 生成。该脚本是唯一的
来源记录入口：它按固定 URL 下载上游压缩包、比对写入脚本里的 SHA-256、只解出用到
的成员，再把帧合成图集。`--check` 模式不联网写盘，只重算一遍并逐字节比对磁盘上的
文件——素材漂移会变成一次构建失败，而不是一次静默的美术替换。

```bash
cd .  # repository root
python tools/import_bestiary_assets.py           # 下载 + 解包 + 合成图集
python tools/import_bestiary_assets.py --check   # 只校验，不写盘
```

### 图集

| 图集 | 帧 | 网格 | 来源 | 授权 |
|---|---|---|---|---|
| `enemy-skeleton.png` | 48×64 | 3×4（N/E/S/W 各 3 帧） | Skeletons Rework 1.4 | CC0-1.0 |
| `enemy-skeleton-red-eyes.png` | 48×64 | 3×4 | 同上 | CC0-1.0 |
| `enemy-warrior-skeleton.png` | 48×64 | 3×4 | 同上 | CC0-1.0 |
| `enemy-demon-skeleton.png` | 48×64 | 3×4 | 同上 | CC0-1.0 |
| `enemy-beasts.png` | 32×32 | 5×4（18 格有内容） | Basic Green Monster Collection | CC0-1.0 |

上游信息逐包记录在 `assets/<pack>/SOURCE.json`：作者、上游页面、下载直链、
压缩包 SHA-256、授权与直链。压缩包本身也一起留在 `assets/<pack>/`，所以一次
离线重算（`--check`）不需要网络。

### 两个上游包

| 包 | 作者 | 上游 | 授权 |
|---|---|---|---|
| Skeletons Rework 1.4 | Jordan Irwin (AntumDeluge)、artisticdude、LordNeo | <https://opengameart.org/content/skeletons-rework> | CC0-1.0（包内 `LICENSE.txt` 即 CC0 全文） |
| Basic Green Monster Collection | darkagent（重上色自 Dungeon Crawl Stone Soup 的图块） | <https://opengameart.org/content/basic-green-monster-collection> | CC0-1.0（包内 `READ ME.txt`：「released in public domain (Common Creative Zero)」） |

两套都选择 **CC0 1.0** 而不是 CC-BY / CC-BY-SA：CC0 不要求署名，所以下游游戏
即使漏写 credits 也不构成侵权，而 BY-SA 的传染性会波及整个项目。署名仍然照写，
但这些记录是**为了可审计**，不是因为法律义务。

### 图集为什么长这样

- **骸骨四款是一张 3×4 的表。** 上游 README 写明「N/E/S/W format」「walking:
  12 frames (3 per direction)」，所以行序是 N、E、S、W，每行 3 帧行走。第 2 行
  正对镜头，`idle.s` 取该行中间帧——上游 README 的「idle (center frames)」。
- **妖物图集是逐张 32×32 拼出来的 5×4 网格。** 顺序固定在
  `import_bestiary_assets.py` 的 `BEAST_ORDER` 里，所以某个怪物的帧号不会漂。
  上游的 `Untitled-8.png` 是一个没名字的重复文件，故意不收。
- **没有做任何放大。** 帧保持原尺寸：`hero.json` 本来就是 32×48，小尺寸精灵是
  这套工作流既有的约定。要不要在绘制时放大是运行时的事，把它烘进图集等于发明数据。

## 程序化开发动画（2026-10-30补齐）

`hero.png`、`blade.png`、`palm.png`、`fireball.png` 和 `thunder.png` 由项目内
[`tools/build_placeholder_anims.py`](../../tools/build_placeholder_anims.py) 确定性生成。
它们是原创程序化开发占位素材，随项目采用 MIT 授权；不使用外部图片、不需要网络。
角色三张为 128×96（32×48、4×2），火球与雷电为 128×64（32×32、4×2），
透明背景，每帧有可辨的动作或特效变化，现有动画文档、片段ID和事件时刻保持不变。

```bash
python tools/build_placeholder_anims.py
python tools/build_placeholder_anims.py --check
python tools/rpgc.py toolkit assets
```

这些资源用于开发、编辑预览和发布完整性，不宣称是正式武侠人物美术或多方向角色动画。
默认游戏适配器的 `play_animation` 仍没有接入完整播放器；补齐文件不改变这一范围。
之前评估并移除的 Engvee 多朝向资源与 Kenney 微缩角色未重新引入，敌人继续使用上面的
CC0 素材。原先“主角没有图”的记录已由本次明确的开发资源方案替代。

运行时 schema 门仍不解码图片；独立 `toolkit assets` 检查真实文件、PNG尺寸与哈希，
CI 同时运行它和生成物新鲜度检查，因此资源断链不能再被纯文档校验的 PASS 掩盖。

## 地形素材

地形（等距地面 / 道具 / 城墙 / 建筑）走另一条线，见
[`../tilesets/CREDITS.md`](../tilesets/CREDITS.md)。

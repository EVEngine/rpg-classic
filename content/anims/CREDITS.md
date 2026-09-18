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

## 为什么这里仍然不放逐朝向角色精灵

**主角与 NPC 依然没有图。** `hero.json` 指向 `hero.png`，`fireball.json` 指向
`fireball.png`，两张图都不存在。

之前这里放过 Engvee 的 "Animated Isometric" 系列（Reptile / Snake /
Archeopteryx），已按项目决定全部移除：Engvee 每个包按 22.5°（部分 7.5°）渲染出
16~48 个朝向，每朝向一个独立图集文件，三个包合起来 1.45 MB，而
`eve.rpgc.anim` 是**单图 + 单网格**，一次只能放一个朝向。拿到 8 方向要付出的体积
远大于实际可用的信息量，同样的表现力用一个带骨骼的 3D 模型更省也更灵活。

本轮也重新评估过 Kenney 的等距微缩角色（`assets/kenney_isometric-miniature-dungeon/Characters/`，
168 张 256×512 的 `Male_0..7` 帧），结论同样是**不用**：8 个 `Male_*` 不是八个角色，
而是同一个裸身模型的不同肤色变体，`Run0..9` 十帧里也只有两三个可辨姿势。把它拼成
图集只会得到八张几乎一样的图。

**而这些只是主角/友方的缺口，不是敌人的。** 敌人用的是上面两套「按怪物画的」素材，
它们本来就是独立角色，不存在朝向数量爆炸的问题。所以本轮的取舍是：**敌人有图，
主角没有**，并且这一点在 README 的「明确不提供的东西」里也写明了。

需要注意：工作流**不解析图片、也不检查图片是否存在**，所以上面两处断链**不会被
校验门报出来**。要么补图，要么连同引用它们的内容文档一起改掉。

## 地形素材

地形（等距地面 / 道具 / 城墙 / 建筑）走另一条线，见
[`../tilesets/CREDITS.md`](../tilesets/CREDITS.md)。

# 07 · 世界图志：中原五城与边地七镇

> 本文说明 `content/maps/` 里那十二张新地图是从哪来的、它们怎么连成一张世界，
> 以及 `tools/build_world_maps.py` 与 `data/world-regions.json` 的分工。
> 设定（城名、地域、NPC、连线）写在 spec 里；地图文档是它的投影，不是第二份真源。
>
> 战斗与成长系统在 [`06-game-design.md`](06-game-design.md)；本文只讲世界这一层。

## 1. 两档聚落

| id | 名称 | 地域 | 档 | 尺寸 | 图集 | 地面材质 |
|---|---|---|---|---|---|---|
| `luoyang` | 洛阳 | 中原 | 主城 | 32×26 | `sbs-floors` | `Floor_Stone` |
| `changan` | 长安 | 中原 | 主城 | 32×26 | `sbs-floors` | `Floor_Brick` |
| `kaifeng` | 开封 | 中原 | 主城 | 32×26 | `sbs-floors` | `Floor_Wood` |
| `xiangyang` | 襄阳 | 中原 | 主城 | 32×26 | `sbs-floors` | `Floor_Rocky` |
| `jinling` | 金陵 | 中原 | 主城 | 32×26 | `sbs-floors` | `Floor_Tile` |
| `yanmen-fortress` | 雁门关 | 北境 | 边镇 | 24×18 | `sbs-overworld` | `Terrain 1` |
| `yumen-town` | 玉门镇 | 西域 | 边镇 | 24×18 | `sbs-overworld` | `Terrain 2` |
| `canglang-ferry` | 沧浪渡 | 东海 | 边镇 | 24×18 | `sbs-overworld` | `Forest` / `Water` |
| `jiange-post` | 剑阁驿 | 西蜀 | 边镇 | 24×18 | `sbs-overworld` | `Terrain 3` |
| `miaoling-village` | 苗岭寨 | 南疆 | 边镇 | 24×18 | `sbs-overworld` | `Forest` |
| `xueling-hold` | 雪岭坞 | 极北 | 边镇 | 24×18 | `sbs-floors` | `Floor_Ice` |
| `luoxia-isle` | 落霞岛 | 东南 | 边镇 | 24×18 | `sbs-overworld` | `Water` / `Forest` |

十二张地图各有一句设定、3–4 名 NPC（`speaker` + `dialogue`）与一只宝箱，全部写在
`data/world-regions.json` 的 `locations[]` 里。改设定只改那一个文件。

## 2. 旅行图

十二座新聚落与两张既有地图构成 13 条走廊。**边是成对的**：一条 `links[]` 记录
同时生成 A→B 与 B→A 两个 `portal` 对象，所以不会出现单向死路。

```text
                        xueling-hold 雪岭坞
                              │
   yumen-town ── changan ── yanmen-fortress
   玉门镇        长安        雁门关
                   │
   luoxia-isle ─ jinling ─ luoyang ─ kaifeng ─ canglang-ferry
   落霞岛        金陵      洛阳      开封      沧浪渡
                              │
                          xiangyang 襄阳
                           │        │
                  jiange-post   miaoling-village
                   剑阁驿        苗岭寨
                       │
              village-outskirts 村庄外郊
                       │
                  mist-forest 迷雾森林        （既有地图，未改动）
```

- 洛阳是四向枢纽（东/西/南/北各一门）；
- 边镇多为单门尽头，正是「边缘」的意思；
- 起手地图 `village-outskirts` 新增一门通 `jiange-post`，
  于是 `村庄 → 驿站 → 襄阳 → 洛阳` 是一条可走的成长线。

**落点约定**：A→B 的 `targetX/targetY` 不是随手填的，
而是 **B 那扇回程门沿它自己的内向再走一格**。这样落地时玩家不会正好站在
回程门上被立刻弹回去。生成器算这一步，`facingX/facingY` 取同一个内向。

## 3. 门：存在但未开放

「未开放」是条件，不是内容缺失——关着的门仍然留在对象层里，人和 AI 都能从文档
读出「这扇门在，但还没开」（`06-game-design.md` §1.3）。本世界 5 处：

| 门 | 条件 | 台词 key |
|---|---|---|
| `changan/gate-yumen-town` | `story.chapter ≥ 2` | `msg.gate.locked.yumen` |
| `yanmen-fortress/gate-xueling-hold` | `story.chapter ≥ 3` | `msg.gate.locked.xueling` |
| `jinling/gate-luoxia-isle` | `story.chapter ≥ 4` | `msg.gate.locked.luoxia` |
| `kaifeng/gate-canglang-ferry` | 时刻 ∈ {dawn, day} | `msg.gate.locked.canglang` |
| `xiangyang/gate-miaoling-village` | 开关 `flag.miaoling-peace` | `msg.gate.locked.miaoling` |

条件词表复用 `eve.rpgc.condition` 一份，没有第二套语法。门只写在
`content/world/world.main.json`（世界文档是单例），地图文档一字不提开放状态。

## 4. 地图是怎么来的

`tools/build_world_maps.py` 读 `data/world-regions.json` 生成
`content/maps/<id>.json`。它拥有四样东西：

1. **投影头**。`origin` 由尺寸推导，不是手填：

   ```text
   pitchX = tileWidth × renderSpacing[0] = 128 × 2 = 256
   originX = (height − 1) × tileWidth + tileHeight
   originY = tileHeight
   ```

   这条对得上两张既有地图（`village-outskirts` 24×20 → `[2496, 64]`；
   `mist-forest` 20×18 → `[2240, 64]`），它把地图包围盒的左上角放在
   `(tileHeight, tileHeight)`。

2. **`terrain` 层**，必须是第一个 tilelayer 且 `layer: 0`
   （`map.no-terrain-layer` / `map.terrain-layer-index`）。外圈留一格 GID 0，
   内部填 3 个同材质变体，按 map id 的 CRC32 播种，**重跑必然一致**。

3. **`props` 层**，铺装。主城是每 5 格一条的街网，边镇是一条主路加一条支路，
   中心都有一小块广场。

4. **对象层**：一个 `spawn`（`map.no-spawn` 要求）、spec 里的 NPC 与宝箱、
   以及由 `links[]` 推导出的 `portal`。所有对象坐标写的是**格子锚点**
   `worldX = originX + (tx − ty) × tileWidth`，这正是 `RpgcIso.worldToTile*` 的精确逆，
   两张既有地图也是这个写法。

`village-outskirts.json` 只被**追加**一个 portal，其余部分原样保留；重跑不会重复添加。

```bash
cd .  # repository root
python tools/build_world_maps.py           # 写盘
python tools/build_world_maps.py --check   # 断言磁盘产物与重新生成一致
```

## 5. 一条必须知道的限制：一图一图集

地图 schema 的 `tilesets` 是 `maxItems: 1`，所以一张地图只能引用一个图集。
本世界的两个图集（`sbs-floors` 504 块、`sbs-overworld` 180 块）**全部是
`class: floor`，即全部可走**。后果：

- 十二张地图**没有阻挡几何**。寻路看到的是一整片可达地面，
  不是街巷迷宫；「建筑」目前没有对应的瓦片层。
- `props` 层铺的是同材质的另一种地面，不是墙。

要做出真正的街巷，需要一张**同时含地面与墙**的合并图集，或改地图 schema 允许
多个图集——两者都是独立改动，本文不做。在那之前，
这十二张地图的准确描述是「铺装完好、可直接行走的聚落地面」。

## 6. 跟着改的两处

| 文件 | 改动 | 为什么必须改 |
|---|---|---|
| `data/world-object-contract.json` | `portal.targetMap` 的 enum 从 2 个扩到 14 个 | 这是**运行时**契约：`map.loadFromFileWithObjectContract` 会拒绝 enum 外的目标地图，不补新地图就一脚踹空 |
| `content/world/world.main.json` | 新增 5 处 `gates[]` | 门的 `portal` 写成 `<mapId>/<objectName>`，指向的门必须真实存在（`systems.gate-portal-missing`） |

## 7. 验收

```bash
cd .  # repository root
EVE_BIN=<repo>/build/win32-debug/src/engine/eve.exe \
  python tools/rpgc.py --wait 150 validate
python tools/build_world_maps.py --check
```

实测：

```text
  map        14 document(s)
result  : PASS · ok
build_world_maps: up to date (13 maps, 24 portals)
```

还有一条比 schema 门更硬的证据：把 14 张地图逐份喂给**引擎自己的加载器**
`Map::loadFromFileWithObjectContract`（`main.nut:185` 用的同一个调用），
一份都没被拒：

```text
[loadmaps] 14 maps admitted by the engine loader, 26 portal objects on disk
```

26 = 本轮生成的 24 个 + 既有的 `forest_gate` 与 `village_gate`。这条跑在
`eve mcp` 宿主里，所以它同时证明了扩展后的 `targetMap` enum 被引擎接受。

另外两条不针对本轮内容、但确认没有回归：

```text
[tools/modules_check.nut]  gate PASS: ok / PASS (0 failure(s))
[rpgc.py selftest]         PASS (8/8 checks), 42/42 declared commands callable
```

六层门里跟本轮直接相关的是：**严格 JSON 解析**（12 份新文档）、
**Eve Schema v1**（`eve.rpgc.map` 字段/上下限/`additionalProperties:false`）、
**每文档语义门**（图层纪律、`terrain`/`layer 0`、GID 落在图集范围、spawn 存在、
图层与对象名唯一）、**跨引用门**（图集存在、门指向的对象存在且是 portal、
`moment` 名字在世界时刻表里）、**模块额外检查**（图集 firstGid 与瓦片尺寸一致、
时刻层索引不重复）。

### 本轮没有验证的

- **没有渲染验证**。`origin` / 锚点公式来自源码推导与两张既有地图的数值反解，
  不是肉眼比对；截图需要引擎自带接口跑起来。
- **没有被真正走过的世界**。24 个 portal 的双向一致性是生成器与校验门算出来的，
  不是靠人走进每一扇门试出来的。
- **`eve run` 打到几张图**。本轮只证明了校验门 PASS；
  运行时换图还受 `Map::retireReplacedLayers` 只清空不销毁实体那条限制约束
  （`06-game-design.md` §1.2），来回穿图会积累旧图层实体。

## 8. 加第十三座城

1. 在 `data/world-regions.json` 的 `locations[]` 追加一条（`id`/`size`/`atlas`/
   `ground`/`street`/`npcs`/`chests`）；
2. 在 `links[]` 追加至少一条边，`edge` 取 `north|south|east|west`；
3. `python tools/build_world_maps.py`；
4. 若该城有门，在 `content/world/world.main.json` 加一条 `gates[]`；
5. 若目标地图是新的，把它加进 `data/world-object-contract.json` 的 `targetMap` enum；
6. `python tools/rpgc.py validate`。

生成器会拒绝：自环、重复的边、指向不存在地图的边、超出图集范围的 GID、
以及 spec 里没有对应 `locations` 条目的端点。

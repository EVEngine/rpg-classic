# 01 · 等距关卡编辑器（tilemap）

对应 `lib/rpgc_tilemap.nut`、`lib/rpgc_iso.nut`、`schema/eve.rpgc.tileset.json`、
`schema/eve.rpgc.map.json`、`editors/tilemap.vm.nut`。

> 落地状态：人用入口是 `eve run apps/tilemap`。Agent 入口 `eve mcp --root .` 会一并恢复该编辑器（`eve_host_status.viewModels` 中可见 `TilemapVM`）。库、schema、语义门与 CLI 校验均已运行验证。

## 1. 引擎的投影公式

工作流直接复用引擎的投影，不自己实现一套，这样编辑器画出来的和运行时画出来的必然一致。
链路是 `map::tileToWorld` → `grid::cellToWorld`：

```cpp
// src/modules/grid/GridProjection.cpp:38-43
px = cfg.originX + float(cx - cy) * tw * 0.5f;   // tw = cellPitchX = cellW + cellGapX
py = cfg.originY + float(cx + cy) * th * 0.5f;   // th = cellPitchY = cellH + cellGapY
```

```cpp
// src/modules/grid/GridProjection.cpp:63-67
float cellToDepthY(cfg, cx, cy) { return cellToWorld(cx,cy).py + cfg.cellH; }
```

写成人话：

```text
worldX = originX + (tx - ty) * pitchX / 2
worldY = originY + (tx + ty) * pitchY / 2
depthY = worldY + tileHeight
pitch  = tile size + gap
```

`pitch` 中的 gap 有两个来源（`RpgcIso.configFromDocument`，`lib/rpgc_iso.nut:37-82`）：

- `cellGap: [gx, gy]` —— 显式 gap；
- `renderSpacing: [sx, sy]` —— 引擎按 `gap = size * (spacing - 1)` 换算
  （`TileLayer::setRenderSpacing`），所以 `pitch = size * spacing`；
- 都没有时退到 `cellGapX` / `cellGapY`（默认 0）。
- origin 可写成 `origin: [x, y]`，或退到顶层 `x` / `y`。

`RpgcIso` 暴露的对应函数：`tileToWorldX/Y`（`:86-92`）、`anchorX/Y`（`:96-97`，
单元格锚点＝投影格左上角，也是贴图应用 pivot 前的位置）、`depthYAt`（`:99-101`）、
`sortKey`（`:104-106`，depthY + tile 的 sortBias，与引擎统一 2D 队列的排序键同义）、
`centerX/Y`（`:110-116`，包围盒中心）。

`schema/eve.rpgc.map.json` 把 `orientation` 限制为 `["isometric"]`，`renderSpacing` 与
`origin` 都是必填的 2 元 number 数组。

## 2. 拾取不变式（这一节解释了 `renderSpacing` 为什么必须那样填）

引擎的 `worldToTile` 不是 `tileToWorld` 的精确逆：

```cpp
// src/modules/grid/GridProjection.cpp:81-92
cx = floor((b + a) / 2);   // a = (wx-originX) / (pitchX/2)
cy = floor((b - a) / 2);   // b = (wy-originY) / (pitchY/2)
```

把单元格 `(tx,ty)` 的**包围盒中心**代进去，解得

```text
tx' = floor(tx + (tileW/pitchX + tileH/pitchY) / 2)
ty' = floor(ty + (tileH/pitchY - tileW/pitchX) / 2)
```

于是「点在某个格的视觉中心上，落回同一个格」成立，当且仅当

```text
tileW/pitchX + tileH/pitchY < 2      且      tileH/pitchY >= tileW/pitchX
```

这正是 `RpgcIso.pickIsConsistent` 判的东西（`lib/rpgc_iso.nut:119-132`）：

```squirrel
info.ratioX = cfg.tileWidth  / cfg.pitchX;
info.ratioY = cfg.tileHeight / cfg.pitchY;
info.ok     = (info.ratioX + info.ratioY) < 2.0 && info.ratioY >= info.ratioX;
```

**出厂的等距约定正好满足它**：`renderSpacing = [2, 2]` 让 pitch 恰好是 tile 尺寸的两倍，
比值为 `(0.5, 0.5)`，和 = 1 < 2，且 `0.5 >= 0.5`。此时 `tx' = floor(tx + 0.5) = tx`。

不满足时会怎样？以 2:1 图集 `tileW=150, tileH=75` 为例：

| renderSpacing | pitchX / pitchY | ratioX / ratioY | 和 | 结果 |
|---|---|---|---|---|
| `[2, 2]` | 300 / 150 | 0.5 / 0.5 | 1.0 | 一致 |
| `[1, 1]` | 150 / 75 | 1.0 / 1.0 | 2.0 | 不一致：和 = 2，`floor(tx + 1) = tx + 1`，点击**视觉中心**落到右下方邻格 |
| `[3, 3]` | 450 / 225 | 0.333 / 0.333 | 0.667 | 一致，但格子间距变大 |

`RpgcTilemap.mapDiagnostics` 在 `!pick.ok` 时给 `map.pick-inconsistent` **warning**
（`lib/rpgc_tilemap.nut:118-123`），提示改成 `renderSpacing [2,2]`。它被刻意做成 warning 而不是
error：`[1,1]` 仍然能让引擎正常渲染与拾取，只是「点的位置和心里的格子差一格」。

编辑器侧对应的是 `RpgcIso.pickCell`（`lib/rpgc_iso.nut:220-230`）：屏幕点 → 世界点 →
`worldToTile*`，返回 `{x, y, inside}`，`inside` 是**编辑器自己**夹取到地图范围的结果。

**引擎的 `worldToTile` 不夹取。** `grid::worldToCell` 的 `mapW/mapH` 只用于
staggered / hex 的有界最近邻搜索（`src/modules/grid/GridProjection.cpp:69-94`、头注释
`src/modules/grid/GridProjection.h:17-22`）；正交与等距分支直接 `floor` 出结果，越界就是越界的
负数或超大索引。`RpgcIso` 因此也不夹取，把「越界拾取是否有意义」交给调用方决定
（`lib/rpgc_iso.nut:14-15`）。

## 3. 图集文档（`eve.rpgc.tileset`）

字段见 `schema/eve.rpgc.tileset.json`。它是 Tiled-flat 的：一张图片 + 规则网格 + 逐 GID 覆盖。

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `image` | string | 是 | 图集图片路径（**工作流不检查文件是否存在**，见 §5） |
| `firstGid` | integer ≥1 | 是 | 本图集第一个 GID；地图的 `tilesets[0].firstgid` 必须与它一致 |
| `columns` | integer ≥1 | 是 | 网格列数 |
| `tileWidth` / `tileHeight` | integer 1..512 | 是 | 单元格尺寸 |
| `margin` / `spacing` | integer ≥0 | 否 | 图集边距与格间距 |
| `tiles[]` | array ≥1 | 是 | 逐 GID 覆盖记录 |

`tiles[]` 一项的字段：

| 字段 | 类型 | 必填 | 引擎消费点 |
|------|------|------|-----------|
| `gid` | integer ≥1 | 是 | `readTileVisual`（`src/modules/map/TileConfig.cpp:146`） |
| `name` | string | 否 | 仅编辑器标签用 |
| `region` | integer[4] | 是 | `readVec4(o,"region",...)` → `visual.x/y/width/height`（`TileConfig.cpp:148-153`） |
| `pivot` | number[2] | 否 | `readVec2(o,"pivot",...)` → `visual.pivotX/pivotY`（`TileConfig.cpp:154`） |
| `sortBias` | number | 否 | `visual.sortBias`（`TileConfig.cpp:155`） |
| `footprint` | integer[2] | 否 | `visual.footprintW/H`（`TileConfig.cpp:157-160`）——**存下来但没人用**，见 §5 |
| `walkable` | bool | 否 | `visual.walkable`（`TileConfig.cpp:161`） |
| `cost` | number ≥0.001 | 否 | `visual.cost`（`TileConfig.cpp:162`，下限被夹到 0.001） |
| `enterMask` / `exitMask` | integer 0..15 | 否 | 也可走 `properties` 里的同名项（`TileConfig.cpp:174` 起） |
| `opaque` | bool | 否 | 同上，导航/遮挡配置 |
| `tags` | string[] | 否 | 项目侧标签 |

工作流的语义门对 `tiles[]` 额外要求（`lib/rpgc_tilemap.nut:52-104`）：

- `gid >= 1`（GID 0 保留给空格子）；
- **GID 不得重复** —— 引擎渲染取第一个匹配（`visualForGid`，`src/modules/map/TileSystem.cpp:81-85`
  线性扫描 `ts.visuals`），重复声明是静默的错；
- `region` 必须是 4 元数组且宽高为正；
- **缺失 `pivot` 给 warning**（`map.missing-pivot`）：未设置时 pivot 为 0，对裁过透明边的等距 tile
  几乎总是错的；
- `footprint` 要么不写，要么是 2 元数组。

## 4. 地图文档（`eve.rpgc.map`）

它同时是**合法的引擎地图文件**，因为引擎读取器
（`src/modules/map/TileConfig.cpp`）解析的就是同一组字段；顶层的
`schema` / `version` / `id` / `title` 被引擎忽略，由本工作流使用。

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `width` / `height` | integer 1..512 | 是 | 逻辑格尺寸（矩阵是行主序 `data[ty*width + tx]`） |
| `tilewidth` / `tileheight` | number 1..512 | 是 | 格尺寸；引擎用它算格与 UV，**图集尺寸只影响 UV** |
| `orientation` | `"isometric"` | 是 | 只允许等距 |
| `renderSpacing` | number[2] | 是 | 见 §2 |
| `origin` | number[2] | 是 | 世界原点 |
| `autoReload` | bool | 否 | 交给引擎的热重载开关 |
| `tilesets[]` | array，长度恰好 1 | 是 | `{source, firstgid}`；`source` 相对地图目录 |
| `layers[]` | array 1..16 | 是 | 见下 |

图层项：`{id, name?, type?, layer?, visible?, data?, objects?}`。

- `type` 取 `tilelayer`（默认）或 `objectgroup`；
- `layer` 是绘制层号 0..15；
- `tilelayer` 用 `data`：**长度必须恰好 `width * height`**，`0` 表示空格子；
- `objectgroup` 用 `objects[]`：`{name, type, x, y, width?, height?, properties?}`，
  `x/y` 是**世界像素坐标**（不是格坐标）；`properties` 项是
  `{name, type?, value}`，**value 必须是字符串**（对齐 Tiled 的编码与引擎的 asString 强制转换）。

工作流的语义门对地图额外要求（`lib/rpgc_tilemap.nut:108-249`）：

| code | 条件 |
|------|------|
| `map.pick-inconsistent` | warning，`pickIsConsistent` 失败 |
| `map.atlas-firstgid` | 图集可读且 `atlas.firstGid != map.tilesets[0].firstgid` |
| `map.atlas-tile-size` | 图集可读且 `atlas.tileWidth/Height != map.tilewidth/height` |
| `map.bad-layer-id` / `map.duplicate-layer` | 图层 id 不是稳定 id / 重复 |
| `map.bad-object-name` / `map.duplicate-object` | 对象名不是稳定 id / 同名重复 |
| `map.duplicate-property` | 同一对象内同名属性重复 |
| `map.layer-size` | tilelayer 的 `data` 长度 != `width*height` |
| `map.gid-out-of-range` | 有非 0 GID 落在 `[firstGid, firstGid + |tiles| - 1]` 之外 |
| `map.no-tile-layer` | 一个 tilelayer 都没有 |
| `map.no-spawn` | 没有任何 `type == "spawn"` 的对象 |

`map.no-spawn` 是**error**：`RpgcTilemap` 把「关卡必须有玩家起点」定为契约。
这是工作流加的项目规则，不是引擎规则。

## 5. 引擎不检查、因此工作流才检查的东西

这一节是本文的核心。下面每一条都是「引擎会接受，但结果是错的」，所以语义门必须自己拦下来。

### 5.1 没有 GID 范围检查

`decodeLayerData`（`src/modules/map/TileConfig.cpp:542-563`）只校验 **元素个数**：

```cpp
if (expectedCount > 0 && out.size() != expectedCount) { *error = "gid count mismatch"; return false; }
// 元素逐个 asUInt32(...)，不比对 GID 与图集 tiles[] 的范围
```

越界的 GID 不会报错，会走渲染路径：`visualForGid` 找不到就退回
`atlasForGid` + `atlasUV` 的规则网格 UV（`src/modules/map/TileSystem.cpp:261-262`、`:62-79`），
而没有纹理时渲染的是**确定性调试色** `solidForGid`（`src/modules/map/TileSystem.cpp:45-52`，
`gid * 2654435761u` 散列出的颜色，头注释写明 "Deterministic debug color when no tileset
texture is bound"）。也就是说，写错 GID 的后果是一个**看起来像地图但颜色莫名**的画面。

→ 工作流报 `map.gid-out-of-range`，并在 hint 里说明引擎只验证元素个数
（`lib/rpgc_tilemap.nut:210-236`）。

### 5.2 没有图片存在性检查

`tileset.image` / `anim.image` 只是字符串。工作流不读图片、不检查扩展名、不检查文件是否存在、
不检查声明尺寸与真实像素是否一致。这条限制是**有意的**：工作流不应该成为资源加载器。

### 5.3 `tiles[]` 里重复 GID 无法被引擎发现

`visualForGid` 是线性扫描并返回**第一个**匹配：

```cpp
// src/modules/map/TileSystem.cpp:81-85
for (const auto &visual : ts.visuals) if (visual.gid == int(gid)) return &visual;
return nullptr;
```

`setTileVisual` / `setTileMetadata`（`src/modules/map/TileLayer.cpp:439-457`、`:466-482`）
也是「找到就改，找不到才追加」，所以后写的覆盖前写的，文档里两份都留着。

→ 工作流报 `map.duplicate-gid`，hint 是「runtime 只保留第一个匹配」
（`lib/rpgc_tilemap.nut:70-74`）。

### 5.4 地图 tile 尺寸不必等于图集尺寸

引擎用**地图**的 `tilewidth/tileheight` 建立格子与投影，用**图集**的 region/columns 算 UV。
两者不一致时不会报错，只会画歪或错位。

→ 工作流报 `map.atlas-tile-size`，hint 写明这层分工
（`lib/rpgc_tilemap.nut:136-143`）。

### 5.5 未知 JSON 字段从不被引擎拒绝

引擎的 JSON 读取器按名字取值，多余的键直接忽略。所以一个拼错的字段名（`tilewith`、
`renderSpacings`）在引擎侧是完全静默的。

→ 工作流靠 Eve Schema v1 的 `additionalProperties: false` 把这件事变成硬错误。
六份 schema 全部显式声明 `"additionalProperties": false`。这是 layer 1 的价值所在。

### 5.6 没有 spawn / 可达性校验

引擎不知道「关卡是否可玩」。`RpgcTilemap` 只检查**存在** `type == "spawn"` 的对象
（`lib/rpgc_tilemap.nut:184`、`:243-247`）。可达性是运行时的事：`Pathfinder`
（`Map.newPathfinder` / `syncFromLayer` / `isWalkable` / `findPath`）才有寻路语义，
而且它按 GID 的 walkable/cost 工作，不读文档。工作流**不做**连通性检查——这是刻意的边界，
见 [`04-runtime-integration.md`](04-runtime-integration.md)。

### 5.7 没有对象重名检查（除非有契约）

引擎侧对象重名是允许的；问题在于**世界状态和事件按名字寻址对象**。工作流因此把
对象名限制为稳定 id 且要求唯一（`lib/rpgc_tilemap.nut:174-183`），hint 直接写明
"world state and events address objects by name"。这是工作流加的契约。

### 5.8 `footprintW/H` 被解析但没有任何消费者

`TileConfig.cpp:157-160` 与 `setTileMetadata`（`TileLayer.cpp:477-478`）都会存
`visual.footprintW/H`，`TileLayer.h:129-130` 也声明了它们。但渲染仍是
**每个 GID 恰好画一格**：`TileSystem.cpp` 只读 `visual` 的 region/pivot/sortBias
（`visualForGid` → `visualUV` / `subtileUV`），footprint 不参与布局。

→ 工作流**明确把它当编辑器契约**：`RpgcIso.footprintCells`
（`lib/rpgc_iso.nut:161-172`）与 `footprintIsInside`（`:174-178`）定义了
「GID 占据从 `(tx,ty)` 起的 `w*h` 格」，语义门只检查 `footprint` 的形状
（2 元数组或缺失）。也就是说编辑器可以用 footprint 做提示与占用计算，但**不要指望引擎替你画多格**。

### 5.9 `worldToTile` 不夹取

见 §2。引擎不给越界保护，`RpgcIso.pickCell` 用 `inside` 标记代替夹取。

## 6. 编辑器走查

`editors/tilemap.vm.nut`（ViewModel）是这套设计的参考实现。它的规则只有一条：
**`doc` 是唯一权威，其余全是投影**（`editors/tilemap.vm.nut:69-71`）。

### 6.1 打开的是文件夹，不是文档

编辑器**没有"打开文档"这一步**。`workflow.json` 给每个 kind 指定唯一目录，
`RpgcProject.folder(kind)` 直接读那个目录，列表就是它的内容；**选中一行就是载入**
（`onChange` → `loadSelected`），面板上的标题绑定 `vm.folderLabel`，显示的就是
`content/maps  ·  14 个文档` 这样的路径与数量。四个编辑器一致（tilemap/skill/event/battle）。

生命周期：

1. 文件末尾扫目录并显示第一张（`:1176-1183`）：
   `TilemapVM.loadFolder(); TilemapVM.loadSelected("tilemap", "")`。
2. `loadFolder`（`:110-134`）调 `RpgcProject.folder("map")`，把 `ids` 写进 `mapList`、
   把 `directory`/`count`/`label` 写进 `folderPath`/`folderCount`/`folderLabel`。
   目录为空时清 `doc` 并给出可读状态，不会留下上一份文档。
3. `loadSelected`（`:136-155`）走 `RpgcProject.loadById("map", id)`，把结果写进
   `doc`，调 `rebuild()` 与 `frameAll()`。它只被 `onChange`、`refresh` 与启动调用，
   **没有自己的按钮**——这正是"没有打开手势"的含义。
4. `rebuild()`（`:501-557`）从 `doc` 重算所有投影：图层名列表、对象名列表、图集与 GID 标签、
   当前图层的格子数、光标标签。**没有任何缓存需要手工失效**。
5. `pollFolder(dt)`（`:168-195`）每秒重扫一次目录，让列表跟上磁盘。它**只刷新列表**：
   重新读入当前文档会静默丢掉未保存的修改，所以那件事只在用户主动 `refresh`
   （`:157-166`）或**所选行已从磁盘消失**时发生——那时已经没有东西可编辑了。
6. 帧回调（`:1184-1187`）向 `RpgcHost` 注册一个 drawer：
   `update(dt)`（`:856-862`）→ `normalize` / `pollFolder` / `resolvePointer` / `updateCursor`；
   `draw()` → 画棋盘；`status()` → 一行摘要。
   `RpgcHost` 由 `mcp.nut` 的 `eve_host_update` / `eve_host_render` 泵动，
   所以新增编辑器不会破坏已有编辑器（`lib/rpgc_host.nut:1-14`）。

### 6.2 目录列表与校验索引是两件事

`RpgcProject.index()` 是给**校验门**用的启动快照，它被缓存（`indexValue`），
因为一次整体校验要在一个稳定的内容集合上跑。编辑器要的是**此刻**的磁盘状态，
所以 `RpgcProject.folder(kind)` 每次都重新读目录，**刻意绕过那个缓存**。

两者不一致时 `folder()` 会丢弃索引缓存（`lib/rpgc_project.nut:159-171`）。
没有这一步，面板会显示一行、而 `loadById` 对同一行回答 `project.unknown-id`——
这是这个视图唯一能骗到人的方式。`tools/modules_check.nut` 的
`folder.stale.*` 探针用"改写 manifest 里那个目录"制造真实的过期状态并断言修复发生：
它先证明缓存**真的**会滞后（`cached 14 vs on disk 6`），再断言 `folder()` 之后
索引与磁盘一致、`loadById` 能接受那一行。

**它不能在这台机器上靠改文件来制造过期**：Squirrel 没有项目根的写入口——
`installScriptFileApi`（`src/modules/filesystem/physfs/FileApi.cpp:129`）是只读的，
而 `writeTextAtomic` 对项目相对路径直接拒绝（本轮实测：
`writeTextAtomic rejected content/maps/_rpgc_probe.json`）。

绘制（`draw`）：按文档 `width`×`height` 在**主窗口**铺等距网格（`boardRect` = 窗口减去右侧 inspector 与底部图块选择条），不再读取 `eve.host.widgetRect("tilemap","canvas")`。有图集 PNG 时用 `Sprite2D`+`Quad` 画单元格，否则退回 `colourOf` 色块。底部是可视化图块选择（点选 GID，上一页/下一页翻页），笔刷页没有 GID 下拉。碰撞叠加（`collectBlocked`）从图集读 walkable，红色半透明盖住不可走格。对象用小方块标出，spawn 用绿色区分。

编辑动作与它们的守卫：

| 动作 | 位置 | 行为与守卫 |
|------|------|-----------|
| `paint` / `erase` / `fill` / `rect` | `:264-285` | 四个入口只设置 `this.tool`，并把 `(editor, widget)` **原样转发**给 `stampBrush`（`:287-326`）；`erase` 写 GID 0；`fill` 整层；`rect` 画当前光标 3×3（v1 没有两次点击的状态机，注释在 `:279-283`）；单格写入前检查光标在地图内 |
| `spawnObject` | `:346-372` | 检查对象名 `Rpgc.validId`、查重；位置由 `RpgcTilemap.worldOf(doc, cursorTileX, cursorTileY)` 换算 |
| `removeObject` | `:374-387` | 按名字过滤 |
| `resizeMap` | `:389-413` | 逐 tilelayer 重排 data：落在旧范围内的保留，新增部分填 0；**objectgroup 不动** |
| `frameAll` | `:415-436` | 用 `RpgcIso.documentBounds` 求出整图世界包围盒，重置编辑器相机 |
| `saveMap` | `:237-257` | **先** `RpgcStore.checkRevision(path)`，再 `RpgcValidate.commitDocument(path, doc)`；成功才清 `dirty` |

转发那一条不是风格问题：`stampBrush` 与其它命令一样声明为 `(editor, widget)`，
写成 `this.stampBrush()` 只会传入 `this`，Squirrel 直接抛
`wrong number of parameters (1 passed, 3 required)`，四个笔刷按钮与
`stampBrush` 命令**全部无法落笔**。这条在本机 `eve mcp` 宿主上实测过。

### 6.3 光标是状态，不是每帧推导量

`cursorTileX` / `cursorTileY` 是权威状态，`pointer` 只是**一个**移动它的来源：

- `resolvePointer()`（`:661-669`）只在第一次调用时构造指针（`eve.Mouse()`）并吞掉异常，
  于是没有输入模块的宿主只是没有指针，而不是每帧抛错。
- 拾取只在有指针时跑（`updateCursor`，`:750-779`）；无指针时光标保持原值，
  标签由 `refreshCursorLabel()`（`:596-601`）刷新。
- `moveCursor` / `setCursor` / `setCursorTile`（`:559-594`）让无头会话
  （以及 `eve_host_script`、`eve_eval`）也能把光标移到任意格。`editors/tilemap.editor.json`
  的「笔刷」页给了 ←/→/↑/↓、`x,y` 输入框与「定位」按钮，所以没有鼠标也能完整编辑。

根槽 `mouse` 在 `eve mcp` 宿主里**不存在**（宿主不跑 `load.nut`），因此
`mouse.getX()` 报 `the index 'mouse' does not exist`；模块实例必须经 `eve` 取
（`eve.Mouse()`，已实测可答）。这条规则同样适用于 `gfx` / `keyboard`。

`saveMap` 里的两条守卫是这个编辑器最重要的两行：

```squirrel
local stale = RpgcStore.checkRevision(path);
if (!stale.ok) { this.report(stale); return; }       // store.stale-revision
local result = RpgcValidate.commitDocument(path, this.doc);
```

`checkRevision` 防止覆盖别人刚改过的文件；`commitDocument` 保证**写不出没通过门的文档**。
在 `deferred` 后端下，`commitDocument` 成功只是「已暂存」，状态行会明确要求跑
`tools/rpgc.py export`（`:133-136`）。

## 7. 一个完整的例子

目标：6×4 的等距地图，2:1 图集，铺地板、加两个对象、存下来。

### 7.1 图集 `content/tilesets/dungeon-atlas.json`

```json
{
  "schema": "eve.rpgc.tileset",
  "version": 1,
  "id": "dungeon-atlas",
  "title": "地牢图集",
  "image": "textures/dungeon.png",
  "firstGid": 1,
  "columns": 8,
  "tileWidth": 150,
  "tileHeight": 75,
  "margin": 0,
  "spacing": 0,
  "tiles": [
    {
      "gid": 1,
      "name": "floor_stone",
      "region": [0, 0, 150, 75],
      "pivot": [0, 0],
      "walkable": true,
      "cost": 1.0,
      "enterMask": 15,
      "exitMask": 15,
      "opaque": false
    },
    {
      "gid": 2,
      "name": "wall_brick",
      "region": [150, 0, 150, 75],
      "pivot": [0, 0],
      "sortBias": 4,
      "walkable": false,
      "opaque": true
    },
    {
      "gid": 3,
      "name": "tree_oak",
      "region": [300, 0, 300, 225],
      "pivot": [150, 220],
      "sortBias": 0,
      "footprint": [2, 2],
      "walkable": false,
      "opaque": true
    }
  ]
}
```

注意三件事：`gid` 从 1 开始连续；每项都有 `pivot`（缺了会 warning）；`gid: 3` 的区域
比格子大（300×225）并带 `footprint: [2,2]`——**引擎仍只画一格**（§5.8），
footprint 是给编辑器用的占用声明。

### 7.2 地图 `content/maps/forest-clearing.json`

```json
{
  "schema": "eve.rpgc.map",
  "version": 1,
  "id": "forest-clearing",
  "title": "林中空地",
  "width": 6,
  "height": 4,
  "tilewidth": 150,
  "tileheight": 75,
  "orientation": "isometric",
  "renderSpacing": [2, 2],
  "origin": [1200, 64],
  "autoReload": true,
  "tilesets": [
    { "source": "../tilesets/dungeon-atlas.json", "firstgid": 1 }
  ],
  "layers": [
    {
      "id": "ground",
      "name": "ground",
      "type": "tilelayer",
      "layer": 0,
      "visible": true,
      "data": [1, 1, 1, 1, 1, 1,
               1, 1, 2, 1, 1, 1,
               1, 1, 1, 1, 3, 1,
               1, 1, 1, 1, 1, 1]
    },
    {
      "id": "actors",
      "name": "actors",
      "type": "objectgroup",
      "layer": 2,
      "visible": true,
      "objects": [
        { "name": "spawn_1", "type": "spawn",
          "x": 1920, "y": 289, "width": 0, "height": 0, "properties": [] },
        { "name": "chest_1", "type": "chest",
          "x": 2070, "y": 364.5, "width": 0, "height": 0,
          "properties": [ { "name": "loot", "type": "string", "value": "item.potion" } ] }
      ]
    }
  ]
}
```

坐标是这么来的。`origin = (1200, 64)`，`pitchX = 300`，`pitchY = 150`：

```text
spawn_1 在格 (1,1):
  worldX = 1200 + (1-1) * 150 = 1200
  worldY =   64 + (1+1) *  75 =  214
  centerX = 1200 + 150/2 = 1275
  centerY =  214 +  75/2 = 251.5
```

（示例里写的是别的坐标——目的是提示一个常见错误：对象 `x/y` 必须是**世界像素**，
而且**必须落在你想放的格子包围盒里**。工作流不校验这个，因为引擎也不校验；
用 `RpgcTilemap.worldOf(doc, tx, ty)` 或 `RpgcIso.centerX/Y` 算才是正解。）

### 7.3 校验

```bash
python tools/rpgc.py check content/tilesets/dungeon-atlas.json
python tools/rpgc.py check content/maps/forest-clearing.json
# 或一起
python tools/rpgc.py validate
```

期望 `PASS`。产出的引用统计里会有 `tileset: 1`（地图的 `tilesets[0].source` 解析成了
`dungeon-atlas`）。

### 7.4 故意改坏，看门怎么答

把 `renderSpacing` 改成 `[1, 1]`：

```text
WARN    /renderSpacing: tile/pitch ratios (1, 1) break the engine's cell picking;
        set renderSpacing so pitch is twice the tile size (the shipped isometric convention)
```

把 `data` 删掉两个元素：

```text
ERROR   <path>:/layers/0/data: layer 'ground' has 22 cells, expected 24 (6x4)
        hint: the engine rejects a mismatched data array at load time
```

把某个 GID 改成 `9`（超出 1..3）：

```text
ERROR   <path>:/layers/0/data: layer 'ground' uses 1 GID(s) outside the atlas range 1..3 (9)
        hint: the engine only verifies the cell count and would render a debug colour
```

删掉 `spawn_1`：

```text
ERROR   <path>:/layers: no object of type 'spawn': the level has no player start
        hint: add an objectgroup object with type 'spawn'
```

把 `forest-clearing.json` 改名成 `clearing.json` 而不改 `id`：

```text
ERROR   <path>:/id: document id 'forest-clearing' must equal the file stem 'clearing'
        hint: rename the file or fix the id
```

把 `tileheight` 改成 `80`（与图集 75 不符）：

```text
ERROR   <path>:/tilewidth: map tile size 150x80 does not match the atlas 150x75
        hint: the engine uses the map size for the cell and the atlas for UVs
```

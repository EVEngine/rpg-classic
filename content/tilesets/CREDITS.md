# 地形素材来源与授权（rpg-classic）

本目录的图集由 `assets/` 下已下载的素材包生成，**全部为 CC0 / 公有领域**：
CC0 不要求署名，但来源记在这里，便于复核与重建。

| 图集 | 来源包 | 视角 | 瓦片数 | 说明 |
|---|---|---|---|---|
| `sbs-atlas.json` | 手写 | 等距 | 24 | 精选起步图集，**GID 1–8 是示例地图的公开契约**，仍为 version 1 |
| `sbs-floors.json` | SBS 等距地面 | 等距 | 504 | 14 种材质 × 2 张图集 × 18 格 |
| `sbs-overworld.json` | SBS 大世界 | 等距 | 180 | Flat / Thick |
| `sbs-walls.json` | SBS 墙体 | 等距 | 936 | Flat `128x192` / Thick `144x200` / Corner `160x200` |
| `sbs-objects.json` | SBS 道具 | 等距 | 384 | 箱子 / 台阶 / 压顶 |
| `sbs-town.json` | SBS 城镇 | 等距 | 443 | 建筑 `64x96` / 屋顶 `144x92` |
| `kenney-dungeon.json` | Kenney Isometric Miniature: Dungeon | 等距 | 288 | 地面 / 石墙 / 门 / 楼梯 / 桌椅 / 箱子 |
| `kenney-farm.json` | Kenney Isometric Miniature: Farm | 等距 | 220 | 农田 / 木墙 / 屋顶 / 围栏 / 干草 |
| `kenney-library.json` | Kenney Isometric Miniature: Library | 等距 | 141 | 书架 / 长桌 / 地毯 / 陈设 |
| `kenney-bases.json` | Kenney Isometric Miniature: Bases | 等距 | 160 | 草地 / 泥土 / 雪地 / 石地 / 木地板底座 |

**合计 3256 块瓦片**，来自 5 个 SBS 包与 4 个 Kenney 包。

作者：Screaming Brain Studios（<https://screamingbrainstudios.com>）、
Kenney（<https://kenney.nl>）。两者均为 CC0。

## 图集文档存的是规则，不是元素

九个图集合计 **163 KB** 的 JSON 描述 3256 块瓦片——平均每块 50 字节，
而如果逐块写出 region / pivot / walkable / cost / sortBias / footprint /
遮罩，同样的数据是 **1.5 MB**（每块约 470 字节）。

version 2 的文档只存四样东西：

```json
{
  "count": 288,
  "layout": { "pack": "shelf", "width": 1408, "maxDim": 8192, "firstTile": 0 },
  "classes": { "floor": { "pivotRule": "cell-origin", "walkable": true, "cost": 1, ... },
               "prop":  { "pivotRule": "ground-anchor", "walkable": false, ... } },
  "runs": [ { "count": 21, "cell": [128, 64], "class": "floor" }, ... ]
}
```

`runs` 是有序的尺寸序列（连续同尺寸合并成一条）。**货架打包是确定性的**，
所以运行时用同样的算法重放 `runs` + `layout.width`，就能精确复原每一块瓦片的
`region`；`pivot` 由 `class` 的 `pivotRule` 现算。没有一处逐块数据，
也不需要把它留在内存里——`RpgcTilemap.tilesOf(doc)` 按需算，
`tools/bake_tilesets.py` 在需要喂给引擎加载器时才展开。

**这没有让图集变大。** 打包算法和宽度都没变，`kenney-dungeon.png` 等九张图
与重做之前逐字节相同（`--check` 断言这一点）。

### 引擎侧：按需烘焙

引擎的 `TileConfig.cpp` 只认逐块的 `tiles[]`。所以：

```bash
python tools/bake_tilesets.py          # 写出 <id>.baked.json
python tools/bake_tilesets.py --check  # 校验烘焙产物是否过期
```

`*.baked.json` 是**生成物**，已 gitignore；地图要引用规则图集时，把
`tilesets[].source` 指向 `.baked.json` 而不是规则文件。`sbs-atlas.json` 是
version 1，本来就是引擎形态，不需要烘焙。

## pivot 的两种写法，以及一个未决问题

`pivot` 是"region 里与格子投影原点重合的那个点"：`TileSystem.cpp:293-294`
把贴图画在 `tileToWorld(...) - pivot`，而 `GridProjection.cpp:41-42` 让
`tileToWorld` 落在格子菱形的**包围盒左上角**（`RpgcIso.centerX` 要 `+tileWidth*0.5`
才拿到菱形中心，正是这个原因）。由此：

- `cell-origin`：`[0, 0]`。精灵本身就是格子（地面、整格墙块），和地面瓦片的
  `[0, 0]` 完全一致。
- `ground-anchor`：`[w/2 - tileWidth/2, h - tileHeight/2]`。把精灵自己的
  接地锚点（内容包围盒底边中点）搬到格子中心。**Kenney 四个包用这一条。**
- `ground-anchor-legacy`：`[w/2, h]`。锚点即 pivot，不再减去半格。
  **五个 SBS 包沿用这一条**，与它们此前交付的产物一致。

差别就是半格：按上面的推导，`legacy` 会让道具落在格子左上角而不是格子中心，
即向左上偏移 `(tileWidth/2, tileHeight/2)`。这是**从源码读出来的结论，没有
渲染验证**——引擎宿主目前起不来（见下），所以我没有把它一并改掉：
改 SBS 会动到你已经在评审的产物，改不改由你决定。要改就是把这五个包的
`"pivot"` 键从默认改成 `"origin"` 再重跑导入。

## Kenney 包：进了什么，没进什么

四个 Isometric Miniature 包全部导入。两处是**排除**，都不是授权问题：

| 目录 | 处理 | 原因 |
|---|---|---|
| `Characters/`（仅 dungeon 包，168 张） | 排除 | 你在前面明确说过不要人物/动物素材 |
| `Angle/`（四个包各一套，共 820 张） | 排除 | **不是等距投影**：`Angle` 的地面渲染成轴对齐的正方形网格（45° 旋转视点），放在 2:1 菱形格上必然错位。`Isometric/` 才是可用的一套 |
| `Samples/`（`.zip` 示例工程） | 排除 | 非素材 |

`angle` 与 `isometric` 的同一物件逐像素不同（288/288 张全不同），确认是两套
视角而不是重复文件。若要收进来，只需在 `KENNEY_PACKS` 里加一条 `root` 指向
`Angle/`，它会成为独立图集，不会混进 `Isometric` 那套。

网格来自 Kenney 包自己的 Tiled 示例工程
（`Samples/Tiled Sample.zip → Sample.tmx`）：

```xml
<map orientation="isometric" width="60" height="32" tilewidth="256" tileheight="128">
```

即 Kenney 的原生格是 `256x128`，是本项目 `128x64` 的两倍，所以每张精灵按
`0.5` 缩放。这与 SBS 的处理一致（SBS "Large" 也是 `256x128` 源，同样减半）。

同一物件按 `_N/_S/_E/_W` 各出一张（共 4 朝向）。对称物件的四张完全一样，
导入时按内容哈希去重，所以 820 个文件收敛成 809 块瓦片。

## 导入是怎么做的

`tools/import_terrain_assets.py` 支持两种包形状：

**sheet 包（SBS）**：一个 PNG 里是多格 sheet。格尺寸来源依次是——同名 Tiled
`.tsx` 的 `tilewidth`/`tileheight`/`columns` 与 `trans="rrggbb"`；否则文件名里的
`<W>x<H>`（SBS 每个文件都带）。按该格切 `列 × 行`，**每格都收**；切不整的
文件不猜、直接报告。透明键有三种（洋红 / 黑 / 青），一律**全局**去底，不能只
洪泛边缘——打包密集的 sheet 会把背景封成一格一格的死袋。

**single 包（Kenney）**：一个 PNG 正好一个物件，画在 `256x512` 画布上、四周是
透明留白。不切格：裁到内容包围盒，再按 `0.5` 缩放。

两者随后都进同一个流程：按内容哈希去重 → 货架打包（每行按最高瓦片前进，超过
纹理上限自动分页）→ 把有序尺寸序列压成 `runs`。

**没有留下的包**（都是"切不整"，不猜）：

- `SBS - Isometric Object Pack/Temple Kit/104x80 Temple Kit.png`（320x312 不是 104x80 的整数倍）
- `SBS - Isometric Object Pack/Temple Kit/Temple Kit Demo.png`（文件名里没有尺寸）

## 重建方法

```bash
# 精选图集（会自己解压 assets/*.zip|*.rar）
python tools/build_sbs_atlas.py --archives assets
python tools/build_sbs_atlas.py --archives assets --check

# 全量导入（读 assets/ 下已解压的目录）
python tools/import_terrain_assets.py --plan    # 只统计，不写盘
python tools/import_terrain_assets.py           # 生成图集 + 规则文档
python tools/import_terrain_assets.py --check   # 校验磁盘产物与重新构建一致

# 引擎可读的展开（生成物，已 gitignore）
python tools/bake_tilesets.py
python tools/bake_tilesets.py --check
```

导入在写盘前跑**结构自检**：产物必须通过 `schema/eve.rpgc.tileset.json`
（字段类型 / 必填 / 上下限 / `additionalProperties:false`），并且**重放
`runs` 能还原出与图集逐字节一致的布局**——GID 连续、每块 region 落在图内、
pivot 与它的 `pivotRule` 自洽。这条不是抽查：重放对不上就整体失败。

## 这一轮验证了什么，没验证什么

**验证过：**

- `--check` 通过：九个规则文档与九张图集都能由当前代码逐字节重建；
- 重放自检通过：3256 块瓦片的 region 全部落在各自图集内、GID 连续、
  pivot 与类别规则自洽；
- **图集未变**：九张 PNG 与改格式之前逐字节相同；
- **引擎真的跑起来了**：`eve run` 在 workflow 目录下启动，
  `boot: game script loaded` → 持续到 6600 帧，`eve.log` 里零 error；
- **version 2 的重放路径被真正执行过**：临时把两张地图的
  `tilesets[0].source` 指向 `kenney-dungeon.json`（规则文档）再 `eve run`，
  游戏正常加载并跑到 1200+ 帧无报错，随后已把地图改回 `sbs-atlas.json`。
  这走的就是 `RpgcTilemap.tilesOf` 的重放分支。

**没验证：**

- pivot 的贴合**没有渲染验证**。半格偏移的结论来自源码推导，不是肉眼对照。
  截图需要引擎自带的截图接口。

> 早先这里记着「`python tools/rpgc.py validate` 跑不起来，宿主报
> `engine did not start listening`」，所以 `RpgcTilemap.tilesetDiagnostics` 里那几条
> 规则校验没被执行过。**该结论已作废**：宿主起不来的原因是用错了二进制——
> 必须以仓库自建的 `build/win32-debug/src/engine/eve.exe` 为准（`EVE_BIN`），
> 已发布的 SDK 二进制早于 `dofile` / `EditorHost` 的 `import` 实例化修改。
> 现在九个图集每次都真的过一遍 `tilesetDiagnostics`：
>
> ```bash
> EVE_BIN=<repo>/build/win32-debug/src/engine/eve.exe python tools/rpgc.py validate
> # → result : PASS · ok   （tileset=9）
> ```

## 尚未处理

- `content/tilesets/dungeon-atlas.json` 是更早的占位图集，**已不被任何地图引用**，
  它引用的 `dungeon-atlas.png` 从来没有存在过。是删是留仍需你决定。
- `content/anims/hero.json` 与 `fireball.json` 指向的 PNG 不存在，
  详见 [`../anims/CREDITS.md`](../anims/CREDITS.md)。
- `assets/` 里的 **125 MB 原始素材包没有被 gitignore**（只忽略了
  `assets/extracted/`）。规则文档把 JSON 从 1.5 MB 压到 163 KB，但图集本身
  仍有 59 MB，是否入库由你决定。

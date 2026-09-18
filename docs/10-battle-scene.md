# 10 · 战斗场景：左上敌阵与右下我方

> 本文说明 `eve.rpgc.battle` 这一类内容文档：一屏分成两半的屏幕布局、左上 8 个敌方阵位与
> 右下 5 个我方阵位的上限、六份战场文档，以及为什么这一整类内容在引擎里**没有任何对应
> 类型**——也就没有任何加载器会替我们拒绝一份画错的战场。
>
> 战斗数值与五行击破在 [`06-game-design.md`](06-game-design.md) §3–§5；敌人原型与遭遇编队
> 在 [`09-enemies-and-encounters.md`](09-enemies-and-encounters.md)；本文只回答一个问题：
> **谁站在屏幕的哪里。**

## 1. 契约：一屏、两半、两块阵地

一份 `eve.rpgc.battle` 只描述屏幕几何，不含任何数值：

| 字段 | 含义 |
|---|---|
| `canvas.width` / `canvas.height` | 设计空间分辨率（如 `1920 x 1080`）。所有坐标都在这个空间里，与运行时窗口大小无关 |
| `zones.enemy` | 敌阵矩形 `{x, y, width, height}`，必须在**左上那一半**里 |
| `zones.ally` | 我方矩形，必须在**右下那一半**里 |
| `enemySlots[]` | 敌方阵位 `{id, x, y}`，最多 **8** 个 |
| `allySlots[]` | 我方阵位 `{id, x, y}`，最多 **5** 个 |
| `encounters[]` | 这块战场承接哪些遭遇（至少一条） |
| `background`（可选） | 画出来的战斗背景，**文档相对路径**（如 `backdrops/backdrop.desert.png`）。见 §6 |
| `ui.party`（可选） | 右下人物 HUD 的几何。见 §6 |
| `ui.commandRing`（可选） | 左边操作环的几何。见 §6 |

「左上」与「右下」是**两个轴同时成立**的约束，不是「大致在左上」：

```text
敌阵：  x + width  <= canvas.width  / 2     且   y + height <= canvas.height / 2
我方：  x          >= canvas.width  / 2     且   y          >= canvas.height / 2
```

只满足一个轴是最容易犯的错：把敌阵整体右移到 `x = 400`（宽 760）时，它仍然在**上**半屏，
但右边缘已经越过中线，两条阵线就变成左右并排了。文档里看不出来，画出来一眼就是错的——
所以语义门对两个轴分别报错（`systems.battle-zone-half`），编辑器预览也把中线画出来。

阵位坐标必须落在**自己那块阵地**里（`systems.battle-slot-outside-zone`），同一侧的
两个阵位不能落在同一点（`systems.battle-slot-collision`）——两只单位叠在同一个像素上
是最典型的「文档合法、画面报废」。

## 2. 引擎没有的那一半

这是本 kind 与前面所有 kind 最大的不同：**没有下游**。

- `eve.rpgc.map` / `eve.rpgc.tileset` 由引擎自己的加载器读（`Map::loadFromFile…`）；
- `eve.rpgc.encounter` 被 `EncounterCatalogue.replaceFromJsonStrict` 读，而且是**原子**拒绝；
- `eve.rpgc.battle` **什么都不是**。`src/modules/rpg` 里没有战场、阵型、战斗位置这一类
  符号；它里面唯一叫 `slot` 的东西是 `equipmentSlot`（装备槽，`RPGSaveSession.h:36`）与
  背包格子（`RPG.cpp:1013`），和战斗站位无关。

需要说明的一处「看起来像」：`src/modules/rts` **确实**有一套阵型系统——
`enum class FormationKind`（`src/modules/rts/RTSSystems.h:23`）、`struct FormationSpec`
（同文件 `:30`）、`FormationPlanner::plan`（`RTSSystems.cpp:411`）、以及 `OrderComponent`
的 `formationSlot`（`src/modules/rts/RTSTypes.h:124`）。但那是 **RTS 的命令扇出**：把一次
攻击/移动命令按 `Line` / `Grid` / `Wedge` 摊到世界坐标上的单位，输入是 `WorldPosition`
锚点与间距，不是「屏幕左上角有 8 个位置」。rpg-classic 这套回合制工作流也不加载 `rts`
模块。两者同名不同物，**不能**互相投影。

因此这里没有 `tools/build_*.py` 那样的投影工具：没有引擎形态可投影，文档本身就是真源，
运行期适配器是纯投影（见 §5）。

## 3. 六份战场

`content/battles/` 下六份文档，按地形分档。**敌位上限 8 是设计常量**，只有隘口因为地形
本身排不开而给了 6；我方一律 5，因为「最多 5 名队友」是容量而不是人数。

| id | 名称 | 敌位 | 我位 | 承接的遭遇 | `background` |
|---|---|---|---|---|---|
| `battle.open-field` | 旷野 | 8 | 5 | `outskirts-night` `yumen-dunes` | `desert` |
| `battle.mountain-pass` | 隘口 | **6** | **4** | `jiange-ambush` `xiangyang-pass` `yanmen-raid` | `snow-mountain-pass` |
| `battle.waterfront` | 渡口 | 8 | 5 | `canglang-night` `kaifeng-wharf` `luoxia-wreck` | `waterfront` |
| `battle.town-square` | 城镇广场 | 8 | 5 | `changan-caravan` `luoyang-market` `jinling-alley` | *(无)* |
| `battle.forest-clearing` | 林间空地 | 8 | 5 | `mist-forest-deep` `miaoling-hex` | `golden-plain` |
| `battle.snowfield` | 雪原 | 8 | 5 | `xueling-frost` | `snow-mountain-pass` |

`town-square` 没有背景、`forest-clearing` 用的是「沼泽落日」（本组里最弱的一次匹配）：
四张合规的 CC0 背景覆盖不了六种地貌，缺口与理由是**写明的**而不是凑一张错的
（[`content/battles/backdrops/CREDITS.md`](../content/battles/backdrops/CREDITS.md) 的
「已知缺口」一节）。`mountain-pass` 与 `snowfield` 共用雪山那张，是 §6.1 说的情况。
四张背景全部 1920×1080，来源与 SHA-256 见 `assets/<pack>/SOURCE.json`。

14 场遭遇 × 6 块战场，覆盖关系由跨文档门强制（§4）。当前**没有一份战场是紧的**：

| 战场 | 敌位 | 承接的最大编队 | 余量 |
|---|---|---|---|
| `open-field` | 8 | 3 | 5 |
| `mountain-pass` | 6 | 3 | 3 |
| `waterfront` | 8 | 3 | 5 |
| `town-square` | 8 | 3 | 5 |
| `forest-clearing` | 8 | 4 | 4 |
| `snowfield` | 8 | 3 | 5 |

也就是说容量门在**真实内容**上一次都没点火——这是刻意的余量，不是失效的检查。
它在探针里有确定的证据（`tools/modules_check.nut` 的 `cross.battle-capacity`），
而只要把任一场遭遇的 `count` 提到超过 `mountain-pass` 的 6，它立刻会在真实内容上点火。

**我方阵位是容量，不是名单。** 谁站在那 5 个位置上取决于运行期的 `Party`，内容文档
不可能知道队伍里现在有几个人，所以 `allySlots` 只声明「右下最多能有 5 个位置」。

## 4. 门：这一层唯一的检查者

`battle` 没有下游，所以六层门是**唯一**会看这份文档的东西。

| 层 | 检查 | 代码 |
|---|---|---|
| 0 严格 JSON | 重复键 / 尾逗号 / 控制字符 | `json.*` |
| 1 Eve Schema v1 | 字段名、类型、`additionalProperties: false`、canvas/坐标的数值上下限 | `validate.schema` |
| 2 文档语义门 | id、`displayName` 非空、canvas 为正、两块阵地有面积且在画布内、**两块阵地各在正确的一半（两个轴）**、阵位 id 合法且不重复、阵位在自己阵地内、同侧阵位不重叠、**敌位 ≤ 8 / 我位 ≤ 5**、`encounters[]` 的 id 形状与不重复；**以及 `background` / `ui` 那一层**（见 §6）：HUD 在右下半、操作环在左半、两者都不压敌阵、头像数与条数与环上键数不超上限、头像数覆盖得住阵位、头像横排装得进面板、条不溢出头像条下方的预算、键不越出环也不重叠、`background` 非空 | `systems.battle-*` |
| 3 引用门 | `encounters[]` → 真实存在的 `encounter` | `ref.dangling` |
| 4 模块额外检查 | **容量**：承接的每场遭遇投影后的出场人数 ≤ 该战场敌位数；**覆盖**：每场遭遇恰好被一块战场承接（0 块 = 没有布局，2 块 = 两个答案） | `systems.battle-capacity` / `systems.encounter-without-battle` / `systems.encounter-hosted-twice` |
| 5 失败关闭 | schema 文件缺失、`module` 对不上模块名一律报错，不跳过 | `validate.unknown-module` |

关于上限，有一处刻意的设计：**8 与 5 没有写成 schema 的 `maxItems`。**

`RpgcValidate.validateDocument` 在 schema 失败时**直接返回**（`lib/rpgc_validate.nut:158`），
语义门根本不会跑。如果 `enemySlots` 写了 `maxItems: 8`，那么第 9 个阵位只会得到一条
`validate.schema`，而 `systems.battle-slot-count` 永远不可达——**一个永远不会点火的门
等于没有门**（`rpgc_systems.nut` 自己对这件事的注释见 §「document source」上方）。
所以那两个数字只存在一处：`RpgcSystems.maxBattleEnemySlots` / `maxBattleAllySlots`，
语义门用它，跨文档的容量门也用它。改一个数字，两处检查同时改变。

`systems.battle-no-encounter`（一块战场一场都不接）同样只写在跨文档门里，理由一样：
schema 的 `minItems: 1` 会让空数组在第 1 层就被拒，语义门里的同一条检查会是死代码。

## 5. 运行期：适配器是纯投影

`battle` 文档不产生第二份真值。运行期要做的事只有一件：**把编队下标映射到阵位下标**。
`lib/rpgc_battle.nut` 的 `placeOnScene()` 就是这条映射本身（它只读阵位坐标，不含任何
数值判断），`main.nut` 再把坐标按 `fitToViewport()` 等比缩放进视口。战斗怎么算、
谁先动手见 [`11-battle-system.md`](11-battle-system.md)。

```text
敌人在屏幕上的位置
  遭遇 members[] 按顺序展开成 N 个成员（tools/build_encounters.py 的同一套展开）
  -> N <= battle.enemySlots.len()（容量门保证）
  -> 第 k 个成员用 enemySlots[k]

我方在屏幕上的位置
  Party 里的第 k 名成员 -> allySlots[k]（k < battle.allySlots.len()）
  队伍人数由运行期决定，文档只管位置够不够

背景
  取自 encounter.map —— 一块战场可以承接不同地图上的战斗，
  所以战场文档里故意没有 `map` 字段：那会是同一件事的第二个出处
```

`battle.waterfront` 同时承接沧浪渡、开封码头、落霞岛三场遭遇，就是这条规则的存在证明。

一份适配器只需要读三个数：`zones.enemy` / `zones.ally`（用来把设计空间缩放进视口）
和每个阵位的 `x` / `y`。没有需要「解释」的字段，也没有需要调的引擎 API——
这正是这一层能保持纯投影的原因。

## 6. 战斗界面：背景、人物 HUD、左边的操作环

`background` 与 `ui` 是**可选**的加层。没有它们的战场文档依然是合法文档，只是不画
背景也不画界面控件——这也是为什么在它们存在之前就写好的那六份战场文档一个字都不用改，
schema 的 `version` 也因此留在 1：文档信封没有变。反过来，`additionalProperties: false`
意味着**用**了这两个字段的文档需要一个认识它们的校验器，这是失败关闭的方向：老读者
拒绝这样一份战场，而不是静默丢掉这一层。

### 6.1 `background`：画出来的背景，不是「战斗在哪」

[`content/battles/backdrops/`](../content/battles/backdrops/CREDITS.md) 里有四张 CC0
背景，由 `tools/import_battle_backdrops.py` 下载、裁切到 16:9、放大到 1920×1080，
`--check` 逐字节重算。

字段是**文档相对路径**，语义与 `tileset.image` / `anim.image` 完全一致：

```json
"background": "backdrops/backdrop.desert.png"
```

它和遭遇的 `map` 是**两件不同的事**：`map` 是玩法上的地点，`background` 是画出来的
那一层。所以两块战场可以共用一张背景（`snowfield` 与 `mountain-pass` 就共用雪山那张），
而同一张背景也可以出现在不同地图的战斗里。

它**没有** `fit` / `tint` / `parallax` 开关，这不是偷懒：脚本侧只暴露
`drawTexturedRect(texture, x, y, w, h, r, g, b, a)`，**没有** `drawTexturedRectUV`
（`src/modules/graphics/Graphics.cpp:1181-1197`）。一个文档能声明、投影却做不到的
`fit` 模式，会让文档和画面悄悄说两件事——正是这套工作流防的那种失败。编辑器改为
报告纹理的真实像素尺寸，于是宽高比对不上画布是**看得见**的，而不是看不见。

`ui` 块内部的两个面板都是 `required`，而**上界**（行数、条数、键数）刻意不写成
schema 的 `maximum` / `maxItems`：schema 先拒绝，语义门就跑不到，那几条门就成了
永远不会点火的死代码。理由与 §4 里 8/5 的处理完全一样。

### 6.2 `ui.party`：右下人物 HUD —— 一排头像，血条在底下

```json
"party": {
  "x": 1310, "y": 840, "width": 570, "height": 200,
  "slots": 5, "slotWidth": 104, "slotGap": 8, "portraitHeight": 130,
  "bars": [
    { "id": "hp", "offsetY": 8,  "height": 18, "colour": [0.30, 0.72, 0.36] },
    { "id": "mana", "offsetY": 32, "height": 18, "colour": [0.25, 0.48, 0.85] }
  ]
}
```

| 字段 | 含义 |
|---|---|
| `x` / `y` / `width` / `height` | 面板矩形，必须在**右下那一半**里（与 `zones.ally` 同一条两轴规则） |
| `slots` | 横排能放几个头像；1..5，上限来自 `RpgcSystems.maxBattleAllySlots` |
| `slotWidth` / `slotGap` | 单个头像格宽度与格间距（画布单位） |
| `portraitHeight` | 头像那一条的高度；条在它**下面** |
| `bars[]` | 头像条下方的资源条：`{id, offsetY, height, colour}`，`offsetY` 从**头像条底边**量起。`id` 是 `hp`，或规则文档 `/resources` 里某个池子的 `attribute`（`systems.battle-ui-bar-unregistered`） |

**条的名字是池子的名字，不是显示名。** 运行期拿 `id` 去单位的资源表里查（`main.nut` 的
`hudPoolCurrent` / `hudPoolMaximum`），查不到就是 `0/0` —— 一条**永远填不满**的条，在屏幕上
和「这个人正好没蓝了」长得一模一样。六份战场文档原本写的是 `mp`，而
`rules.wuxing.json` 注册的池子是 `stamina` 与 `mana`：第二条条从写下那天起就没亮过，schema
只查了 id 的形状（`systems.battle-ui-bar-id`），没有任何一层能看见这个分歧。名字对不上现在
由 `systems.battle-ui-bar-unregistered` 拒绝，反例探针是
`reject.battle-ui-bar-unregistered`。

**它是横排，不是竖排列表。** 五个人就是屏幕底边一排五张脸，这比「头像在左、数字在右」
的五行堆叠既小又一眼看得完，需要的条也从十条变成两条。方向变了，于是「装不下」这件事
也换了一个轴：横排要装的是**宽**——`slots × slotWidth + (slots-1) × slotGap` 必须
≤ 面板宽度（`systems.battle-ui-row-overflow`），装不下就是把最后一张脸挂到 HUD 外面。

**HUD 里没有数值，这是刻意的。** `hp` 与资源池是运行期的 `Party` 状态，内容文档不可能
知道；写一个假的分母会让「文档就是真源」变成「文档是某一时刻的快照」。编辑器画的是
空的头像格、破折号名字与固定演示比例的条，并把这一点写在面板注释里。运行期则相反：
它读得到真值，于是每个头像格都印出名字与 `id 当前/上限`（见
[`11-battle-system.md`](11-battle-system.md) §5）。

三条容易漏的规则：

- **头像数必须覆盖得住阵位**（`systems.battle-ui-slots-coverage`）：`slots < allySlots.len()`
  时，站在最后一个阵位上的队友**根本没有头像**。`allySlots` 是容量不是名单，所以
  这是容量比较，不是人数比较。
- **条与头像共用面板的高度**（`systems.battle-ui-portrait-overflow`）：`portraitHeight`
  大到没给条留空间时，条会被画在它正在汇报的那几张脸上。
- **条的预算从头像底边算起**（`systems.battle-ui-bar-overflow`）：`offsetY + height`
  超出 `height - portraitHeight` 就溢出。`offsetY` 是**整条 HUD 的相对量**，因为五张脸
  共用同一条血条，不再有「第几行」这个坐标系。

### 6.3 `ui.commandRing`：左边的操作环

```json
"commandRing": {
  "cx": 300, "cy": 800, "radius": 190,
  "buttons": [
    { "id": "cmd.attack", "x": 410, "y": 800, "radius": 40, "label": "攻击" },
    { "id": "cmd.skill",  "x": 300, "y": 690, "radius": 40, "label": "招式" },
    { "id": "cmd.item",   "x": 190, "y": 800, "radius": 40, "label": "物品" },
    { "id": "cmd.defend", "x": 300, "y": 910, "radius": 40, "label": "防御" }
  ]
}
```

环整个必须在**左半屏**（`cx + radius <= canvas.width / 2`），每个键**整个**必须在环内
（`距离 + 键半径 <= 环半径`），键与键不得重叠。键数上界 8 同样只在语义门里。

这里有一条**故意不写**的规则：**「两个面板不许重叠」是不写的**。环在左半、HUD 在右半，
两条半屏规则已经蕴含它们不可能重叠，写了就是一句永远为真的话。同理**「HUD 压住敌阵」
也是不写的**：敌阵必须在 `canvas.width / 2` 之前结束、HUD 必须在那之后开始，HUD 遵不遵守
自己那条半屏规则就决定了它压根够不着敌阵。**唯一够得着敌阵的面板是操作环**——「在左半」
并不蕴含「在下半」，一个抬高的环确实能压在怪身上，所以只有它有一条
`systems.battle-ui-overlaps-enemies`。

这三处不写，是 `tools/modules_check.nut` 的探针**逼**出来的：先写出检查，再写人工构造
的反例，反例证明不了自己会失败，就说明它不可达。同一个探针也逼掉了另外两条：面板零面积
与环零半径（schema 的 `minimum: 1` 先拦），以及 `ui` 缺面板（schema 标了 `required`）。

### 6.4 编辑器怎么画

`editors/battle.vm.nut` 的 `draw` 顺序是：背景 → 两半与中线 → 两块阵地 → HUD 与操作环 →
阵位标记。控件压在阵位标记下面是有意的：选中单位的高亮必须留在最上层，否则你看不出
自己选了谁。

背景是**懒加载**的，而且 `backgroundTexturePath` 记的是**最后一次尝试过的路径**，
成功失败都记。不这样做的话，一张加载失败的背景会让纹理和路径都保持空，守卫永远不成立，
于是**每帧都重新尝试打开一次文件**。失败会写一行 `eve.log` 的 `warn`，
否则 `newTextureFromFile` 会把它吞掉，场景只是安静地不画背景。

## 7. 编辑器

```bash
eve run apps/battle
```

面板（`editors/battle.editor.json` + `editors/battle.vm.nut`）把设计空间**等比**缩放进
预览矩形（letterbox，不拉伸），画两半底色、两条中线、两块阵地边框与每个阵位；
选中的阵位加一圈高亮，**越出自己阵地的阵位画成白色**——语义门会拒它，画面应该先说。

三个页签：**场景**（文件夹列表 / 重扫 / 新建 / 保存，以及 canvas、两块阵地、承接遭遇的
只读回显）、**阵位**（两侧各一份位置列表与 X/Y 滑块，新增/删除/应用坐标）、
**诊断**（status + `RpgcSystems.semanticDiagnostics` 的结果）。

场景页顶部的标题绑定 `vm.folderLabel`，显示的是 `content/battles  ·  6 个文档`：
编辑器读的是 `workflow.json` 给 `battle` 指定的那个目录，**选中一行就是载入**，
没有「打开文档」这一步（其余三个编辑器同样如此，见 `docs/01-tilemap-editor.md` §6.1）。

两处刻意的本地拒绝：新增第 9 个敌位或第 6 个我位时面板直接说明上限，不让你先存再被门拒
（和 `event.vm.nut` 的 `indentStep` 拒绝二层嵌套是同一个理由——让人当场学到规则）。
X/Y 滑块是**每侧一对**、应用按钮也是**每侧一个**：只做一个「当前选中侧」的隐式状态，
就会出现「滑块显示的和我以为的不是同一侧」这种只能靠点一次才知道的错。

保存走的是和其它编辑器完全相同的那条路：`RpgcStore.checkRevision` → `RpgcValidate.commitDocument`
→ 暂存 → `tools/rpgc.py export`（`README.md` 的「持久化：为什么不能直接写盘」）。

## 8. 加一场战斗 / 加一块战场

加一场战斗（已被现有战场覆盖时**不需要动战场文档**）：

1. 在 `content/encounters/` 加一份 `eve.rpgc.encounter`；
2. 把它加进某块战场的 `encounters[]`。

漏掉第 2 步会被 `systems.encounter-without-battle` 拒绝，不会静默留下没有布局的战斗。

加一块战场：

1. 在 `content/battles/` 加一份文档，`canvas` 与两块 `zones` 满足 §1 的两个轴；
2. 阵位写成自己阵地内的坐标，敌位 ≤ 8、我位 ≤ 5；
3. `encounters[]` 列出承接的遭遇（每场遭遇全项目只能出现在一块战场里）；
4. `python tools/rpgc.py validate`（本机见 §9 的替代命令）；
5. `workflow.json` 的 `kinds`、`README.md` 的 kind 表、`06-game-design.md` §7 已经登记过
   `battle`，新增的是内容而不是 kind，所以这三处不用改。

## 9. 验收

本机 `eve mcp` 不监听端口（见 §10），所以 `python tools/rpgc.py validate` 走不通；
它跑的是同一个 `RpgcValidate.validateProject()`，改由 Squirrel 直接调：

```bash
cd .  # repository root
EVE=<repo>/build/win32-debug/src/engine/eve.exe
"$EVE" run --no-window -r tools/modules_check.nut   # grep "[modules]"
```

实测（本机，2026 年本轮）：

```text
[modules] gate PASS: 1 warning(s)
[modules] view battle: 10 command(s), 24 bind(s) checked against BattleVM
[modules] battle  status: battle.forest-clearing | canvas 1920x1080 | enemy 8 / ally 5 |
                    backdrop declared, not loaded yet | HUD 570x200 @ (1310, 840) · 5 个头像 × 104 (间隔 8) · 头像高 130 · 条 2 · 操作环 r190 · 4 键
[modules] ok   accept.battle-well-formed  unexpected []
[modules] ok   reject.battle-enemy-bank-cap  wanted systems.battle-slot-count
[modules] ok   reject.battle-ally-bank-cap   wanted systems.battle-slot-count
[modules] ok   reject.battle-enemy-bank-half-x / -y   wanted systems.battle-zone-half
[modules] ok   reject.battle-ally-bank-half-x / -y    wanted systems.battle-zone-half
[modules] ok   reject.battle-bank-off-canvas          wanted systems.battle-zone-outside-canvas
[modules] ok   reject.battle-slot-outside-bank        wanted systems.battle-slot-outside-zone
[modules] ok   reject.battle-slot-collision           wanted systems.battle-slot-collision
[modules] ok   reject.battle-slot-duplicate-id        wanted systems.battle-slot-duplicate
[modules] ok   accept.battle-ui-well-formed           unexpected []
[modules] ok   accept.battle-backdrop-path            unexpected []
[modules] ok   reject.battle-backdrop-empty           wanted systems.battle-background-empty
[modules] ok   reject.battle-ui-hud-half              wanted systems.battle-ui-half
[modules] ok   reject.battle-ui-hud-off-canvas        wanted systems.battle-ui-outside-canvas
[modules] ok   reject.battle-ui-ring-half             wanted systems.battle-ui-half
[modules] ok   reject.battle-ui-ring-off-canvas       wanted systems.battle-ui-outside-canvas
[modules] ok   reject.battle-ui-ring-over-enemies     wanted systems.battle-ui-overlaps-enemies
[modules] ok   reject.battle-ui-slots-cap            wanted systems.battle-ui-slots
[modules] ok   reject.battle-ui-slots-coverage       wanted systems.battle-ui-slots-coverage
[modules] ok   reject.battle-ui-bar-cap               wanted systems.battle-ui-bar-count
[modules] ok   reject.battle-ui-button-cap            wanted systems.battle-ui-button-count
[modules] ok   reject.battle-ui-row-overflow         wanted systems.battle-ui-row-overflow
[modules] ok   reject.battle-ui-portrait-overflow    wanted systems.battle-ui-portrait-overflow

[modules] ok   reject.battle-ui-bar-overflow          wanted systems.battle-ui-bar-overflow
[modules] ok   reject.battle-ui-bar-duplicate         wanted systems.battle-ui-bar-duplicate
[modules] ok   reject.battle-ui-bar-id                wanted systems.battle-ui-bar-id
[modules] ok   cross.battle-ui-bar-unregistered       wanted systems.battle-ui-bar-unregistered
[modules] ok   reject.battle-ui-button-outside-ring   wanted systems.battle-ui-button-outside-ring
[modules] ok   reject.battle-ui-button-collision      wanted systems.battle-ui-button-collision
[modules] ok   reject.battle-ui-button-duplicate      wanted systems.battle-ui-button-duplicate
[modules] ok   reject.battle-ui-button-id             wanted systems.battle-ui-button-id
[modules] ok   battle-backdrop.document-relative      content/battles/backdrops/backdrop.desert.png
[modules] ok   battle-backdrop.detector-sees-missing
[modules] ok   battle-backdrop.files-exist  5 declared; missing
[modules] ok   cross.encounter-without-battle         wanted systems.encounter-without-battle
[modules] ok   cross.encounter-hosted-twice           wanted systems.encounter-hosted-twice
[modules] ok   cross.battle-no-encounter              wanted systems.battle-no-encounter
[modules] ok   cross.battle-capacity                  wanted systems.battle-capacity
[modules] ok   battle.content-coverage  real content tree reports 0 battle error(s)
[modules] PASS (0 failure(s))
```

全脚本 217 条 `ok`、0 条 FAIL，连续四次运行结果一致。

`battle` 那一条状态行里写的是 `backdrop declared, not loaded yet` 而不是 `no backdrop`：
`modules_check.nut` 是 `eve run -r` 脚本，没有图形模块，纹理只会在编辑器 `draw()` 里
懒加载。**纹理真的加载成功的证据来自另一次运行**：`eve run apps/battle` 的 `eve.log`
在有图的两次运行里没有警告，而在故意把 `backdrop.golden-plain.png` 改名藏起来之后
写了一条

```text
warn | battle: backdrop 'content/battles/backdrops/backdrop.golden-plain.png' failed to load: Could not load image file: ...
```

同一条日志也证明了**文档相对路径解析**是对的：它打印的是解析后的工程路径
`content/battles/backdrops/...`，而不是文档里写的 `backdrops/...`。

全项目清点（同一进程内调 `RpgcValidate.validateProject()`）：

```text
15 kind(s), 150 document(s)：anim=10 art=4 battle=6 combo=2 effect=11 encounter=14
enemy=22 event=2 heart=1 item=25 map=14 rules=1 skill=28 tileset=9 world=1
gate PASS: 1 warning(s)
```

那唯一一条 warning 是既有的、刻意保留的 `systems.encounter-quest-unregistered`
（本工作流不建模 quest，见 `README.md` 的六层门表）。

`tools/modules_check.nut` 还新增了一条对**全部四个编辑器**的静态检查：遍历
`editors/*.editor.json`，把每个 `command` 与每个 `bind*`（含 `bind:options` /
`bind:label`）拿去对应 ViewModel 上解析。一个点不动的按钮或一个永远不刷新的字段，
在此之前只有 `rpgc.py selftest`（需要活宿主）才看得见；现在静态可查：

```text
[modules] view tilemap: 19 command(s), 22 bind(s) checked against TilemapVM
[modules] view skill:   11 command(s), 29 bind(s) checked against SkillVM
[modules] view event:   12 command(s), 33 bind(s) checked against EventVM
[modules] view battle:  10 command(s), 18 bind(s) checked against BattleVM
```

同一份脚本还断言四个编辑器**绑定在项目文件夹上**而不是手工维护的数组上：
`folder.<kind>.panel-shows-folder` 要求 ViewModel 的列表槽位等于磁盘上的目录内容，
`folder.<editor>.no-open-gesture` 要求视图里没有任何 `open*` 命令，
`folder.<editor>.list-loads-on-selection` 要求文档列表带 `onChange`。
这三条是"功能即缺席"的检查，所以 `folder.detector.*` 再用人工构造的节点
证明两个探测器**确实会失败**——一个永远答 ok 的检查和一个什么都不做的检查无法区分。

### 本轮没有验证的

- **没有渲染验证。** 面板的等比缩放、两半底色、越界阵位的白色标记都是照
  `eve.host.widgetRect("battle", "field")` 与 `drawSolidRect` 写的，
  但本轮没有截图；MCP 宿主起不来，`rpgc.py selftest` 的 `editors-loaded` /
  `drawer-status` / `vm-commands` 三项也跑不了。
- **投影出来的 `data/encounters.engine.json` 仍然没被引擎的加载器吃过。**
  `rpg` 绑定不可用（见 [`09-enemies-and-encounters.md`](09-enemies-and-encounters.md) §6），
  所以那一条投影仍是设计约定。**「成员下标 → 阵位下标」这条映射已经实测**：
  `lib/rpgc_battle.nut` 的 `placeOnScene()` 是它的实现，`tools/modules_check.nut` 的
  `battle.content.every-encounter-plays` 用真实内容树里十四场遭遇逐一开局并跑到终局
  （见 [`11-battle-system.md`](11-battle-system.md) §8）。
- **没有校验过阵位之间的最小间距。** 只拒「完全同一点」，因为「至少隔开多少像素」
  取决于精灵尺寸，而精灵尺寸在本工作流里不是受管数据（`README.md`「不解析图片」）。

## 10. 明确不做的事

- **不为战斗单独复制一份地图。** 背景来自 `encounter.map`，战场文档里没有 `map` 字段：
  两块战场承接同一张地图、或一块战场承接三张地图，都不需要第二个出处。
- **不管我方的名单。** `allySlots` 是容量；`Party` 是运行期状态，内容文档不知道队伍人数。
- **不做「前排 / 后排」的语义标记。** 前后关系完全由 y 坐标体现（y 小的靠敌阵），
  再加一个字段就是同一件事的第二个说法。
- **不投影成引擎形态。** 引擎没有对应类型（§2），所以没有 `data/*.engine.json` 产物，
  `tools/` 下也没有 `build_battles.py`。不发明一个只有本工作流认识的文件格式假装它是接口。
- **不把 8 / 5 写进 `rules`。** 它们是这一层的屏幕容量，不是战斗规则；
  `rules` 已经是五行 / 破绽 / 回合秒数 / 装备槽位词表的唯一出处，再塞进屏幕几何
  只会让两个模块共享同一份文档。

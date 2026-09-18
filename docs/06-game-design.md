# 06 · 武侠开放世界 RPG 核心系统设计

> 本文是**游戏设计**文档，不是工具链文档。01–05 说明 rpg-classic 这套工作流怎么用；
> 本文说明用这套工作流做出来的游戏长什么样：每一类内容落在哪一份文档、哪一个引擎 API 上，
> 以及哪些部分引擎根本没有、必须项目侧实现。
>
> 三条贯穿全文的约定：
>
> 1. **真源只有一份。** 规则写在文档里，运行期只是投影；适配器不产生第二份真值
>    （`04-runtime-integration.md` §4）。
> 2. **引擎没有的概念不塞进引擎。** 每一节把「引擎已有」「项目侧」「本设计新增的文档」分开写。
> 3. **新增一类内容 = 新增一个 kind。** 新 kind 必须在 `workflow.json` 里同时给出
>    `directory` / `schema` / `module`；只写 `module` 名字而不给实现会让门失败
>    （`validate.unknown-module`），而不是静默跳过
>    （`README.md` 的「内容 kind 表」一节、`lib/rpgc_validate.nut:227-244`）。

## 0. 七个系统与它们各自的数据层

| # | 系统 | 本设计新增 kind | 引擎已有的那一半 | 必须项目侧实现的那一半 |
|---|------|-----------------|------------------|------------------------|
| 1 | 多地图开放世界 / 时刻图 | `eve.rpgc.world` | 地图文档（多图层 + 对象层 + 对象契约）、`TileLayer` 的可见性/调色/换图集、daynight 时钟 | 跳转判定、门条件求值、时刻层与风格变体的选择 |
| 2 | 武功与品级 | `eve.rpgc.art` | `SkillDefinition`（冷却/读条/消耗/授予效果/tags）、职业按等级解锁技能 | 品级表、每级解锁与数值覆盖、绝招可用性 |
| 3 | 五行与弱点击破 | `eve.rpgc.rules` | 伤害带自由字符串 `element` + `TraitSystem::getElementRate` 倍率 | 相生相克表、破绽值、击破后的状态下降与眩晕 |
| 4 | 心法 | `eve.rpgc.heart` | `Trait`（paramRate / exParam / attackElement…）、`EffectDefinition`（modifiers / extra / stackPolicy） | 心法装配规则、命中后追加效果、五行归属覆盖 |
| 5 | 组合技 | `eve.rpgc.combo` | `tactics` 的行动与反应窗口、`Party` | 成员与条件判定、多段串行结算、合击演出 |
| 6 | 物品与装备 | `eve.rpgc.item` | `ItemDefinition` / `Bag` / `EquipmentSet`、`registerItemStatsFromJson` / `syncEquipModifiers` | 使用效果、秘籍教学、装备槽位词表、品级要求（逐条见 [`08-items-and-equipment.md`](08-items-and-equipment.md)） |
| 7 | 战斗场景与阵位 | `eve.rpgc.battle` | **没有**：`src/modules/rpg` 里没有战场 / 阵型 / 阵位；`src/modules/rts` 的 `FormationSpec` 是 RTS 命令扇出，不是战斗屏 | 屏幕布局、编队成员→阵位映射、等比缩放与背景（逐条见 [`10-battle-scene.md`](10-battle-scene.md)） |

顺序按「先世界、后战斗、最后物品」——物品要引用 effect / art / skill 三者，所以排在最后；
战斗场景要引用 encounter，所以排在物品之后。

---

## 1. 世界：多地图 + 边缘跳转 + 逐步开放 + 时刻

### 1.1 一张地图 = 一份 `eve.rpgc.map` 文档

- 一次只加载一张地图：`map.loadFromFileWithObjectContract(path, contractJson)`
  （`src/modules/map/Map.h:75`）。失败时保留当前地图，替换是事务性的
  （`src/modules/map/Map.h:52-54` 的 `@remarks`）。
- 图层：map schema 允许 1..16 个 `layers[]`，`type` 只允许 `tilelayer` / `objectgroup`
  （`schema/eve.rpgc.map.json:35-50`）。地图读取器**为每个 tile layer 建一个
  `TileLayer`**（`src/modules/map/Map.h:50` 的注释），并逐个读该层的 `visible`（`src/modules/map/TileConfig.cpp:626-627`）。
- 对象层承载 `spawn / npc / chest / portal`；类型白名单与必填属性在对象契约里
  （`data/world-object-contract.json:6-32`）。
  运行时按名字或坐标查：`Map::findObjectByName` / `findObjectAt`（`src/modules/map/Map.h:175-188`）。

### 1.2 跳到另一张地图：portal 对象 + 事件

- portal 的契约属性是 `targetMap / targetX / targetY / facingX / facingY`
  （`data/world-object-contract.json:23-31`）。
- 引擎**不做**「踩到就传送」。转场是项目侧的三步：
  1. 检测玩家所在格与某个 `portal` 对象重叠；
  2. 触发一条 `eve.rpgc.event`，它的 `trigger.kind = "portal_entered"`
     （`schema/eve.rpgc.event.json:14`）；
  3. 事件里的 `load_map` 步调用 `map.loadFromFileWithObjectContract` 换地图，按需
     `consume_object` 记下「来过了」这个事实（`03-event-editor.md` §3 步骤总表）。
- 地图边缘约定：portal 放在最外一圈可走格上，`targetX/targetY` 写目标地图的落地格；
  **双向成对**——A→B 与 B→A 各有一个 portal 对象，各自在自己的地图文档里。
- **反复换图有代价。** `Map::retireReplacedLayers` 对旧图层只做
  `clear()` + `setVisible(false)`，**不销毁 ECS 实体**
  （`src/modules/map/Map.cpp:27-35`，`TileLayer::release()` 是空的）。
  每成功加载一次地图就新注册一组图层实体，旧实体留在世界里。开放世界来回穿图会持续积累，
  所以**一张地图一个 `eve.Map()` 实例**（或自建图层池），而不是同一个实例反复 load。
- 等距地图**不要依赖 `publishCollision`**：它只支持正交层，等距/六角返回 0
  （`src/modules/map/Map.cpp:127`）。等距走行走 `Pathfinder` 的
  `blockGid` / `syncFromLayer` 那条路（见 `04-runtime-integration.md`）。

### 1.3 逐步开放：门写在 `eve.rpgc.world`，不写在内容里

关键原则：**「未开放」是一个条件，不是「内容不存在」。** 开放前后地图文档一字不改，
变的只是条件求值结果。否则同一个跳转点会演化出两份地图文档，真源分裂。

```json
{
  "schema": "eve.rpgc.world",
  "version": 1,
  "id": "world.main",
  "gates": [
    {
      "portal": "village-outskirts/gate-north",
      "open": { "kind": "variable", "name": "story.chapter", "compare": "gte", "value": 3 },
      "lockedMessage": "msg.gate.locked.north"
    },
    {
      "portal": "village-outskirts/gate-bamboo",
      "open": { "kind": "moment", "any": ["dawn", "night"] },
      "lockedMessage": "msg.gate.locked.bamboo"
    }
  ]
}
```

- 条件词表**复用** event 的那一套：`variable` / `switch` / `object_consumed` / `always`
  （`schema/eve.rpgc.event.json:42-49`），本设计只加一个 `moment`（当前时刻）。
  不新造第二套条件语法——两套语法一定会漂。
- 关闭的 portal 仍然留在对象层里：玩家看得见、撞得到，运行时拒绝转场并播 `lockedMessage`。
  这比「删掉对象」多出来的好处是，人和 AI 都能从文档读出「这个门存在，但还没开」。

### 1.4 地形图与时刻图

- **地形层**：`id: "terrain"`，`layer: 0`，恒可见，任何时刻都不改。
- **时刻层**：`id: "moment.<momentId>"`，`layer: 1..N`。同一时刻只启用一层，
  运行时用 `TileLayer::setVisible(bool)`（`src/modules/map/TileLayer.h:312-313`）切换；
  取层用 `Map::getLayer(index)` / `Map::getLayerCount()`（`src/modules/map/Map.h:108-110`）。
- 这一层是引擎原生的：地图可以有任意多个 tilelayer，可见性是运行时可开关的。
- 一个必须知道的落差：**运行时的 `TileLayer` 没有名字**
  （`src/modules/map/TileLayer.h:30-341` 里没有 name 字段），地图文档里的 `id` / `name`
  只活在文档里。读取器按 `layers[]` 的顺序逐个建层
  （`src/modules/map/TileConfig.cpp:1065-1105`），所以 **`layers[]` 的顺序就是
  `Map::getLayer(index)` 的 index**。项目要从地图文档（校验时反正已经读过一遍）
  推导「第几层是 `moment.night`」，不要指望运行时问图层名字。
- 校验门要加的三条（schema 表达不了，属于内容纪律）：
  1. 每张地图必须有 `terrain` 层，且 `layer == 0`；
  2. `moment.<id>` 的 `<id>` 必须在 `eve.rpgc.world.clock.moments` 里存在（跨文档引用门）；
  3. 同一张地图上任意两个 `moment.*` 层的 `layer` 不允许重复。

### 1.5 时刻图影响单位与事件

- **单位**：对象缓存是扁平的、不携带图层归属——`MapObject` 只有
  `name/type/x/y/width/height/gid/properties`（`src/modules/map/MapObject.h:13-26`），
  对象缓存本身是一个平铺的 `std::vector<MapObject>`（`src/modules/map/Map.h:211`），
  由 `src/modules/map/Map.h:50-51` 的注释「从 objectgroup 层刷新对象缓存」可知所有 objectgroup 的
  对象进的是**同一个**缓存。
  所以「哪些单位属于哪个时刻」**不能靠图层判断**，只能用对象属性：

  ```json
  {
    "name": "night-guard",
    "type": "npc",
    "x": 512, "y": 384,
    "properties": [
      { "name": "moment", "value": "night" },
      { "name": "dialogue", "value": "village.night-guard" },
      { "name": "speaker", "value": "巡夜人" }
    ]
  }
  ```

  对象契约里给 `npc` / `chest` 加一个**可选**的 `moment` 属性
  （`data/world-object-contract.json:9-21` 的 `properties` 列表），运行时用
  `Map::getObjectProperty(i, "moment", "")`（`src/modules/map/Map.h:163`）过滤即可。
- **「不在场」与「已消耗」是两件事**：`consume_object` 记的是「这个对象被拿走了」
  （`eve::rpg::WorldState::consumeObject`，`src/modules/rpg/WorldState.h:42`，
  读回用 `isObjectConsumed`，`src/modules/rpg/WorldState.h:34`），时刻切换只是「这次没实例化它」。
  用前者表达后者，会导致白天回来时 NPC 永久消失。这条必须写进项目侧的实例化代码注释里。
- 引擎**不会**把被消耗的对象从场景里摘掉：`consumeObject` 只写一个事实，
  渲染与交互时的跳过由项目负责（`examples/rpg-classic/main.nut` 就是
  「类型是 spawn 或 `isObjectConsumed(...)` 就 continue」这个形状）。
  `Map::setObjects` 只有 C++ 端（`src/modules/map/Map.h:192`），没有绑定到 Squirrel，
  所以运行时改对象集合只能走「逻辑过滤」，不能走「改地图」。
- **事件**：时刻相关的事件不要新造 trigger kind。`eve.rpgc.event` 的 trigger 已经是封闭集合
  （`portal_entered` / `map_entered` / `object_interacted` / `quest_completed` / `game_started`，
  `schema/eve.rpgc.event.json:14`）；时刻条件写成 `map_entered` + `branch` 上的 `moment` 条件。

### 1.6 时间：一个时钟，两个消费者

- 引擎有时钟：`daynight.setTimeOfDay / getTimeOfDay / isNight`
  （`src/modules/daynight/DayNight.h:53-61`）。它同时驱动 3D 太阳与天空；
  **2D 等距项目只用它的读数**，光照由时刻层与调色表达，不用它的 Light3D 那一套。
- 时刻分档来自 `eve.rpgc.world.clock.moments`，例如
  `{ "dawn": [5,7], "day": [7,17], "dusk": [17,19], "night": [19,5] }`。
  门条件与时刻层选择**调同一个「当前时刻」函数**——一个函数，两个消费者。
- 时钟**没有事件**：`DayNight` 的整套接口里没有 time-changed / hour-tick 回调
  （`src/modules/daynight/DayNight.h` 全量方法里没有任何事件 API），只能每帧轮询
  `getTimeOfDay()` / `isNight()`，由项目判断是否跨过了时刻分档。
- 也**没有世界历法**：引擎的 `Timer` 是帧时钟，没有「第几天 / 第几月」的推进。
  剧情要按天数走（比如「三日后开放山门」），天数必须项目自己维护成一个
  `GameState` 变量，并纳入 §1.8 的存档。

### 1.7 换风格：整层调色，还是换一套图集

两条路，按需要选，不要混着用：

| 做法 | 用什么 | 适用 |
|------|--------|------|
| 整层调色 | `TileLayer::setTint(r, g, b, a)`（`src/modules/map/TileLayer.h:315`） | 「夜晚版本」只是压暗/偏蓝；零新素材，立刻可用 |
| 换图集 | `TileLayer::setTileset(texture, firstGid, columns, ...)`（`src/modules/map/TileLayer.h:270`）+ 逐 GID 的 `setTileVisual`（`:285`） | 真正重画过的一套美术 |

- **换图集会把逐 GID 元数据清空**，这是这条路唯一的坑：`setTileset` 的实现里会清掉
  `visuals` / `animations` / `terrainRules` / `terrainFamilies` / `customData` / `atlases`
  （`src/modules/map/TileLayer.cpp:390-395`），也就是先前用 `setTileVisual` /
  `setTileMetadata` / `setTileNavigationProfile` 写进去的**视觉与导航画像全部丢失**。
  换肤之后必须按图集清单重新灌一遍 `walkable` / `cost` / `opaque` / 进出遮罩，
  否则寻路与视野会静默失真。这也是「整层调色优先」的另一个理由：`setTint` 不动元数据。
- 仓库里的 `docs/dev/dynamic-skin-palettes.md` 讲的是**骨骼蒙皮矩阵** palette，与贴图配色
  无关，不要引错。tile 侧唯一受支持的染色入口是**整层**的 `setTint`
  （`src/modules/map/TileLayer.h:315`，渲染时对全层每个 tile 生效）；
  逐 tile 自定义着色器没有受支持的入口。
- 引擎对图集的沉默点（和 `01-tilemap-editor.md` 里那份清单是同一批）：
  图片加载失败只是返回 `nullptr`（`src/modules/map/TileConfig.cpp:114-126`），
  GID 越出图集行列不校验（`src/modules/map/TileSystem.cpp:62-79`），
  纹理为空时画的是确定性 hash 调试色（`src/modules/map/TileSystem.cpp:45-52`）。
  所以「换肤后画面不对」在引擎侧永远是静默的——校验门是唯一的预警。
- map schema 里 `tilesets` 是 `maxItems: 1`（`schema/eve.rpgc.map.json:25`），
  所以「同一张地图两套图集」写不进地图文档；变体声明放在
  `eve.rpgc.world.styleVariants` 里，运行时按当前时刻选一套。
- **换图集的前提是两份图集同构**：同 `firstGid`、同列数、同
  `GID → region / pivot / footprint` 表。引擎不检查这件事
  （`01-tilemap-editor.md` 的「引擎不检查、工作流才检查」一节逐条列了引擎的沉默点），
  所以本设计要求新增一条**变体同构门**：变体图集与基准图集的 GID 表逐项比对，
  缺一块、错一块都报 error。GID 错位的表现是「夜晚某些格子变成另一块地」，
  人眼很难在几百块瓦片里发现，这条门是必须的。

### 1.8 存档：哪些事实必须活过重启

引擎有一个事务性存档边界 `RPGSaveSession`
（`src/modules/rpg/RPGSaveSession.h:46-71`）：它把 `GameState`、任务 `Tracker`、
玩家 actor 或 `Party`、背包与装备绑成一个 `rpg:save-session` JSON
（`snapshotJson` / `restoreSnapshotJson`，`:148-171`），并且**内容版本是契约的一部分**
（`setContentVersion`，`:81`；兼容声明 `allowCompatibleContentVersion`，`:96`）。

本设计要持久的事实按归属分三类：

| 事实 | 归属 | 引擎覆盖程度 |
|------|------|--------------|
| 剧情变量 / 开关（门条件用的 flag） | `GameState`（`setVariable` / `switchOn`） | 是 |
| 「某个地图对象被消耗过」 | `GameState` 的 `world.object:<mapId>` scope（`WorldState::consumeObject`，`src/modules/rpg/WorldState.h:42`） | 是 |
| 当前地图与坐标、已解锁的地图集合 | 项目的 `GameState` 变量 | 变量是引擎的，语义是项目的 |
| 武学品级 / 熟练度 / 心法装配 / 破绽值 | 项目的 `GameState` 变量 | 同上 |

- **不需要存**：当前时刻、时刻层可见性、NPC 在不在场。它们是时钟与地图文档的派生物，
  每次进入地图重新求值即可。存了反而会出现「存档里的时刻与时钟打架」。
- 一条硬约束：**已发布的 skill / trait / class id 不要改名。** 存档里存的是定义 id，
  `RPGSaveIdDomain` 明确列了 `Skill` / `Class` / `Trait`
  （`RPGSaveSession.h:28-37`）；改名必须注册 `addIdRenameMigration`（`:111`），
  否则老存档恢复时会被拒绝。这意味着品级变体 id（`skill.taiji-fist.p3`）
  一旦发出去就是**存档契约**的一部分——品级重编号要先想清楚。

---

## 2. 武功系统：武术、功法、品级、绝招

### 2.1 先把四个词定死

| 词 | 含义 | 承载 |
|----|------|------|
| 武术（外功） | 一次施放的招式：伤害 / 位移 / 连段 | `eve.rpgc.skill`（落到引擎 `SkillDefinition`） |
| 功法（内功） | 也是一次施放，但走增益 / 持续 / 换属性 | 同上 |
| 品级 | 一门武术或功法自己的成长段位（1..maxGrade） | `eve.rpgc.art`（本设计新增） |
| 心法 | 不给新招式，只给已有招式附加属性/效果 | `eve.rpgc.heart`（本设计新增，见 §4） |
| 绝招 | 达到某品级才进入可用集合的特殊招式 | `eve.rpgc.art` 的 `ultimates[]` + 独立 skill 文档 |

「武术」与「功法」在数据上是**同一类东西**（都是 skill），区别在默认的
`targetType` / `costs.attribute` / 是否带持续 effect；不要为它们建两套 schema。

### 2.2 引擎已有的那一半

- `SkillDefinition { id, cooldown(秒), castTime(秒), targetType(自由字符串), cost,
  grantedEffects[], tags[], castCondition, extra{} }`（`src/modules/rpg/Skill.h:25-39`）。
- 注册：`rpg.registerSkillsFromJson`（`src/modules/rpg/RPG.h:84`）；
  伤害登记：`rpg.registerSkillDamage(skillId, damageType, formula, element, critChance, hitChance)`
  （`src/modules/rpg/RPG.h:265-267`）。
- 施放流水线（冷却 / 消耗 / 读条 / 授予效果）由 `SkillSystem` 负责（`src/modules/rpg/SkillSystem.h:30-61`）；
  `castTime <= 0` 立即结算。
- **引擎不知道品级。** `SkillDefinition` 里没有任何等级/段位字段。最接近的原始能力是
  「职业按角色等级解锁技能」：`ClassLearnSkill{skillId, level}`（`src/modules/rpg/Class.h:18-21`），
  数据形如 `learnSkills:[{skillId, level}]`（`src/modules/rpg/Class.h:52-56`，样例
  `examples/rpg-classic/data/classes.json`）。它解决的是**角色等级**，
  不是**每门武功自己的品级**——两者不要互相冒充。
- **眩晕/沉默不是引擎内置的。** `src/modules/rpg/SkillSystem.h:5-8` 明确写着引擎不内置任何
  状态互斥概念，沉默/眩晕完全由游戏自定义的 tag/effect 表达；
  `SkillSystem::registerCastCondition` 是 C++ 回调（`docs/dev/RPG系统设计.md:53`），
  Squirrel 注册不了新条件。

### 2.3 品级模型

一份 `eve.rpgc.art` = 一门武学（含它的品级表）：

```json
{
  "schema": "eve.rpgc.art",
  "version": 1,
  "id": "art.taiji-fist",
  "title": "太极拳",
  "category": "martial",
  "element": "earth",
  "maxGrade": 5,
  "grades": [
    {
      "grade": 1,
      "title": "起势",
      "requirement": { "kind": "proficiency", "value": 0 },
      "skills": ["skill.taiji-fist.p1"],
      "modifiers": [{ "attribute": "defense", "op": "mulAdd", "value": 0.05 }]
    },
    {
      "grade": 3,
      "title": "云手",
      "requirement": { "kind": "proficiency", "value": 120 },
      "skills": ["skill.taiji-fist.p3"],
      "traits": ["trait.taiji-guard"]
    },
    {
      "grade": 5,
      "title": "如封似闭",
      "requirement": { "kind": "proficiency", "value": 400 },
      "skills": ["skill.taiji-fist.p5"],
      "ultimates": ["skill.taiji-seal"],
      "traits": ["trait.taiji-parry"]
    }
  ]
}
```

规则：

- `maxGrade` **由每门武学自己声明**（1..9），不是全局常量。用户要的「可以自由设定最大品级」
  就是这一条：品级上限是内容，不是引擎开关。
- `grades[].grade` 必须唯一、升序，且 ≤ `maxGrade`——沿用 skill 的 `presentation.levels[]`
  行约束模式（`lib/rpgc_skill.nut` 的语义门）。
- `skills` / `traits` / `ultimates` 是**累计可用集合**（该品级起可用）；
  `modifiers` 是**该品级自己的被动加成**。两种语义在字段上就分开，避免「到了 5 品反而丢了 1 品招式」。
- `grades[]` 是**成长**（玩法），`presentation.levels[]` 是**每一级的演出替换**
  （`04-runtime-integration.md` §2.3 明确它是替换不是追加）。
  两者不要互相兼任：一个管数值与解锁，一个管动画与特效。

### 2.4 运行时投影：品级编译成 skill id

引擎看不见品级，所以「当前品级」由项目**编译成具体注册过的 skill id**：

```text
玩家 art.taiji-fist 的品级 = 3
  可用招式 = union(grades[1..3].skills)      = { skill.taiji-fist.p1, skill.taiji-fist.p3 }
  绝招集合 = union(grades[1..3].ultimates)   = {}
  被动集合 = union(grades[1..3].traits)
```

- 每个品级变体是**独立的 skill 文档**（`skill.taiji-fist.p3`），有各自的
  `damage.formula` 与 `presentation.segments`。这样 `rpg.registerSkillDamage` 的 key 是确定的，
  运行期不需要改公式，也不需要「同一 id 换数值」这种会撕裂注册表的做法。
- 被动加成走 `Trait`：`rpg.registerTraitsFromJson`（`src/modules/rpg/RPG.h:255`）+ `rpg.applyTrait`
  （`src/modules/rpg/RPG.cpp:666-693`）。
- **绝招的可用性检查在项目侧。** 引擎唯一能拦「能不能放」的是 `castCondition`，
  而注册新条件需要 C++（`SkillSystem::registerCastCondition`）。所以
  「品级不够就不能放绝招」写在项目的指令校验里，真源是 `eve.rpgc.art.ultimates`。

### 2.5 品级解锁的四类东西分别落到哪里

| 解锁 | 承载 | 引擎 API |
|------|------|----------|
| 新招式 / 新的招式段 | 独立 skill 文档的 `presentation.segments` | `SpriteAnim`（`eve.Animation().newSpriteAnim()`） |
| 数值提升 | 各品级 skill 自己的 `damage.formula` | `rpg.registerSkillDamage`（`src/modules/rpg/RPG.h:265-267`） |
| 被动加成 | `Trait`（`paramRate` / `exParam` / `elementRate`） | `rpg.registerTraitsFromJson` + `applyTrait` |
| 附加效果 | `skill.effects[]` 引用的 `effect` 文档 | `rpg.registerEffectsFromJson`（`src/modules/rpg/RPG.h:79`） |
| 绝招 | 独立 skill + 专属 clip + 项目侧可用性校验 | 上述通道 |

### 2.6 `art` 这个 kind 要加的校验

- `grades[].grade` 升序、唯一、≤ `maxGrade`，`maxGrade ∈ [1,9]`；
- `skills` / `ultimates` 引用的 skill 必须存在（引用门，
  `RpgcValidate.validateReferences` 的既有机制）；
- `traits` 引用的 trait id 必须在项目的 trait 文档集里存在——
  **引擎的 `registerTraitsFromJson` 遇到坏条目不报错**，所以这条只能靠工作流拦；
- `skills[]` 里的每份 skill 必须反向声明同一个 `art` id（防串门，防复制粘贴改漏一行）；
- 绝招必须带 `ultimate` tag，否则「绝招」就只是普通技能改了个名。
- 新 kind 的纪律：`workflow.json` 里同时给 `directory` / `schema` / `module`，
  并实现 `semanticDiagnostics` / `references` / `extraDiagnostics` 三个钩子——
  否则语义门被静默跳过（`README.md` 的 kind 表一节）。

---

## 3. 五行相生相克与弱点击破

### 3.1 规则表（真源：`eve.rpgc.rules`）

```json
{
  "schema": "eve.rpgc.rules",
  "version": 1,
  "id": "rules.wuxing",
  "elements": ["metal", "wood", "water", "fire", "earth"],
  "generates": { "wood": "fire", "fire": "earth", "earth": "metal", "metal": "water", "water": "wood" },
  "overcomes": { "wood": "earth", "earth": "water", "water": "fire", "fire": "metal", "metal": "wood" },
  "break": { "max": 100, "onOvercome": 30, "onWeakElement": 20, "onWeakStyle": 25, "regenPerRound": 10 },
  "clock": { "turnSeconds": 6.0 }
}
```

- 相生：木生火、火生土、土生金、金生水、水生木；
  相克：木克土、土克水、水克火、火克金、金克木。
- 这两张表**只写在文档里**：战斗结算、校验门、组合技共鸣判定都读它。
  运行期不允许再抄一份硬编码的对照表。

### 3.2 引擎的元素通道：直接使用五行的元素名

- 伤害的 `element` 在引擎里是**自由字符串**（`src/modules/rpg/BattleSystem.h:26-31`），
  结算时按 `TraitSystem::getElementRate(target, element)` 取倍率
  （`src/modules/rpg/BattleSystem.cpp:237-240`）。
- 倍率语义：`elementRate` 取**乘积**，源码注释给出的两个锚点是
  「1 = 无修正，0.5 = 减半」（`src/modules/rpg/TraitSystem.h:49-50`）；
  大于 1 就是弱点，0 在数学上会把伤害乘成 0——但源码只对**状态**提供了
  `isStateResist` 这种显式的免疫判定（`TraitSystem.h:53-54`），
  元素免疫请用「倍率 = 0」表达，不要另造一个免疫标记。
- 所以五行**不需要**「翻译成引擎元素」：引擎元素名就是五行名
  （`metal` / `wood` / `water` / `fire` / `earth`）。
  当前工作流的 skill schema 把 `damage.element` 限死在
  `none/fire/ice/thunder/earth/wind/light/dark`（`schema/eve.rpgc.skill.json:24`）——
  这正是本设计要改的一处：把 `metal` / `wood` / `water` 加进 enum（`earth` / `fire` 已在）。
  这是 schema 变更，必须同时升格校验门，不能靠约定绕过。
- **相克为什么不能写进伤害公式**：引擎的公式 DSL 只支持数字、`a.<attr>`、`b.<attr>` 与
  `+ - * / ( )`（`src/modules/rpg/BattleSystem.cpp:55-196` 的 `parseFormula`），没有表查询。
  相克只能通过「目标身上的 `elementRate`」表达，而这恰好是引擎支持的**唯一**倍率通道。

### 3.3 双弱点

| 弱点 | 载体 | 引擎支持程度 |
|------|------|--------------|
| 属性弱点（惧火、畏金） | 目标 actor 的 `Trait{kind:"elementRate", target:"fire", value:1.5}` | 原生：数据驱动，结算自动乘 |
| 武功弱点（怕剑法、惧掌力） | 按 `skill.tags[]`（`schema/eve.rpgc.skill.json:21`）查表 | **没有「按 tag 的倍率」通道** |

- 引擎的 Trait 只有 `elementRate` / `stateRate` 两类倍率
  （`src/modules/rpg/Trait.h:19-27` 的 kind 表）；`stateRate` 是**状态命中**倍率，
  不是「招式流派」倍率。
- 所以**武功弱点必须项目侧查表**：结算前用 `skill.tags ∩ weakStyles` 决定是否加权，
  加权落地成「追加一个 effect」或「改 actor 属性」，不能指望引擎自动乘。
- 统一形状：弱点表写在 `eve.rpgc.rules` 里（`weakStyles`），怪物侧只声明自己怕哪些 tag。
  这样「哪些怪怕剑法」是一张表，不是散落在各处的 if。

### 3.4 击破链：从命中弱点到两回合眩晕

1. 命中弱点 → 破绽值下降（`break`，项目属性，0..100）；
2. 破绽降到 0 之前，每段给出可见反馈：`effect.exposed` 用 `modifiers[]` 加受伤 / 降防御；
3. 完全击破（破绽 = 0）→ 施加 `effect.stun` + 破防，**从下一回合起算，持续 2 回合**；
4. 每回合结束破绽恢复 `regenPerRound`（不是一次性用光）。

- **时间单位是这里最容易出错的一点。** 引擎的状态时长是**秒**，不是回合：
  `EffectDefinition.duration` 的单位是秒（`src/modules/rpg/Effect.h:32-59`），
  运行时由 `StatusSystem::update(dt)` 递减（`src/modules/rpg/StatusSystem.h:107`）；
  `remaining = -1` 表示无限（`src/modules/rpg/StatusTypes.h:31`）。
  所以「2 回合眩晕」必须写成 `duration = 2 × rules.clock.turnSeconds`。
  两个数字必须一致——这是校验门要盯的**推导一致性检查**：
  `turnSeconds` 改了而 effect 的 `duration` 没跟着变，就是 bug。
- **眩晕必须项目侧实现。** 引擎不内置眩晕/沉默（`src/modules/rpg/SkillSystem.h:5-8`，
  `docs/dev/RPG系统设计.md:53`）：项目的回合调度在轮到被眩晕单位时跳过它，
  并在提交指令时按 tag 拒绝（`skill.tags` 含 `stun` 即禁技能）。
- 破防/削弱这类数值走 `Effect` 的 `modifiers[]`（`add` / `mul` / `set` + `priority`，
  `schema/eve.rpgc.effect.json:18-32`），这部分是引擎原生的，不需要项目重写。

### 3.5 一次攻击的结算顺序（项目侧）

```text
1. 选目标      引擎只解析 self / allySingle / enemySingle，AOE 是项目侧
                （src/modules/rpg/Battle.cpp:226-238、src/modules/rpg/Battle.cpp:266-289）
2. 相克判定    rules.overcomes[attacker.element] == target.baseElement ?
3. 弱点判定    skill.element ∈ target.weakElements ? skill.tags ∩ target.weakStyles ?
4. 破绽结算    按 rules.break 扣减；跨过 0 则挂 effect.stun + effect.exposed
5. 交给引擎    Battle.setActionChecked → resolveHit 自己算 elementRate 与暴击
```

第 5 步有一条硬约束：**相克倍率不要和 `elementRate` 重复计一次。**
本设计规定 `elementRate` 是唯一结算倍率（§3.2），相克只影响第 4 步的破绽，
不额外乘伤害——否则同一件事被算两遍，数值会漂。

---

## 4. 心法

### 4.1 心法做什么、不做什么

- 做：给已有招式**附加**属性（换或加元素）、加被动数值（暴击 / 命中 / 闪避 / 攻击速度）、
  改消耗与冷却、命中后追加状态、改五行归属。
- 不做：不给新招式（那是武术/功法），不新增品级（心法自己有品级也走 §2 的模型，
  心法文档只描述「附加了什么」）。

### 4.2 承载：Trait + Effect

| 心法效果 | 承载 | API |
|----------|------|-----|
| 招式附带元素 | `Trait{kind:"attackElement", target:"fire"}` | `src/modules/rpg/Trait.h:20-21`；`rpg.registerTraitsFromJson`（`src/modules/rpg/RPG.h:255`） |
| 数值加成 | `Trait{kind:"paramRate"}` / `{kind:"exParam"}` | 同上 |
| 自身抗性 | `Trait{kind:"elementRate"}` | 同上 |
| 持续增益 | `EffectDefinition.modifiers[]` + `stackPolicy` + `duration` | `rpg.registerEffectsFromJson`（`src/modules/rpg/RPG.h:79`） |
| 命中后追加状态 | **项目侧钩子**：结算后 `applyEffect` | 引擎没有「effect 触发另一个 effect」的通道 |

- `EffectDefinition` 有一个 `extra` 字符串袋（`schema/eve.rpgc.effect.json:33`），
  但**定义侧的 `extra` 在 Squirrel 里读不到**：`RPG.cpp` 没有绑定
  `EffectRegistry::find` / `EffectDefinition.extra`，技能、特征、职业的 `extra` 同样没有绑定。
  脚本能读写的只有**状态实例**上的 props：`actor.getStatusProp` / `setStatusProp`
  （`src/modules/rpg/RPG.cpp:599-600`）。
- 结论：「把心法数据藏在 `extra` 里让运行时读取」这条路**走不通**。
  心法数据要么进项目的脚本数据表，要么由 C++ 消费。设计上选前者：
  `eve.rpgc.heart` 是唯一真源，运行时把需要的东西编译进脚本表。

### 4.3 心法文档与装配规则

```json
{
  "schema": "eve.rpgc.heart",
  "version": 1,
  "id": "heart.ice-mind",
  "title": "玄冰心法",
  "slots": { "count": 1, "exclusiveGroup": "heart.ice" },
  "grants": {
    "traits": ["trait.ice-attack", "trait.ice-affinity"],
    "effects": ["effect.ice-aura"],
    "elementOverride": "water",
    "costScale": { "attribute": "mana", "mul": 0.9 },
    "onHit": [{ "effectId": "effect.chill", "chance": 0.25 }]
  },
  "requires": { "artId": "art.taiji-fist", "minGrade": 3 }
}
```

- `slots` 决定同时能装几门、哪些互斥；`requires` 把心法与特定武学的品级绑定
  （「只有太极拳三品以上才吃这门口诀」）。
- `elementOverride` 与 `Trait.attackElement` 的关系要写死：
  - `elementOverride` 是**替换**招式元素；
  - `attackElement` 是**追加**攻击元素（引擎侧是标签列表，
    `src/modules/rpg/RPGActor.h:245` 的 `getAttackElements`）。
  两者语义不同，文档里二选一，不允许同一门心法同时声明。

### 4.4 心法要加的校验

- `grants.traits` / `grants.effects` / `onHit[].effectId` 必须存在（引用门）；
- `requires.artId` 必须存在，且 `minGrade ≤ art.maxGrade`（跨文档求值）；
- `elementOverride` 必须是 `eve.rpgc.rules.elements` 里的值；
- 同一 `exclusiveGroup` 内的心法不能在文档层声明互相包含的 `requires`——
  「实际装备冲突」是运行时状态，校验门只能保证文档自洽。

---

## 5. 组合技

### 5.1 规则（本设计）

- **成员**：2..4 名同队单位，各自贡献一个 skill。
- **条件**：都在场、未被眩晕/沉默、五行共鸣（相邻成员的招式元素满足相生链，
  或至少两者相克同一目标）、资源足够（内力/怒气）。
- **窗口**：同一回合内，参与者按顺序各消耗一次行动。引擎没有「多人一次行动」的概念，
  组合技是**多次行动的组合**，不是一次原子行动。
- **结算**：每个成员各结算一次（各自的命中 / 暴击 / 元素倍率），最后追加一段「合击」
  （增加破绽、无视部分防御）。
- **中断**：任一成员被打断或眩晕，组合技取消；已消耗的行动不返还。

### 5.2 引擎现状

- **没有组合技概念**：`src/modules/rpg/**` 里没有 combo / joint / coop；
  多目标也只解析 `self` / `allySingle` / `enemySingle`（`src/modules/rpg/Battle.cpp:226-238`、
  `src/modules/rpg/Battle.cpp:266-289`），
  AOE 是项目侧。
- 有序多方行动的引擎原语：`Party`（稳定 id ↔ actor 链接，
  `src/modules/rpg/Party.h:22-97`）与 `tactics` 模块的行动 / 反应窗口
  （`TurnPolicyKind{SideAlternating, Initiative}`，`src/modules/tactics/TacticsTypes.h:57-58`；
  `reactionPoints` 等资源规格，`:75-84`；反应栈
  `src/modules/tactics/TacticsBattle.h:87-93` 的 `openReaction` / `acceptReaction`）。
  连携窗口用反应窗口表达，是最贴近引擎的路径；数值结算仍交给 `rpg` 的 `Battle`。
- **没有连击计时器**：`Battle::executeNextAction` 一次只推进一个行动
  （`src/modules/rpg/Battle.cpp:212-264`）。组合技的「窗口」由项目在自己的回合调度里维护。

### 5.3 组合技文档

```json
{
  "schema": "eve.rpgc.combo",
  "version": 1,
  "id": "combo.twin-sword",
  "title": "双剑合璧",
  "members": { "min": 2, "max": 2, "order": "declared" },
  "condition": {
    "elements": { "kind": "generates", "chain": ["metal", "water"] },
    "vitals": [{ "attribute": "mana", "min": 30, "perMember": true }]
  },
  "stages": [
    { "actor": 0, "skill": "skill.twin-sword.left" },
    { "actor": 1, "skill": "skill.twin-sword.right" }
  ],
  "finish": {
    "skill": "combo.twin-sword.cross",
    "anim": { "anim": "fx-twin-sword", "clip": "cross" },
    "breakBonus": 40
  }
}
```

- `condition.elements` 用 §3.1 的 `generates` / `overcomes` 表求值——
  **组合技的五行规则和弱点击破是同一张表**，不复制。
- `stages[]` 是有序列表，与 event 的步骤列表同构；每段仍是一个普通 skill，
  所以表现层可以复用同一套 `presentation.segments` → `SpriteAnim` 的驱动方式。

### 5.4 表现：多角色动画必须项目侧串行

多段动画没有引擎级编排：`SpriteAnim` 只持有一个 next clip 与一个播放头
（`02-skill-editor.md` §6）。所以「甲出招 → 乙接招 → 合击」是项目侧把三段串行驱动，
每段完成后启动下一段；镜头用 `Camera2D::setPosition` / `setZoom`
（`03-event-editor.md` §3 步骤总表）。

### 5.5 组合技要加的校验

- `stages[].skill` / `finish.skill` 必须存在，且都反向引用同一组合技 id（防串门）；
- `members.min/max` 与 `stages.len()` 必须一致；
- `condition.elements.chain` 必须能在 `rules` 的相生/相克表上走通
  （跨文档求值，落在模块额外检查层，与事件门的 clip 存在性检查同一层，
  `lib/rpgc_event.nut:257-295`）；
- `finish.anim` / `finish.anim.clip` 必须存在——复用事件门已有的检查形状。

---

## 6. 物品与装备

物品是这几个系统里唯一一个**引擎已经提供了一半数据结构**的：`inventory` 模块有
`ItemDefinition` 注册表、`Bag`、`EquipmentSet`，`rpg` 模块有物品→属性加成的注册表。
所以这一层的工作主要是**把引擎的沉默点交给门**，而不是设计新结构。

三条与战斗半边咬合的规则，写在这里，细节在
[`08-items-and-equipment.md`](08-items-and-equipment.md)：

1. **装备槽位词表在 `rules` 里**（`rules.equipmentSlots`）。引擎自己把
   `ItemDefinition.equipSlot` 定义成「建议槽名」（`src/modules/inventory/ItemTypes.h:21`），
   真正决定能不能穿的是运行时 `EquipmentSet::defineSlot` 建的槽位——两者之间
   没有任何东西对账，所以词表必须有一个权威，物品只写引用。
2. **秘籍教的东西必须自洽**：`teaches` 同时点名 art 与 skill 时，那个 skill 必须
   确实属于那门 art。这条由 `itemCrossDiagnostics` 检查，是 `artCrossDiagnostics`
   那套「skill 必须反向声明 art」的正向补充。
3. **装备条件不能超过那门武学的上限**：`requires.minGrade ≤ art.maxGrade`，
   否则这件装备永远无法装备，而引擎没有品级概念可以察觉。

一条必须记住的引擎事实：**装备加成里 `op` 拼错是静默失效**。它经过
`AttributeSystem::addModifier`（`src/modules/rpg/AttributeSystem.cpp:58-74`，
不认识的 op 直接 `return {}`），而调用它的
`EquipmentSystem::syncEquipModifiers` 把返回值丢掉了
（`src/modules/rpg/EquipmentSystem.cpp:73`）。schema 因此把 `op` 收紧成
`parseAttributeOperation` 的合法拼写集合（`src/modules/attributes/AttributeSet.cpp:30-53`）。

## 7. 真源与投影总表

| 系统 | 文档 kind | schema | 主要引擎 API | 适配器职责 |
|------|-----------|--------|--------------|------------|
| 世界与门 | `eve.rpgc.world` | `eve.rpgc.world` | `daynight.getTimeOfDay/isNight`；`TileLayer.setVisible/setTint/setTileset` | 求值门条件、选时刻层、选风格变体 |
| 时刻单位 | `eve.rpgc.map` 的对象属性 | `eve.rpgc.map` | `Map::getObjectProperty`；`findObjectAt` | 按 `moment` 过滤实例化 |
| 武学与品级 | `eve.rpgc.art` | `eve.rpgc.art` | `registerSkillsFromJson` / `registerSkillDamage` / `applyTrait` | 编译当前品级为可用 skill 集 |
| 招式与演出 | `eve.rpgc.skill` / `eve.rpgc.anim` / `eve.rpgc.effect` | 既有三份 | `SkillSystem` / `SpriteAnim` / `StatusSystem` | 演出驱动与轮询 cast 事件 |
| 五行与击破 | `eve.rpgc.rules` | `eve.rpgc.rules` | `TraitSystem::getElementRate`（结算内） | 破绽值、相克判定、眩晕挂载 |
| 心法 | `eve.rpgc.heart` | `eve.rpgc.heart` | `registerTraitsFromJson` / `registerEffectsFromJson` / `applyEffect` | 装配规则、命中后追加效果 |
| 组合技 | `eve.rpgc.combo` | `eve.rpgc.combo` | `Party` / `tactics` 反应窗口 / `Battle` | 成员判定、多段串行、合击 |
| 物品与装备 | `eve.rpgc.item` | `eve.rpgc.item` | `eve.Inventory().registerItemsFromJson` / `rpg.registerItemStatsFromJson` / `rpg.syncEquipModifiers` / `rpg.applyEffect` | 使用效果、秘籍教学、槽位词表对账 |
| 敌人与遭遇 | `eve.rpgc.enemy` / `eve.rpgc.encounter` | 本设计新增两份 | `rpg.replaceEncountersFromJson` / `rpg.newEncounterMemberActor`（`src/modules/rpg/RPG.cpp:1194-1212`） | 投影（`tools/build_encounters.py`）、遭遇触发、敌方 AI、掉落结算 |
| 我方名单 | `eve.rpgc.party` | 本设计新增一份 | **无**：`Party` 是运行期容器，不带内容与加载器 | 名单人数对 `maxBattleAllySlots` 的对账；`art` + `grade` 编译成招式表 |
| 战斗结算 | `lib/rpgc_battle.nut` | —（不是 kind） | 复述 `BattleSystem::parseFormula` / `resolveHit` / `computeAttributeValue`；本项目**不绑定** `rpg` | 五行击破、状态时长、回合序、敌方 AI、胜负与结算 |
| 战斗场景 | `eve.rpgc.battle` | 本设计新增一份 | **无**：引擎没有战场 / 阵型 / 阵位类型，也没有投影产物 | 编队成员→阵位映射、等比缩放；背景取自 `encounter.map` |

敌人与遭遇的完整设计见 [`09-enemies-and-encounters.md`](09-enemies-and-encounters.md)：
引擎的 `EncounterCatalogue` 只接受一个**内联了数值的裸数组**，而且是**原子**替换，
所以工作流把它拆成「敌人原型（数值唯一真源）+ 遭遇编队（引用 + 数量）」两份文档，
再由投影工具合成引擎读得懂的形态。

---

## 8. 落地顺序与门禁

1. `eve.rpgc.rules`（五行 + 回合秒数 + 破绽阈值 + 装备槽位词表）——其余系统全部依赖它；
2. `eve.rpgc.world`（时刻分档 + 门表 + 风格变体）+ map 的 `moment` 对象属性；
3. `eve.rpgc.art` 与 `eve.rpgc.heart`（战斗成长）；
4. `eve.rpgc.combo`（需要前三者都在）；
5. `eve.rpgc.item`（引用 effect / art / skill，所以排最后）；
6. `eve.rpgc.enemy` + `eve.rpgc.encounter`（敌人引用 skill / map / anim / item，
   所以排在物品之后；投影产物 `data/encounters.engine.json` 由 `tools/build_encounters.py`
   生成，`--check` 保证它不漂）；
7. `eve.rpgc.battle`（引用 encounter，所以排在遭遇之后；**没有投影产物**——
   引擎没有对应类型，文档本身就是真源）。

每个 kind 都按同一套纪律落地：

```text
schema/  →  语义门（module.semanticDiagnostics）
         →  引用门（references）
         →  模块额外检查（extraDiagnostics）
         →  编辑器抽屉（editors/<id>.editor.json + .vm.nut）
         →  文档（docs/0N-*.md）
```

验收命令：

```bash
python tools/rpgc.py validate     # 全部内容文档过六层门
python tools/rpgc.py selftest     # 启动门 + 编辑器命令 + 暂存/导出往返
```

新增 kind 后要同步三处：`workflow.json` 的 `kinds`、`README.md` 的 kind 表、
本文件的 §7 总表。三处不同步时，`moduleFor` 对不上模块名会给出 `validate.unknown-module`
并让门失败（`lib/rpgc_validate.nut:227-244`）——它以前是**静默跳过**
语义门与引用门，那是整条链上最危险的一个静默点，现在改成 fail closed。

另外，README 的目录树里要补一行本文件（`docs/06-game-design.md`），
新增一类内容时同样要补 `docs/08-items-and-equipment.md` 那种对应文档，
否则它就成了没人找得到的孤儿文档。

---

## 9. 明确不做的事

- **不把相克倍率写进伤害公式**：公式 DSL 没有表查询（`src/modules/rpg/BattleSystem.cpp:55-196`），
  相克只能走 `elementRate` 或不走。
- **不在 `extra` 里藏运行时数据**：技能/效果/特征/职业定义侧的 `extra` 在 Squirrel 里读不到。
- **不用「删对象」表达未开放**：门是条件，不是内容差异。
- **不为时刻单独复制一份地图文档**：时刻是同一份地图文档里的额外图层。
- **不假装引擎有眩晕、组合技、AOE**：这三样都是项目侧实现，本文标注的边界就是最终边界。

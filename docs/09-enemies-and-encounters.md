# 09 · 敌人与遭遇

> 本文说明这一轮新增的两个 kind（`enemy` / `encounter`）：引擎 `EncounterCatalogue`
> 提供了哪一半、文档承载哪一半、投影工具如何把两者接起来，以及 22 个敌人原型的数值与
> 素材来源。
>
> 三条约定沿用 [`06-game-design.md`](06-game-design.md)：
>
> 1. **真源只有一份。** 一个敌人的攻击力只写在它的 `content/enemies/*.json` 里；
>    遭遇只说「哪个敌人、几个」。投影是纯函数，不是第二份数据。
> 2. **引擎没有的概念不塞进引擎。** `sprite` / `drops` / `ai` / `habitat` / `lore`
>    引擎一个字段都没有，它们就是项目侧的，门只保证它们自洽。
> 3. **新增一类内容 = 新增一个 kind。** 两个 kind 都在
>    `workflow.json` 里同时给出 `directory` / `schema` / `module`。

## 0. 一句话

引擎有一个**严格、原子**的遭遇目录：它读一个 JSON **数组**，每个成员的数值**内联**在
成员项里。工作流的形状恰好相反——一个敌人一份文档，数值只有一份。`tools/build_encounters.py`
是这两者之间的连接：读 `content/enemies/` + `content/encounters/`，写出
`data/encounters.engine.json`，一个**裸数组**，就是引擎 `JSON::parse` 会拿到的东西。

遭遇还有一个下游：**每场遭遇必须被恰好一块战场承接**（`eve.rpgc.battle`），
那块战场声明的敌方阵位数必须装得下这场的出场人数。这条由
`RpgcSystems.battleCrossDiagnostics` 强制，见
[`10-battle-scene.md`](10-battle-scene.md)。遭遇本身仍然只管「打谁、几个」。

## 1. 引擎已有的那一半：`EncounterCatalogue`

### 1.1 它拒绝什么

`EncounterCatalogue::replaceFromJsonStrict`（`src/modules/rpg/EncounterCatalogue.cpp:63-176`）
比 `inventory` 与 `skill` 的加载器都严——**未知字段直接报错**（`:76-78` 顶层、
`:125-127` 成员级），而不是像 `registerItemsFromJson` 那样静默丢掉。逐条如下：

| 约束 | 位置 | 越界时 |
|---|---|---|
| 根必须是**非空数组**，不是对象 | `:68-69` | 整体失败 |
| `id` 非空、≤256 字节、无控制字符 | `:81-82` | 整体失败 |
| `id` 不得重复 | `:83` | 整体失败 |
| `displayName` 非空、≤512 字节 | `:84-86` | 整体失败 |
| `members` 长度 1..32 | `:88-90` | 整体失败 |
| `xpReward` **严格 > 0** | `:94`（`strictMinimum=true`） | 整体失败 |
| `xpGrowth` ≥ 1.0 | `:94` | 整体失败 |
| `goldReward` ≥ 0 | `:94-95` | 整体失败 |
| `requiredQuestId` 必须是**已注册**的任务 | `:102-104` | 整体失败 |
| `notifyTopic` / `notifyTarget` / `defeatCounterId` / `levelPointAttributeId` 都非空 | `:105-109` | 整体失败 |
| `notifyAmount` / `defeatCounterAmount` 必须 > 0；`pointsPerLevel` ≥ 0 | `:113-115` | 整体失败 |
| 成员 `id` 非空且**在本次遭遇内唯一** | `:135-138` | 整体失败 |
| 成员 `displayName` 非空、≤512 字节 | `:139-142` | 整体失败 |
| 成员 `skillId` 必须是**已注册**的技能 | `:143-146` | 整体失败 |
| 成员 `maxHp` **严格 > 0**；`attack`/`defense`/`speed` ≥ 0 且有限 | `:147-150` | 整体失败 |

**「整体失败」是这张表的重点。** `replaceFromJsonStrict` 先在局部 `proposed` 表里
建完整个目录，最后一行才 `definitions() = std::move(proposed)`（`:174`）。所以**一条
坏遭遇会让全部遭遇一起消失**，而且是静默的——只有返回值告诉你。这就是它必须是一个
受校验 kind、而不是一段手写 JSON 的原因。

### 1.2 它创建什么

一个成员定义会被实例化成一个 ECS 拥有的 `RPGActor`：四项基础属性
（`attack` / `defense` / `hp` / `speed`）、当前 `hp` 设为满、`learnSkill(skillId)`
（`EncounterCatalogue.cpp:195-210`）。整场遭遇用同一个定义创建多名成员，
`createMemberActor(id, index)` 取第 index 个。

脚本侧入口（`src/modules/rpg/RPG.cpp:1194-1212`）：

```squirrel
local result = rpg.replaceEncountersFromJson(text);   // RPG.cpp:1194，原子替换
rpg.hasEncounter("encounter.luoyang-market");          // RPG.cpp:1205
local n = rpg.getEncounterMemberCount(id);             // RPG.cpp:1206
local actor = rpg.newEncounterMemberActor(id, index);  // RPG.cpp:1208
```

### 1.3 引擎不做的

- **不读文档、不读目录。** 它只要那一个字符串。文件放哪、怎么切分，都是项目的事。
- **不解析 `hero` 之外的任何精灵。** 成员定义里没有动画字段，敌人的样子完全项目侧。
- **不检查 `displayName` 与 `id` 的关系。** 成员 `id` 只是唯一性凭据，不是内容 id。

## 2. 两个新 kind

### 2.1 `enemy` —— 数值的唯一真源

`content/enemies/enemy.*.json`。字段分两半：

| 半段 | 字段 | 去向 |
|---|---|---|
| 引擎半段 | `displayName`、`combat.{attack,defense,maxHp,speed}`、`skillId` | 被投影工具**内联**进成员项 |
| 项目侧半段 | `element`、`weakElements`、`weakStyles`、`breakMax`、`sprite`、`drops`、`ai`、`habitat`、`lore` | 运行时/项目适配器读，引擎不知道它们存在 |

`element` 与 `weakElements` / `weakStyles` 在 schema 里是**自由字符串**，不是 enum。
理由和 §3.2 一样：五行表与弱点流派表写在 `eve.rpgc.rules` 里，在这里再列一遍就是
第二个权威。它们由跨文档门解析（§4），拼错会被报出来，不会静默。

两个引擎的**严格下限**（`maxHp > 0`、`xpReward > 0`）只能在语义门里查：
Eve Schema v1 的关键字集合是 `type/enum/minimum/maximum/minLength/maxLength/`
`minItems/maxItems/elementType/items/fields/additionalProperties/ref/...`
（`src/modules/schema/SchemaRegistry.cpp:175-195`），**没有 `exclusiveMinimum`**。

### 2.2 `encounter` —— 编队与结算

`content/encounters/encounter.*.json`。成员写成 `{enemy, count}`，**不重抄数值**：

```json
{
  "schema": "eve.rpgc.encounter",
  "version": 1,
  "id": "encounter.luoyang-market",
  "displayName": "洛阳南市·看场子的",
  "map": "luoyang",
  "members": [{ "enemy": "enemy.market-thug", "count": 2 }],
  "xpReward": 40, "xpGrowth": 1.2, "goldReward": 18,
  "quest": {
    "requiredQuestId": "quest.bounty", "notifyTopic": "kill",
    "notifyTarget": "thug", "notifyAmount": 1,
    "defeatCounterId": "kills", "defeatCounterAmount": 1,
    "levelPointAttributeId": "statPoints", "pointsPerLevel": 3
  }
}
```

`map` 与 `quest` 是**项目侧**字段（引擎没有）：`map` 让门能核对 `habitat`（§4），
`quest` 集中承载引擎那八个结算字段，投影时摊平。

## 3. 投影：`tools/build_encounters.py`

```bash
cd .  # repository root
python tools/build_encounters.py            # 写 data/encounters.engine.json
python tools/build_encounters.py --check    # 只比对，不写盘
```

它做三件事：按敌人 id 取数值**内联**；按 `count` 展开成员并把 id 生成为
`<敌人名>.<序号>`（如 `river-pirate.0`、`river-pirate.1`）——成员 id 只用于引擎
内部唯一性，用敌人名派生是为了让日志能读出是谁；把 `quest` 摊平到顶层。

输出是**裸数组**，没有包装对象，因为引擎 `JSON::parse` 拿到的就是它。这是**生成物**：
改 `content/enemies/` 与 `content/encounters/`，然后重跑。

`--check` 逐字节重算比对，所以「改了文档忘了重跑」是一次构建失败，而不是一次静默漂移。
这也是 `data/encounters.engine.json` **进版本库**、而 `content/tilesets/*.baked.json`
进 `.gitignore` 的原因：后者是同目录内容的格式迁移，前者是这批内容**唯一**能喂给引擎的
形态，把它放进 diff 才有可能在评审里发现「某个怪的攻击力从 12 变成 120」。

投影在写盘前自查了三条引擎约束（成员 id 唯一、成员总数 ≤32、根非空），所以它单独
运行也安全；上游 `RpgcSystems.encounterDiagnostics` 是同一批约束的提前版本。

## 4. 门抓什么

`enemy` / `encounter` 的语义门在 `lib/rpgc_systems.nut`，跨文档门在同一个模块的
`enemyCrossDiagnostics` / `encounterCrossDiagnostics`（由 `extraDiagnostics` 按模块
去重调用一次）。

**语义门**（schema 表达不了的）：

- 敌人：`combat.maxHp > 0`（引擎严格下限）；`displayName` 非空且 ≤512 字节；
  `skills` 必须包含 `skillId`（引擎只看得见 `skillId`，轮换里没有它就是自相矛盾）；
  `ai.opener` 必须在 `skills` 里；掉落不得重复同一 `itemId`、`max ≥ min`。
- 遭遇：`xpReward > 0`、`xpGrowth ≥ 1`；同一敌人不得出现在两条 `members` 里
  （投影的成员 id 由敌人 id 派生，重复会在引擎里撞 id）；`count` 之和 ≤32
  （schema 的 `maxItems: 32` 限的是**条目数**，限不住投影后的成员数）；
  五个结算 id 非空。

**跨文档门**：

- 敌人的 `element` / `weakElements` 必须落在 `rules.elements` 里，`weakStyles`
  必须落在 `rules.weakStyles` 里。**这条最要紧**：引擎按字符串查
  `TraitSystem::getElementRate`，拼错不是「倍率不对」，而是**根本没有倍率**——
  一个本该惧火的怪会变成打不动的怪，而没有任何一层报错。
- 敌人不得把自身 `element` 列进 `weakElements`。
- `breakMax ≤ rules.break.max`（设计把破绽定义成 0..100，见 06 §3.4）。
- `sprite` 的 `{anim, clip}` 必须命中真实剪辑（复用 `clipDiagnostics`）。
- **遭遇的 `map` 必须在该场每个敌人的 `habitat` 里。** `habitat`（这个怪出没在哪些图）
  与 `map`（这场遭遇放在哪张图）是对同一件事的两句陈述；门把它们逼到同一个答案，
  修法是在敌人文档里加一个字符串。没写 `habitat` 的敌人退出这条检查——「到处都可能
  遇到」用「列出所有图」表达，而不是用省略表达。

### 一条刻意的 warning

`systems.encounter-quest-unregistered` 是**汇总** warning，列出全部遭遇要求注册的
`requiredQuestId`。为什么不报 error：引擎要求 `requiredQuestId` 指向**已注册**的任务
（`:102-104`），而注册发生在运行期；本工作流不建模 quest，门**无法**解析它。报 error
等于对一个门职权之外的事实拒绝放行；不报又等于把一个「会让整个遭遇目录消失」的前置
条件藏起来。所以它是一条可见、可执行、不阻断的 warning，一次列清要注册哪些 id。

## 5. 22 个敌人与 14 场遭遇

数值按档位成阶梯：`minion` 血量 28..56、`elite` 96..180、`boss` 420。`habitat` 权威，
遭遇必须落在其内。

### 5.1 敌人原型（22）

|id|名称|档|五行|怕五行|怕流派|HP|攻|防|速|破绽|精灵|出没|
|---|---|---|---|---|---|---|---|---|---|---|---|---|
|`enemy.blood-bat`|血蝠|minion|fire|water|palm|28|10|1.8|12|30|`enemy-beasts` # `bat`|mist-forest、village-outskirts|
|`enemy.bone-captain`|骸骨甲士|elite|metal|fire|blade/palm|180|30|10|6|95|`enemy-warrior-skeleton` # `idle.s`|mist-forest、xueling-hold|
|`enemy.caravan-raider`|劫商马贼|elite|fire|water|sword|120|24|6.5|10|85|`enemy-beasts` # `centaur`|changan、yumen-town|
|`enemy.corpse-puppet`|尸傀|minion|earth|fire|blade|56|13|4.2|3|60|`enemy-skeleton` # `idle.s`|miaoling-village、mist-forest、village-outskirts|
|`enemy.demon-general`|魔骨将|boss|earth|metal|sword/blade|420|42|14|9|100|`enemy-demon-skeleton` # `idle.s`|mist-forest|
|`enemy.desert-brigand`|沙盗|elite|earth|wood|blade/palm|140|26|7.5|7|95|`enemy-beasts` # `yaktaur`|yumen-town|
|`enemy.dune-scorpion`|沙蝎|minion|earth|water|palm|34|10|3.6|6|40|`enemy-beasts` # `bee`|yumen-town|
|`enemy.frost-wraith`|冰魈|elite|water|fire|palm|96|20|5|8|75|`enemy-beasts` # `wraith`|xueling-hold|
|`enemy.frozen-corpse`|冰尸|elite|water|fire|blade|130|18|8|3|90|`enemy-skeleton-red-eyes` # `idle.s`|miaoling-village、xueling-hold|
|`enemy.grain-bandit`|劫粮盗|minion|wood|metal|sword/blade|44|11|2.6|5|55|`enemy-beasts` # `dragoon`|changan、jiange-post、luoyang、xiangyang|
|`enemy.gu-poison-worm`|蛊虫|minion|wood|metal|palm|30|9|2.2|8|35|`enemy-beasts` # `worm`|miaoling-village|
|`enemy.market-thug`|市井恶徒|minion|earth|metal|sword|38|9|2|6|50|`enemy-beasts` # `goblin`|jinling、luoyang、village-outskirts|
|`enemy.miao-hexer`|苗疆蛊巫|elite|wood|metal|palm|92|19|4.5|9|75|`enemy-beasts` # `naga-mage`|miaoling-village|
|`enemy.mist-stalker`|雾影|minion|earth|fire|sword|40|12|2.5|10|40|`enemy-beasts` # `shadow`|mist-forest|
|`enemy.mountain-sprite`|山魈|elite|wood|metal|blade|104|21|5.5|9|80|`enemy-beasts` # `goblin`|jiange-post|
|`enemy.river-pirate`|江上水贼|minion|water|earth|blade|46|12|2.4|7|55|`enemy-beasts` # `dragoon`|canglang-ferry、kaifeng、luoxia-isle|
|`enemy.rogue-swordsman`|蜀道游侠|elite|metal|fire|sword|118|27|6.8|12|85|`enemy-beasts` # `spectral-warrior`|jiange-post、jinling、xiangyang|
|`enemy.sea-wraith`|海鬼|minion|water|earth|palm|42|11|2.9|7|45|`enemy-beasts` # `ghost`|canglang-ferry、luoxia-isle|
|`enemy.snow-wolf`|雪狼|minion|water|fire|sword|48|13|2.8|9|45|`enemy-beasts` # `bat`|xueling-hold、yanmen-fortress|
|`enemy.steppe-rider`|北狄游骑|elite|metal|fire|blade|112|22|6|11|80|`enemy-beasts` # `centaur`|yanmen-fortress|
|`enemy.sunken-soul`|溺魂|elite|water|fire|sword|126|25|6.2|8|90|`enemy-beasts` # `soul-eater`|canglang-ferry、luoxia-isle|
|`enemy.wharf-brawler`|码头打手|minion|earth|wood|palm|52|12|3.4|4|60|`enemy-beasts` # `vault-guard`|canglang-ferry、kaifeng|


`破绽` 是 `breakMax`；`精灵` 是 `{anim, clip}`；`出没` 是 `habitat`，遭遇所在图必须取自其中。


### 5.2 遭遇编队（14，每张地图一场）

|id|名称|地图|成员|XP|金|任务|
|---|---|---|---|---|---|---|
|`encounter.canglang-night`|沧浪渡·夜渡|`canglang-ferry`|enemy.river-pirate×2、enemy.sea-wraith×1|84|38|quest.bounty|
|`encounter.changan-caravan`|长安西市·劫道|`changan`|enemy.caravan-raider×1、enemy.grain-bandit×2|70|32|quest.bounty|
|`encounter.jiange-ambush`|剑阁驿·蜀道伏|`jiange-post`|enemy.mountain-sprite×1、enemy.grain-bandit×2|88|40|quest.bounty|
|`encounter.jinling-alley`|金陵长街·暗手|`jinling`|enemy.market-thug×2、enemy.rogue-swordsman×1|74|34|quest.bounty|
|`encounter.kaifeng-wharf`|开封码头·漕帮|`kaifeng`|enemy.wharf-brawler×2、enemy.river-pirate×1|62|28|quest.bounty|
|`encounter.luoxia-wreck`|落霞岛·沉船|`luoxia-isle`|enemy.sunken-soul×1、enemy.sea-wraith×2|104|50|quest.bounty|
|`encounter.luoyang-market`|洛阳南市·看场子的|`luoyang`|enemy.market-thug×2|40|18|quest.bounty|
|`encounter.miaoling-hex`|苗岭寨外·蛊阵|`miaoling-village`|enemy.gu-poison-worm×2、enemy.miao-hexer×1、enemy.corpse-puppet×1|102|46|quest.bounty|
|`encounter.mist-forest-deep`|雾林深处·魔骨将|`mist-forest`|enemy.demon-general×1、enemy.bone-captain×1、enemy.corpse-puppet×2|260|180|quest.main.boneseal|
|`encounter.outskirts-night`|村郊·夜行|`village-outskirts`|enemy.blood-bat×2、enemy.market-thug×1|44|20|quest.bounty|
|`encounter.xiangyang-pass`|襄阳城外·拦路|`xiangyang`|enemy.grain-bandit×2、enemy.rogue-swordsman×1|78|36|quest.bounty|
|`encounter.xueling-frost`|雪岭坞·冻骨|`xueling-hold`|enemy.frozen-corpse×2、enemy.frost-wraith×1|108|48|quest.bounty|
|`encounter.yanmen-raid`|雁门关外·掠阵|`yanmen-fortress`|enemy.steppe-rider×2、enemy.snow-wolf×1|96|44|quest.bounty|
|`encounter.yumen-dunes`|玉门镇外·沙暴|`yumen-town`|enemy.desert-brigand×1、enemy.dune-scorpion×2|92|42|quest.bounty|


`成员` 一列是文档里的 `{enemy, count}`；投影后展开为 **43** 名成员。

## 6. 素材：从网上找的 CC0 怪物

见 [`../content/anims/CREDITS.md`](../content/anims/CREDITS.md)。要点：

- 两套 **CC0 1.0** 素材（OpenGameArt）：**Skeletons Rework 1.4**（4 款骸骨，
  N/E/S/W × 3 帧行走）与 **Basic Green Monster Collection**（18 款妖物，32×32 单帧）。
  选 CC0 而不是 CC-BY/BY-SA，是因为 CC0 不要求署名，下游漏写 credits 也不构成侵权。
- 下载、校验、合成全部由 `tools/import_bestiary_assets.py` 完成，脚本里钉住上游
  SHA-256；`--check` 不联网、只重算比对，素材漂移会变成构建失败。
- 上游信息逐包记录在 `assets/<pack>/SOURCE.json`，压缩包也一并留存。
- **主角与 NPC 仍然没有图。** `hero.png` / `fireball.png` 依旧不存在，而工作流
  不解析图片、也不检查图片是否存在，所以这两条断链**不会被门报出来**。

## 7. 明确不做、以及没验证的

**不做：**

- 不做遭遇触发。引擎不提供「踩到就开战」，触发条件与地图对象的关系是项目侧
  （`examples/rpg-classic/main.nut:499` 是同一件事的既有做法）。**当前实现是按键触发**：
  `main.nut` 里按 `B` 打当前地图的那一场遭遇（每张地图恰好一场，由
  `systems.encounter-without-battle` 保证）。做一个「踩到就开战」的地图对象类型是加一个
  类型加一条门的事，见 [`11-battle-system.md`](11-battle-system.md) §6。
- 不做敌方 AI。`ai.{aggression,fleeBelowHp,opener}` 是**声明性**的：门保证自洽，
  运行期的回合调度读它们（`lib/rpgc_battle.nut` 的 `enemyTurn`：第一手用 `opener`，
  之后按 `aggression` 决定「认真出手还是平砍」，血量低于 `fleeBelowHp` 时按
  `fleeChance` 逃走）——引擎不读。
- 不做掉落结算。`drops[]` 是声明，引擎没有掉落表；结算在
  `RpgcBattle.settlement()`，只对**被打倒**的敌人掷骰（逃走的敌人不给掉落）。
- 不做战场布局。谁站在屏幕的哪一个位置是 `eve.rpgc.battle` 的事
  （[`10-battle-scene.md`](10-battle-scene.md)）；遭遇只说打谁、几个。
- 不给敌人加 `Trait`。心法那一侧已经证明 `extra` 读不回来（06 §4.2），而敌人文档
  并没有投给 `registerTraitsFromJson` 的通道——元素抗性目前只能用「弱点覆盖少」
  这种间接方式表达。

**没验证：**

- **投影结果没有被引擎的加载器真正吃过。** `data/encounters.engine.json` 是按
  `EncounterCatalogue.cpp` 的规则逐条对着写出来的，但本工作流跑不出 `rpg` 绑定：
  用 `eve run --no-window -r` 探过，`"rpg" in getroottable()` 为 `false`，
  `eve.Schema()` 可用而 `rpg` 不可用，所以 `replaceEncountersFromJson` 在这棵树里
  调不到。这一条是**已知缺口**，需要在一个真正的游戏工程里加载一次才能闭合。
- 敌人精灵是 32×32 单帧的静态图，`enemy-*.json` 里的剪辑因此只有一帧。
  攻击动作没有独立帧——这是素材本身的限制，不是文档写错。

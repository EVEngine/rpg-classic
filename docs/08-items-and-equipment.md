# 08 · 物品与装备

> 01–05 说明这套工作流怎么用，`06-game-design.md` 说明打出来的游戏长什么样，
> `07-world-atlas.md` 说明世界怎么分片。本文只讲一件事：**物品**。
>
> 物品是这套工作流里第一个**引擎已经有一半**的 kind：`inventory` 模块有完整的
> 物品定义注册表与装备栏，`rpg` 模块有物品→属性加成的注册表。所以这一层的大部分
> 工作是**把引擎的沉默点找出来，交给门**，而不是发明数据结构。

---

## 1. 引擎已有的那一半

### 1.1 `ItemDefinition`

```cpp
// src/modules/inventory/ItemTypes.h:13-27
struct ItemDefinition {
    std::string id;
    std::string displayName;
    int maxStack = 1;
    float weight = 0.f;
    float volume = 0.f;
    std::vector<std::string> tags;
    std::string category;
    std::string equipSlot;                                  // ← 只是建议
    std::unordered_map<std::string, std::string> extra;
};
```

注册入口是 `eve.Inventory().registerItemsFromJson(json)`（`Inventory.h:24`，
绑定在 `Inventory.cpp:250`）。它接受**单个对象或数组**，返回成功注册的数量
（`Item.cpp:84-109`）。

### 1.2 引擎在这里的四处沉默

`parseItemObject`（`Item.cpp:67-80`）只读九个键，`registerItem`
（`Item.cpp:45-51`）只做三件善后。合起来是四条**不报错**的行为：

| 沉默 | 位置 | 表现 |
|------|------|------|
| 未知键被丢弃 | `Item.cpp:67-80` | 写错字段名 = 字段不存在，没有告警 |
| 重复 id 覆盖 | `Item.cpp:50` `table()[copy.id] = std::move(copy)` | 后一份静默赢，前一份消失 |
| `maxStack <= 0` 被改成 1 | `Item.cpp:48` | 「不可堆叠」与「写错了」不可区分 |
| 空 `displayName` 变成 id | `Item.cpp:49` | UI 上直接显示英文 id |

第四条到第三条由 **schema** 兜住（`displayName` 是 `required`，
`maxStack` 有 `minimum: 1`），不是由语义门兜——见 §5。

### 1.3 `equipSlot` 是「建议」，但它确实会被比较

```cpp
// src/modules/inventory/ItemTypes.h:21
/** @brief 非空表示建议装备槽名；是否可装备由 EquipmentSet 槽位配置最终决定。 */
std::string equipSlot;
```

「建议」这两个字容易读过头，实际行为要分两半看：

- **会被比较。** `EquipmentSet::canEquipFromBag`（`Equipment.cpp:108-111`）里有
  `if (!def->equipSlot.empty() && def->equipSlot != equipSlot) return false;`——
  一个非空的 `equipSlot` 必须等于**传进来的槽位名**，否则这次装备失败。
  另一条通道是 `addSlotAllowedTag(slot, tag)`（`Equipment.cpp:26`）：
  槽位配了允许标签时，物品的标签必须命中其中一个。
- **不会被反过来解析。** 引擎里没有任何东西拿 `ItemDefinition.equipSlot`
  去调 `defineSlot`（`Equipment.cpp:12`）。也就是说槽位的**名字表**永远是项目建的，
  引擎只负责拿物品上的字符串和它比一次。

所以 `equipSlot: "weopon"` 的后果不是「穿不上」，而是**能穿，只要项目恰好也建了一个
叫 `weopon` 的槽**；而项目建的槽名是从别处来的，两边就此漂移，全程零报错。
这就是这条只能由工作流拦的原因，做法见 §4（槽位词表放在 `rules.equipmentSlots`，
`RpgcItems` 用它建 `EquipmentSet`，`systems.item-unknown-slot` 拦词表外的拼写）。

---

## 2. 装备加成：`equipStats`

物品→属性加成的映射由 `EquipmentSystem` 单独维护，不在 `ItemDefinition` 里：

```cpp
// src/modules/rpg/EquipmentSystem.h:28-33
struct EquipmentStat {
    std::string attribute;
    std::string op = "add";
    double value = 0.0;
    int priority = 0;
};
```

注册：`rpg.registerItemStatsFromJson(itemId, json)`（`RPG.h:240`，绑定 `RPG.cpp:1294`）。
施加：`rpg.syncEquipModifiers(actor, equipSet)`（`RPG.h:245`）——
它对**每个槽位**先 `removeAllModifiersBySource(actor, "equip:" + slot)` 再重新施加
（`EquipmentSystem.cpp:63-77`），所以穿脱换装后属性是收敛的，不需要项目自己记账。

### 2.1 `op` 拼错的后果：一条不存在的加成

这是这一层最值得记下来的一个坑，因为它串联了三处代码：

```cpp
// EquipmentSystem.cpp:73 —— 返回值被丢弃
AttributeSystem::addModifier(actor, stat.attribute, source, stat.op, stat.value, stat.priority);
```

```cpp
// AttributeSystem.cpp:58-74 —— 不认识的 op 直接提前返回
auto parsed = ::eve::attributes::parseAttributeOperation(operation, value);
if (parsed.ok()) { ... }
else if (customOps().has(operation)) { ... }
else {
    parsed.ignore("unknown RPG attribute operation");
    return {};                       // ← 什么都没加，也不报错
}
```

`customOps()` 在生产代码里是**空表**——只有测试注册过 `"square"`
（`test/rpg.cpp:57`、`test/attributes_rpg_unification.cpp:93-94`）。
所以：**一个拼错的 `op` = 一条永远不生效的装备加成，全链路零报错。**

### 2.2 `op` 的合法拼写由引擎决定，不由本工作流决定

`parseAttributeOperation`（`src/modules/attributes/AttributeSet.cpp:30-53`）
接受的是这一组：

```text
add  additive_percent  mulAdd  multiplicative_percent  mulMul  multiply
override  clamp_min  clampMin  min  clamp_max  clampMax  max
```

语义注意两条：

- `multiplicative_percent` / `mulMul` 的值是**增量**：最终 `× (1 + value)`；
- `multiply` 的值是**倍数**：内部做 `value -= 1.0`，所以 `multiply 0.75` 就是 `× 0.75`。

本工作流的内容一律用 `multiply` 写「倍数」，因为文档里那个数字就是读者心里的那个
倍数，不需要心算。

> **一个容易踩的不一致。** `AttributeModifier` 的构造函数（`AttributeSet.cpp:76-98`）
> 认的是**另一组**拼写（`add` / `mulAdd` / `mulMul` / `multiply` / `override` /
> `min` / `clampMin` / `max` / `clampMax`，其余一律落进 `Custom`）。
> `EquipmentSystem::syncEquipModifiers` 走的是**字符串门面**
> （`AttributeSystem::addModifier`），也就是 `parseAttributeOperation` 那一组。
> 两条路接受的拼写不同，本文描述的是**装备加成实际走的那一组**。
> 用 `parseAttributeOperation` 不接受、`customOps()` 里也没有的拼写，
> 唯一的结果就是 §2.1 的静默失效。

### 2.3 与 `effect` 的 `op` 是同一个解析器

`StatusSystem` 也用 `parseAttributeOperation`（`StatusSystem.cpp:220`），
不同之处是它**会失败**：解析不出来且 `customOps()` 里没有，就返回
`Result` 失败（`StatusSystem.cpp:225-233`）而不是静默跳过。

所以 `effect` 与 `item` 的 `op` 词表在 schema 里是**同一组**。
（历史上 `eve.rpgc.effect` 写的是 `["add","mul","set"]`，其中 `mul` / `set`
两个拼写引擎根本不接受——`content/effects/exposed.json` 与 `stun.json` 就踩在上面，
即游戏的破防与眩晕两个效果**从来没生效过**。这次一并改了：schema 换成引擎的合法集合，
两份内容改用 `multiply`。这是「schema 自己认可了引擎会拒绝的拼写」这一整类 bug 的样本。）

---

## 3. 项目侧的半段：`use` 与 `teaches`

`ItemDefinition` 里**没有**「使用」「学习」这两个概念，也没有任何
`EffectDefinition` 引用——`extra` 是唯一的字符串袋。所以：

- **`use`**：消耗品使用时做什么。`{ consume, cooldown, targetType, effects[] }`。
  `effects[]` 走引擎已有的 `rpg.applyEffect`，但「调用 `applyEffect`」这件事是**项目侧**
  的动作，引擎没有任何「物品被使用」的回调。
- **`teaches`**：秘籍教什么。`{ art, skill }`。引擎没有「学会一门武学」的概念，
  品级与解锁本来就是项目数据（`06-game-design.md` §2）。

两者都只允许出现在对应的 `category` 上（§5），否则就是第二份真源的起点。

> **这里有一个和 `06-game-design.md` §4.2 相反的事实，值得写下来。**
> 那份文档说「定义侧的 `extra` 在 Squirrel 里读不到」——这句对 `rpg` 的技能/效果/特征/
> 职业定义成立，但**对物品不成立**：`eve.Inventory().getItemExtra(itemId, key, fallback)`
> 是绑定过的（`Inventory.h:38`，绑定在 `Inventory.cpp:261`）。
> 所以物品的 `extra` 是**可读**的，本工作流因此可以放心地把 `icon` 这类表现键放在那里。
> 两套模块的行为不一致，读的时候要认准是哪一个。

---

## 4. 装备槽位词表为什么在 `rules` 里

`equipSlot` 无法自我校验：它要对的是一组**运行时**才由 `defineSlot` 建立的槽位名。
既然那组名字在内容树里必须有一个权威，就放在既有的单例文档里：

```json
// content/rules/rules.wuxing.json
"equipmentSlots": ["weapon", "offhand", "armor", "helm", "boots", "accessory"]
```

这与 `weakStyles` 是同一类东西（一张项目侧词表），所以放同一个文件、同一层门
（`RpgcSystems.itemCrossDiagnostics`）。物品的 `equipSlot` 不在这个表里就是 error，
而不是一件穿不上的装备。

---

## 5. 文档形状

```json
{
  "schema": "eve.rpgc.item",
  "version": 1,
  "id": "weapon.liuhe-blade",
  "displayName": "六合刀",
  "category": "weapon",
  "rarity": "rare",
  "maxStack": 1,
  "weight": 4.5,
  "volume": 3.0,
  "value": 1200,
  "tags": ["weapon", "blade"],
  "equipSlot": "weapon",
  "equipStats": [{ "attribute": "attack", "op": "add", "value": 12 }],
  "requires": { "artId": "art.liuhe-blade", "minGrade": 1 },
  "extra": { "icon": "ui/items/weapon.liuhe-blade.png" }
}
```

| 字段 | 归属 | 说明 |
|------|------|------|
| `id` / `displayName` / `maxStack` / `weight` / `volume` / `tags` / `category` / `equipSlot` / `extra` | 引擎 | 原样进 `registerItemsFromJson`。`id` 必须等于文件名 stem（`rpgc_validate.nut` 的 `ref.id-matches`） |
| `title` / `description` | 工作流 | 人读的标签，引擎不认，也不会被 `additionalProperties:false` 之外的东西读到 |
| `rarity` / `value` | 项目侧 | 稀有度与基础价，商店与掉落用；引擎没有价格概念 |
| `equipStats[]` | 项目侧 → 引擎 | `rpg.registerItemStatsFromJson(itemId, json)` |
| `use` | 项目侧 | 消耗品专属 |
| `teaches` | 项目侧 | `manual` 专属 |
| `requires` | 项目侧 | `{ level, artId, minGrade }`；`minGrade` 对 `art.maxGrade` 求值 |

`category` 是封闭集合：`consumable` / `weapon` / `armor` / `accessory` /
`material` / `quest` / `manual`。引擎里它是**自由字符串**，这里收紧是因为
`use` / `teaches` / `equipSlot` 三者的合法性全挂在它上面。

---

## 6. 这一层在六层门里的位置

| 层 | 物品相关的检查 |
|----|----------------|
| 1 schema | `category` 枚举、`displayName` 必填、`maxStack ≥ 1`、`equipStats[].op` 的合法拼写、`use.effects[]` / `equipStats[]` 长度上限、未知字段拒绝 |
| 2 语义门（`RpgcSystems.itemDiagnostics`） | 装备类别必须有 `equipSlot`、非装备不得有、装备不得叠堆、`equipStats` 只允许装备且每条要有 `attribute`、消耗品必须有 `use` 且 `effects` 非空、`manual` 必须有 `teaches`、非对应类别不得声明 `use` / `teaches`。另有 `RpgcSystems.partyDiagnostics` 里的开局背包：`party.startingItems[].itemId` 形状与重复（§7.5） |
| 3 引用门 | `use.effects[]` → effect；`teaches.art` / `teaches.skill` / `requires.artId` → art / skill；**`party.startingItems[].itemId` → item**（§7.5） |
| 4 模块额外检查（`itemCrossDiagnostics`） | `equipSlot` 必须在 `rules.equipmentSlots` 里；`teaches` 同时点名 art 与 skill 时，该 skill 必须属于那门 art；`requires.minGrade ≤ art.maxGrade` |
| 5 失败关闭 | 与其余 kind 相同：模块对不上就是 error，不是跳过 |

一个刻意的取舍：**`maxStack <= 0` 没有语义门**。schema 的 `minimum: 1` 已经在
更早一层拦下它，再写一条语义检查就是一条永远触发不了的死代码。
`tools/modules_check.nut` 的 `reject.item-max-stack` 探针因此断言
`validate.schema`，钉住真正生效的那一层。

---

## 7. 运行时：`lib/rpgc_items.nut`

### 7.1 先说结论：引擎那一半在这棵树里够不着

本文 §1 到 §3 一直在说「引擎已经有一半」。**文档那一半是对的，运行的那一半不是。**
`cmake/module_manifest/core_foundation.cmake:105` 是

```cmake
eve_declare_module(NAME inventory LAYER 0 SCRIPT Inventory)
```

`SCRIPT Inventory` 声明了类名，**没有 `SLOT`**；而 `src/scripts/load.nut:93-108`
只实例化同时给出 `SCRIPT` 与 `SLOT` 的模块。探针实测（`tools/modules_check.nut`
的 `items.inventory-unbound` 就是这条断言）：

```text
[modules] ok   items.inventory-unbound
[modules] ok   items.rpg-unbound
```

`("Inventory" in eve)` 与 `("rpg" in getroottable())` 都是 `false`。所以：

- `eve.Inventory()`、`registerItemsFromJson`、`newBag`、`newEquipmentSet`、
  `rpg.registerItemStatsFromJson`、`rpg.syncEquipModifiers` —— **一条都调不到**；
- 本文早期版本 §7 给出的正是这段代码。它在本机是不能运行的，与内容无关，
  一个只含 `local x = eve.Inventory();` 的空脚本即可复现。

这与 `rpg` 在战斗系统里的处境完全相同（[`11-battle-system.md`](11-battle-system.md) §1）。
结论也一样：**运行时是项目侧对引擎算法的复述**，不是对引擎的调用。

### 7.2 `RpgcItems` 复述了哪几处

| 复述的东西 | 出处 |
|-----------|------|
| 定义解析（九个键）、重复 id 后者覆盖 | `Item.cpp:45-80` |
| `maxStack <= 0` 被当成 1 | `Item.cpp:48`、`InventorySystem.cpp:330` |
| `addItem` 先续堆、再开空槽，返回**实际放进去多少** | `InventorySystem.cpp:369-430` |
| 容量策略 `slotsAndWeight`；重量/体积上限 `<= 0` 表示「不限」 | `Bag.h:114-117`、`InventorySystem.cpp:195-211` |
| 装备槽放的是**整堆**，换装时旧的那堆回原背包格 | `InventorySystem.cpp:718-745` |
| `equipSlot` 非空时与目标槽名比较 | `Equipment.cpp:108-111` |
| `syncEquipModifiers` 的「先清 `equip:<slot>` 再施加」 | `EquipmentSystem.cpp:60-79` |
| 属性合成顺序：add → additive_percent → multiplicative，再按 priority 走 override/clamp | `AttributeSet.cpp:100-142` |
| `multiply N` 内部存成 `N - 1`，意思是「乘以 N」 | `AttributeSet.cpp:38-40` |
| `op` 的 13 个合法拼写 | `AttributeSet.cpp:30-53` |

不认识的 `op` 在这里**和引擎里一样什么都不做**（`AttributeSystem.cpp:66-69` 提前
`return {}`，而 `EquipmentSystem.cpp:73` 连返回值都丢掉）。区别只有一个：
`RpgcItems.unknownModifiers(set, config)` 会把这条加成**报出来**，
所以「拼错了但没有任何地方说」这句话在运行时边界上不成立。

### 7.3 背包、装备、使用

```squirrel
local loaded = RpgcItems.loadProject();          // { items, slots, rules }
local config = loaded.value;

local bag = RpgcItems.newBag(24, "party");       // 24 格的固定槽位数组
RpgcItems.add(bag, config, "potion.heal", 3);    // 返回 Result({ added, requested, remaining })
RpgcItems.canAdd(bag, config, "potion.heal", 3); // Result(true) 或 items.no-slot / over-weight

local set = RpgcItems.newEquipmentSet(config, "party");   // 槽位名取自 rules.equipmentSlots
RpgcItems.equip(bag, set, config, "weapon.iron-sword");   // Result({ slot, itemId, replaced })
RpgcItems.unequip(bag, set, config, "weapon");            // Result({ moved, kept })

local mods = RpgcItems.modifiersOf(set, config);          // [{attribute, op, value, priority, source, itemId}]
RpgcItems.attributeValue(30.0, mods, "attack");           // 与 computeAttributeValue 同序

local used = RpgcItems.use(bag, config, "potion.heal");   // 消耗在这一步发生
// used.value.effects = ["regenerate"]，targetType = "allySingle"
```

三条容易踩的语义，都在探针里有对应断言：

- **`add` 的部分成功是正常结果。** 引擎的 `addItem` 返回实际放进去的数量，
  放不下就说 0，不报错。`RpgcItems.add` 同样返回 `{ added, requested, remaining }`，
  只读 `ok` 的调用方会以为整批都进去了。
- **换装不需要额外空间。** 旧的那堆回到新物品腾出来的那个背包格，所以不会因为
  「换装备时背包满了」而失败。
- **`unequip` 可能只成功一半。** 背包放不下的部分留在装备槽里，结果里的
  `kept` 就是留在身上的数量——悄悄丢装备比拒绝脱下更糟。

### 7.4 消耗品的「使用」由谁执行

`use.effects[]` 里的效果要真的生效，只有一条路：战斗结算器里的
`RpgcBattle.applyEffect`。所以 `RpgcItems.use` 只做两件事——**扣掉物品**、
把效果列表交给调用方；`RpgcItems.battleCommands` 把背包里可用的消耗品投影成
和 `RpgcBattle.commandsFor` 同形的命令项，效果随命令一起走：

```squirrel
// 战斗内：先提交命令，成功之后才扣物品。
local order = { itemId = "potion.heal", label = "金创药",
                targetType = "allySingle", target = targetId,
                effects = ["regenerate"] };
local done = RpgcBattle.submitItemCommand(fight, order);   // 目标非法时什么都不花
if (done.ok) RpgcItems.use(bag, config, order.itemId);
```

顺序是刻意的：`submitItemCommand` 沿用 `performSkill` 的契约——**被拒绝的命令
不消耗任何东西**，所以先扣物品再提交，会让一次非法目标白吃一瓶药。

**命令表是有上限的，而且消耗品排最后。** 操作环的按钮数来自
`ui.commandRing.buttons`（条数由 `systems.battle-ui-button-count` 封顶，
上限是 `RpgcSystems.maxBattleCommandButtons` = 8），键盘只有 9 个数字键，
所以 `main.nut` 的 `battleCommandList` 取两者中较小的一个做上限。一个招式很多的角色
可能把消耗品挤出环外——这是**屏幕上放不下**，不是门漏了什么；`battleHelp` 那一行
列的就是这一帧真正可选的东西。这也是本工作流唯一一处「文档允许、界面装不下」的地方，
写在这里而不是藏在代码里。

**战斗结算的掉落也走同一条路**：`RpgcBattle.settlement` 报 `loot`，
`RpgcItems.applyLoot` 放进去，放不下的部分进 `lost` 并在结算行里写出来。
在这之前，掉落只是被 `print` 出来——结算报了、没人接、屏幕上看起来像奖励。

### 7.5 开局背包：`party.startingItems`

引擎没有「队伍开局带什么」这个概念，所以这份数据只能放在项目侧。放 `party` 而不是
`rules`，因为它是**名单的事实**：

```json
// content/party/party.default.json
"startingItems": [
  { "itemId": "potion.heal", "count": 3 },
  { "itemId": "weapon.iron-sword", "count": 1 }
]
```

`itemId` 是出边引用（第 3 层门），`count` 的 `minimum: 1` 由 schema 负责，所以语义门
只查 schema 看不见的两件事：id 形状与重复（`systems.party-starting-item-id` /
`systems.party-starting-item-duplicate`）。两条都有反例探针，
其中 `count = 0` 那条断言的是 `validate.schema`——钉住真正生效的那一层。

### 7.6 存档

`RpgcItems.snapshot(bag, set)` / `restore(text, config)` 的形状与
`InventorySaveSession` 为引擎自己的 `Bag` + `EquipmentSet` 保存的文档一致，
所以把项目侧换成真引擎模块时读的是同一份文档。`restore` **不会留下半应用的状态**：
一行读不动就整份拒绝（`items.snapshot-item` / `items.snapshot-row` /
`items.snapshot-equip`）。

游戏侧用的就是这个：

```squirrel
// main.nut —— 背包跨热重载活着，靠的就是这一对函数
persist bagSnapshot = "";
bagSnapshot = RpgcJson.encodeCompact(RpgcItems.snapshot(itemBag, itemEquip));
```

---

## 8. 明确不做的

- **不给物品加「使用时施加的效果」的引擎字段。** 那要改 `ItemDefinition` 与
  `InventorySystem`，属于引擎改动；`use` 是文档层的项目侧半段，与 `skill.presentation`
  同一性质。
- **不在 `item.extra` 里藏玩法数据。** `extra` 在物品这条路上**是**可读的
  （`getItemExtra`，§3），正因为它可读，才更容易变成第二份真源。
  `use` / `teaches` / `equipStats` 是结构化的那一份，`extra` 只放图标一类表现键。
- **不把装备槽位词表放进物品文档。** 一份物品一条 `equipSlot` 是引用，不是定义；
  定义在 `rules`。
- **不把 `equipStats` 和 `use` 合成一个字段。** 两条路径的下游完全不同：
  加成进 `EquipmentSystem` 的属性通道，效果进战斗结算的 `applyEffect`。
  合成一个字段只会让「这条是给谁读的」需要靠猜。
- **不做版本迁移。** `version` 固定为 1，未知字段一律拒绝。

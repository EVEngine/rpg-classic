# 11 · 战斗系统

> 前十个 kind 描述了一场战斗，却没有任何东西**跑**过一场战斗：`enemy` 拿数值、`encounter`
> 拿编队、`party` 拿我方名单、`battle` 拿屏幕几何、`rules` 拿五行与破绽，五份文档互不相识。
> 本文说明把它们接起来的那一层：`lib/rpgc_battle.nut`、它为什么是**项目侧**的一份复述、
> 它复述的是引擎的哪几个函数、它把哪些东西留给内容文档，以及运行期（`main.nut`）怎么把它
> 演出来。
>
> 五行相生相克与击破链的设计在 [`06-game-design.md`](06-game-design.md) §3；敌人原型与
> 遭遇在 [`09-enemies-and-encounters.md`](09-enemies-and-encounters.md)；屏幕布局在
> [`10-battle-scene.md`](10-battle-scene.md)。本文只回答一个问题：**谁先动手，打多少，
> 什么时候算完。**

## 1. 一句话：这一层是唯一会「执行」这些文档的东西

```text
rules.wuxing.json   五行表 / 破绽阈值 / 回合秒数 / 资源池
party.default.json  五名我方：数值 + 五行 + 武学品级
enemy.*.json        二十三个敌人原型（数值的唯一真源）
encounter.*.json    十四场编队（打谁、几个、奖励）
battle.*.json       六块战场（谁站在屏幕的哪里）
                    ↓
        lib/rpgc_battle.nut  ← 唯一的执行者
                    ↓
   events / log / outcome / settlement   ← 运行期 adapter 消费
```

引擎里**没有**这条链的另一半可用：`src/modules/rpg` 确实带着一套战斗运行时
（`Battle` / `BattleSystem` / `BattleControl` / `StatusSystem`），但本构建**没有绑定它**。
`cmake/module_manifest/core_foundation.cmake:102` 把 `rpg` 声明成
`SCRIPT RPG` 却**没有给 `SLOT`**，而 `src/scripts/load.nut:99` 只实例化
`eve.moduleList` 里带 slot 的模块——所以 `"rpg" in getroottable()` 是 `false`。
`tools/modules_check.nut` 把这条事实写成断言（`battle.engine.rpg-binding-absent`），
并带一句「它哪天变成 true，就删掉这份复述去调引擎」。

## 2. 复述了引擎的什么（逐条对着源码）

这是本项目里唯一一处「引擎有、项目又写了一遍」的地方，所以边界必须写死：**只有算术**。
五行的代数、破绽、回合钟、敌人 AI 不在其中——那些引擎本来就没有（`06` §3.5、`09` §7）。

| 项目侧 | 引擎出处 | 复述的内容 |
|---|---|---|
| `RpgcBattle.evaluate` | `BattleSystem::parseFormula`（`BattleSystem.cpp:55-196`） | `+ - * /`、括号、一元符号、数字、`a.<attr>` / `b.<attr>`；除零、尾随输入、`1.2.3`、非有限值一律**拒绝**；属性取**最终值**（`:152` 调 `AttributeSystem::getFinal`） |
| `RpgcBattle.resolveHit` | `BattleSystem::resolveHit`（`:210-251`） | 顺序固定：命中判定 → 公式 → 下限 1 → `elementRate` → 暴击 ×3。命中率是**百分数**，而文档里的 `hitChance` 是 0..1（`04-runtime-integration.md` §2.4 的换算） |
| `RpgcBattle.attributeOf` | `computeAttributeValue`（`AttributeSet.cpp:100-142`） | `(base + Σadd) × (1 + ΣaddPercent) × Π mult`，然后按 `priority` 稳定排序的 `override` / `clampMin` / `clampMax` |
| `op` 词表 | `parseAttributeOperation`（`AttributeSet.cpp:30-53`） | `add` / `additive_percent` / `mulAdd` / `multiplicative_percent` / `mulMul` / `multiply`（= `×(value)`）/ `override` / `clamp_min` / `clamp_max` |
| `RpgcBattle.effectIsPeriodic` | `StatusSystem.cpp:202` | `period > 0` 的状态**不绑定任何常驻修改器**，每 `period` 秒结算一次 `hp` 修改器 |
| `RpgcBattle.projectedMemberId` | `tools/build_encounters.py:95` | 成员 id 是 `stem.index`（`enemy.bone-captain` 的第 3 只 = `bone-captain.2`），日志里的名字与引擎目录里的名字是同一个 |

**没有复述的是随机数。** 引擎每次命中用 `std::mt19937(seed)`，那从 Squirrel 驱动不了；
项目用一条 xorshift32 流，种子存在 fight 状态里，所以同一场战斗跑两遍结果一致
（`battle.determinism.same-seed`）。

## 3. 内容文档里的东西，引擎不查、这里也不查

`RpgcBattle` 只消费**文档已经说过的**事实，不引入第二份表：

- 相克表读 `rules.overcomes`（`RpgcBattle.overcomes`），五行名就是字符串，没有对照表副本；
- 破绽的四个阈值读 `rules.break`；
- 一回合多少秒读 `rules.clock.turnSeconds`，破绽状态挂多久读 `rules.breakEffects[].turns`；
- 资源池读 `rules.resources`（`stamina` 40 / `mana` 30），技能的 `costs[]` 从这里扣；
- 我方的招式表**编译**自 `art` + `grade`（`06` §2.4），`party.default.json` 里没有招式副本。

## 4. 一场战斗的形状

```text
newFight(config)          五份文档 → 战斗状态（含 seed）
  ├─ 我方：party.members[] 按序坐到 battle.allySlots[k]
  ├─ 敌方：encounter.members[] 展开（与 build_encounters.py 同一套）+ battle.enemySlots[k]
  └─ 回合序：按 speed 降序，平手时我方优先、再按阵位号
advanceTurn(fight)        轮到敌方就自动出手；轮到我方就停在 pending 上等指令
submitCommand(fight, c)   我方出一手（招式 + 目标，或防御），然后推进
runToEnd(fight, n)        无头跑到底（检查与游戏里的 Q 键都走它）
settlement(fight)         胜利时的 xp / 金币 / 掉落
```

三条容易忽略的规则：

- **一回合 = `clock.turnSeconds`。** 状态时长按回合结算（每回合末减 `turnSeconds`），
  所以「2 回合眩晕」= `2 × 6.0 = 12.0` 秒，而 `RpgcSystems` 早就拒绝
  `breakEffects[].turns × turnSeconds != effect.duration` 的文档。检查里
  `battle.status.duration-seconds` / `-one-round-left` / `-expires-after-two` 把这三步钉住。
- **相克不进伤害公式。** 引擎的公式 DSL 没有表查询，而 `elementRate` 是唯一结算倍率
  （`06` §3.2）。相克只影响破绽：`overcomes` → `onOvercome`，属性弱点 → `onWeakElement`，
  武功弱点（`skill.tags ∩ weakStyles`）→ `onWeakStyle`，三者相加扣破绽值；归零则挂
  `rules.breakEffects` 并**把表复位到 `breakMax`**，每回合末再回 `regenPerRound`。
- **眩晕是项目侧实现**（引擎不内置）。带 `stun` tag 的状态让该单位在轮到它时被跳过，
  一回合都不出。

## 5. 屏幕：运行期 adapter 是纯投影

`RpgcBattle` 不碰纹理、不碰 `SpriteAnim`、不碰鼠标，它只给两样东西：

```text
placeOnScene(fight)    每单位一条 { unit, side, slotId, x, y }（battle 文档的阵位坐标）
fitToViewport(...)     设计分辨率 → 视口的等比缩放与居中偏移（letterbox）
```

`main.nut` 是消费端，它做的全是投影：

- 背景：`battle.background` 是文档相对路径，解析成 `content/battles/<path>` 再
  `gfx.newTextureFromFile`；**加载失败会写一行 `[rpgc] warn:`**，因为
  `newTextureFromFile` 会吞掉缺文件，不写的话场景只是安静地不画背景；
- 两块阵地：`zones.enemy` / `zones.ally` 画成半透明底；
- 每个单位：身体方块 + 头顶血条 + 脚下破绽条，当前该动的一方加一圈高亮；
- 右下人物 HUD：`ui.party` 的 `slots` / `slotWidth` / `slotGap` / `portraitHeight` 与
  `bars[]` 决定头像格与条的位置，文档里只有几何；**每个头像格里的内容全部来自运行期**：
  名字牌（`displayName`）、脸（`element` 在 `rules.elements` 里的**下标**决定的色相，
  倒下时整格变灰）、脚下的破绽条（`breakValue / breakMax`）、轮到谁动时整格加一圈
  金色描边。条上印 `当前/上限`（工作流不带字体文件，这些数字用一套 3×5 的矩形字画；
  哪天游戏装了真字体，`hudReadout` 会改用它，名字牌也才画得出来），`id` 查不到池子
  就是 `0/0` —— 这条条的「名字对不上池子」由 `systems.battle-ui-bar-unregistered`
  挡在内容门外，所以画面上出现 `0/0` 一定意味着运行期真的没有那个数；
- 左边操作环：`ui.commandRing` 的圆心与半径画十字，每个按钮画一个方块，能用的键点亮，
  并在按钮下标出按键号与指令名（`1 攻击`…），因为「有哪几个键」和「几号键是哪个」是
  两个问题；

> **文档里没有数值，这是刻意的。** HUD 画的是运行期的队伍状态；内容文档不知道现在血量多少。
> 空的阵位（`slots` 是容量，名单可能更短）画成空座位，这是**合法状态**，不是缺图。

> **这一层曾经整块不可见，原因是引擎的深度测试。** `vkb::PipelineBuilder::build()` 会给
> 「渲染通道带深度附件」且没有显式设置深度状态的管线补上 `depthTestEnable = true,
> depthWriteEnable = true, compareOp = LESS`（`external/VKBuilder/include/vkbuilder.hpp:2469-2475`）。
> 交换链渲染通道带深度附件（`src/modules/graphics/vulkan/GraphicsPipeline.cpp:156-176`），
> 而纹理管线显式关掉了深度（同文件 `:295`，`setDepthStencil(false, false)`），**纯色管线
> 忘了**（`src/modules/graphics/vulkan/GraphicsOffscreenPipeline.cpp` 的
> `createSolidColorPipeline`）。后果是：所有纯色矩形都在同一个 z，**每个像素只有第一个
> 覆盖它的纯色矩形能画出来** —— 面板套头像格、头像格套条、阵地套单位，全是「后来的被丢掉」。
> 修法是给三条纯色管线链各加一个 `setDepthStencil(false, false)`，与纹理管线对齐；
> 2D 叠加层靠提交顺序作画，深度对它本来就没有意义。

## 6. 怎么打一场（可玩入口）

```bash
eve run .
```

| 输入 | 作用 |
|---|---|
| 方向键 / WASD、鼠标点击 | 走位、寻路（战斗外） |
| `E` | 与 NPC / 箱子 / 传送门互动 |
| **`B`** | **在当前地图开一场遭遇战** |
| `1`..`9` | 选当前我方单位的第 N 个可用指令（不可用/冷却中/气力不够的招式**不给键**） |
| `Q` | 自动把这场打完（跑到底） |

**为什么是按键而不是「踩到就开战」**：本工作流**没有**建模触发用的地图对象类型
（`09` §7 明确不做），而每张地图恰好有一场遭遇，且由
`systems.encounter-without-battle` 保证没有地图漏掉。所以触发条件是一处显式手势，
不是一个隐形的格子——想要「踩到就开战」，加一个对象类型 + 一条门即可。

结算只有一条缝：`finishBattle` 把 `settlement()` 的 `gold` 加进存档，把掉落与 xp
**打印**出来。xp 没有去处是因为本工作流不建模等级曲线——报出来比悄悄丢掉诚实。

## 7. 门的这一半

新 kind `party` 与新的 `rules.resources` 都补上了各自的门（`RpgcSystems`）：

| 门 | 抓什么 |
|---|---|
| `systems.party-id` / `systems.party-member-id` / `systems.party-member-duplicate` | 花名册与成员 id 的形状与唯一性（成员 id 是运行期的身份，重复 = 一个会自己回血的单位） |
| `systems.party-empty` / `systems.party-member-name` | 空名单、空 `displayName`（HUD 只印这个名字） |
| `systems.party-member-max-hp` | `maxHp > 0`（与引擎对遭遇成员的同一条严格下限） |
| `systems.party-member-art-missing` / `-grade-missing` | `art` 与 `grade` 是一句话的两半，单独出现没有意义 |
| `systems.party-member-sprite-anim` / `-clip` | 精灵名形状 |
| `systems.party-unknown-element` | 五行归属必须落在 `rules.elements` |
| `systems.party-break-over-max` | `breakMax ≤ rules.break.max` |
| `systems.party-grade-over-max` | 品级不得高于该武学的 `maxGrade`（否则招式表编译为空） |
| `systems.party-too-many-members` | 名单人数 ≤ `RpgcSystems.maxBattleAllySlots`（**唯一**一份 5） |
| `systems.resource-attribute` / `-duplicate` / `-max` | 资源池表：名字非空、不重复、`max > 0` |
| `systems.skill-cost-unregistered` | 技能 `costs[].attribute` 必须能在 `rules.resources` 里找到池子 |

最后两条是一对：一条管池子表的形状，一条管池子与技能的**词表一致**。`SkillDefinition.costs`
是自由字符串、背后没有注册表，拼错一个字母不会报错——招式只是**变成免费**。

> **`resources[].max` 的 `minimum: 1` 被刻意删掉了。** 写进 schema 时，`max = 0` 会在第 1 层
> 被 `validate.schema` 拒掉，语义门根本跑不到，`systems.resource-max` 就成了永不点火的
> 死代码。反例探针 `reject.rules-resource-max` 正是发现这一点的那个检查。

## 8. 验证

```bash
cd .  # repository root
EVE=<repo>/build/win32-debug/src/engine/eve.exe
"$EVE" run --no-window -r tools/modules_check.nut   # grep "[modules]"
```

本次实测（`299 ok`、`0 failure`，内容门 `PASS`）：

```text
[modules] ok   battle.formula.engine-vector  got 39 ok
[modules] ok   battle.modifier.additive-percent  got 30
[modules] ok   battle.break.three-sources  100 - (30 + 20 + 25) = 25, got 25
[modules] ok   battle.break.overcome-only  100 - 30, got 70
[modules] ok   battle.status.duration-seconds  got 12
[modules] ok   battle.status.expires-after-two
[modules] ok   battle.determinism.same-seed  log lengths 9 vs 9
[modules] ok   battle.content.every-encounter-plays  14/14 played
[modules] ok   battle.content.somebody-wins  14 victory(ies) of 14
[modules] ok   battle.content.narrow-scene-seats-what-fits  seated 4
[modules] ok   battle.content.narrow-scene-benches-the-rest  bench pc.physician
[modules] ok   battle.report.status-line  round 2 / active | 探针 60/100 破绽 100/100 | ...
[modules] ok   battle.engine.rpg-binding-absent
[modules] ok   battle.content-coverage  real content tree reports 0 battle error(s)
[modules] ok   cross.battle-ui-bar-unregistered  wanted systems.battle-ui-bar-unregistered, got [...]
[modules] PASS (0 failure(s))
```

最有价值的一条是 `battle.content.every-encounter-plays`：它拿**真实内容树**里
十四场遭遇逐一开局并跑到终局。它一次性覆盖了「队伍能不能站位」「品级编译出的招式表
是不是空的」「敌人 AI 会不会卡住」这三类只有接起来才会出现的问题。
`battle.content-coverage` 这一轮起同时守着 HUD 条的**词表**（`mana` 是否真的注册过），
它第一次跑就抓到了六份文档里那个 `mp`。

可玩路径的实测（本机窗口运行，`main.nut` 带一次性自启动补丁）：`[rpgc] battle
encounter.outskirts-night on village-outskirts` → 渲染 90 帧 → `[rpgc] battle
outcome=victory rounds=1 gold=20` → 回到地图，无 warn、无 error。

**画面证据**（`eve run … --mcp-port`，`eve_run_script` 起战斗 + `eve_screenshot` 取帧）
与上面两条不同：它验的是「画出来是什么样」。这一轮取到的帧里，右下角是五个头像格
（紫 / 红 / 黄绿 / 绿 / 蓝五张嘴脸，正好是 `rules.elements` 里 metal→wood→water→fire→earth
的下标色相）、第三格套着金色轮次框、每格脚下一条金色破绽条、条下面两行
`302/320` 与 `30/30` 的数字；左下角操作环上印着 1/2/3/4。**在这之前那一帧里这些
一个都没有** —— 不是没写，是被纯色管线的深度测试吃掉了（§5）。

## 9. 没验证的 / 明确不做的

**没验证：**

- **有截图了，而截图是这一层唯一的视觉证据来源。** 引擎的 MCP 主机（`eve run …
  --mcp-port` + `eve_eval` / `eve_run_script` / `eve_screenshot`）能对着活着的窗口
  取一帧真图，所以「不报错、日志对」不再等于「画对了」。第一次取图就发现人物 HUD
  **整块不可见**（§5 末尾那条深度测试的笔记）：面板、头像格、条、单位身体全在同一 z，
  只有每个像素上第一个纯色矩形活下来。修完引擎再取图，HUD 才出现在右下角。
  **这一条现在同时是「验证方法」和「已知的坑」：任何靠 `gfx.drawSolidRect` 叠出来的
  画面都曾经被这条深度测试吃掉。**
- **敌人没有立绘。** 战斗里每个单位是一个色块：主角与 NPC 在整套工作流里都没有精灵图
  （`content/anims/CREDITS.md`），而敌人素材是 32×32 单帧。这不是渲染写错了，是素材的边界。
  HUD 的头像格因此也不是头像：它是「名字牌 + 五行色相的脸 + 破绽条 + 轮次描边」，
  色相取自 `element` 在 `rules.elements` 里的下标，所以换一个五行归属就换一种脸。
- **xp 没有去处。** 没有等级曲线，所以经验值是报出来的，不是花掉的。
- **AI 只有一种性格。** `ai.aggression` 决定「认真出手 vs 平砍」，`ai.opener` 管第一手，
  `ai.fleeBelowHp` 管逃跑；没有仇恨表、没有集火策略、没有站位偏好。

**不做：**

- **不给敌人加 `Trait`。** 元素抗性目前只能由 `weakElements` 表达（`09` §7）。
- **不做装备对战斗的影响。** `item.equipStats` 是引擎 `AttributeSystem` 的通道，
  项目侧的战斗单位没有装备槽的装配模型——要接的话是下一步，不是这里的半截。
- **不做存档。** 战斗是瞬间状态，不进存档；`main.nut` 里它也不是 `persist`。
- **不把 8 / 5 再写一遍。** 阵位容量仍然只有 `RpgcSystems.maxBattleAllySlots` 一处；
  战斗只读它。

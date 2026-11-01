# rpg-classic — 经典斜 45° 回合制 RPG

独立游戏仓库：脚本、schema、内容文档和美术资源都在这里维护。运行时用预编译的
[`eve` SDK](https://github.com/EVEngine/EVEngine/releases)，**不必在本仓库编译引擎**。

引擎 C++ / 模块绑定的修复请开 PR 到 [`EVEngine/EVEngine`](https://github.com/EVEngine/EVEngine) 的 **`dev`** 分支，见 [ENGINE.md](ENGINE.md)。

`rpg-classic` 把「等距关卡 + 多段精灵动画技能 + 过场事件 + 战斗场景布局 + 五行战斗结算」拆成多种文档、一份共享库和一条校验门，让人类和 AI 都能安全地改内容。

五个编辑器是五个普通的 `eve run` 应用，不是必须先起 MCP。AI 仍然可以用
[`eve mcp`](https://github.com/EVEngine/EVEngine/blob/dev/docs/dev/AI%E4%B8%8EMCP%E6%94%AF%E6%8C%81.md) 同时挂上全部面板。

五个编辑器都**直接读项目文件夹**：`workflow.json` 给每个 kind 指定唯一目录，
面板打开时就读那个目录并把内容列出来，**选中一行就是载入**——没有"打开文档"这一步，
也没有文件选择器。面板标题显示的就是那个目录与它当前的文件数
（`content/maps  ·  14 个文档`）。目录列表每秒重扫一次，所以 AI 在会话中间写进来的
新文档会自己出现；只有"重扫文件夹"按钮会重新读入当前文档本身（那会丢掉未保存的修改）。
详见 [`docs/01-tilemap-editor.md`](docs/01-tilemap-editor.md) §6.1。

## 可复用开发工具套件

新增无 UI 依赖的 `tools/rpgc_toolkit` Python 包与 `rpgc.py toolkit`：覆盖 workflow 声明的全部内容类型查询、候选克隆/补丁、地图绘制/填充/缩放、事件编排、本地化、资源审计、数值汇总和可复现源码分发；另提供剧情/任务编译、引用重命名、隔离变更验证、背包存档迁移、命令录制回放、动画/音频导入与本地 SDK 发布。`graph`、`simulate` 和 `validate --headless` 直接复用真实 VM 的引用、战斗与校验实现，无须显示器或 MCP。

```bash
python tools/rpgc.py toolkit catalog --kind item
python tools/rpgc.py toolkit doctor
python tools/rpgc.py validate --headless
python tools/rpgc.py graph --headless --impact skill/skill.strike
python tools/rpgc.py simulate encounter.outskirts-night --headless --seed 42
make toolkit-test
python tools/rpgc.py selftest --headless
make check-assets
```

制作工具只输出候选 JSON，原有 stage/export 仍是内容写入通道；源码包不等于原生可执行导出。五张原先缺失的动画图已由可复现的程序化开发素材补齐（`tools/build_placeholder_anims.py --check`），授权与用途见 [动画素材记录](content/anims/CREDITS.md)。完整能力对照见 [设计文档](docs/12-toolkit-design.md)，命令、Python API 和写入闭环见 [使用指南](docs/13-toolkit-usage.md)。

主流工具对照与本轮改进见 [RPG Maker / GameMaker / Godot / Unity 工作流比较](docs/14-engine-comparison.md)。新增 `toolkit terrain` 自动地形、`toolkit database` 类型化CSV批量编辑，以及 `toolkit preflight` 发布预检profile，均可独立调用。

后续完整剧情、世界存档、制作效率与平台验证的分阶段设计见 [工具套件补全方案](docs/15-completion-plan.md)（分阶段设计，完成状态按工作包验收）。

## 快速开始

先把 `eve` 放到 PATH（SDK 或本地引擎构建，见 [ENGINE.md](ENGINE.md)），在本仓库根目录执行：

```bash
# 玩游戏（默认入口，加载 content/ 里的地图与事件）
# 方向键 / WASD 走位 · 点击寻路 · E 互动 · B 在当前地图开一场遭遇战 · I 背包 · 1..9 出招
eve run .

# 人用的五个编辑器入口（各开一个编辑器窗口）
eve run apps/tilemap
eve run apps/skill
eve run apps/event
eve run apps/battle
eve run apps/item

# 五个 apps 入口的 config.nut 都设置了 hotReloadWatch = [".."]，
# 改 editors/、lib/、content/ 会热重载；不必把编辑器挪出 apps/。

# 无头校验全部内容文档（需要 eve mcp 能监听；本机监听不了，见下文替代路径）
python tools/rpgc.py validate

# 把编辑器暂存的写落盘（唯一被认可的写路径）
python tools/rpgc.py export

# 一条命令重验上面所有结论（8 项检查，失败退出码非 0；同样需要活宿主）
python tools/rpgc.py selftest

# Agent 入口（可选）：一次挂上五个编辑器
eve mcp --root .
```

宿主启动时会打印一行门结果到 stderr（`mcp.nut:28-51`）：

```text
[rpgc] rpg-classic PASS | anim=0 effect=0 event=0 map=0 skill=0 tileset=0 | ok
[rpgc] store backend=deferred pending=0
```

失败时是 `FAIL` 加上逐条 `d.path: d.message`，**但宿主不会退出**——编辑器正是用来修坏文档的。
`python tools/rpgc.py log` 可以把这段 stderr 读回来。

## 目录结构

```text
rpg-classic/
  workflow.json              清单：kind → 目录 / schema / 模块，以及 play / 编辑器命令
  config.nut / main.nut      默认游戏入口：`eve run .`
  data/world-object-contract.json  运行时地图对象契约（portal.targetMap 的 enum 在此）
  data/world-regions.json         世界设定：十二座聚落的尺寸/图集/NPC/连线与门
  data/encounters.engine.json     生成物：遭遇投影成引擎 EncounterCatalogue 读的裸数组
                                  （`tools/build_encounters.py`，不要手改）
  mcp.nut                    共享宿主脚本：启动校验、帧钩子；apps 与 eve mcp 都会跑
  apps/
    tilemap/                 人用入口：`eve run` 等距地图编辑器
    skill/                   人用入口：`eve run` 技能编辑器
    event/                   人用入口：`eve run` 过场事件编辑器
    battle/                  人用入口：`eve run` 战场编辑器（左上敌阵 / 右下我方）
    item/                    人用入口：`eve run` 物品编辑器（定义 / 装备加成 / 使用与秘籍）
  .gitignore                 忽略引擎每次运行追加的 eve.log 与 tools/__pycache__/
  schema/
    eve.rpgc.tileset.json    Tiled-flat 图集契约
    eve.rpgc.map.json        等距关卡契约（同时是合法引擎地图文件）
    eve.rpgc.anim.json       精灵动画集契约（帧网格 + 命名剪辑）
    eve.rpgc.effect.json     引擎效果模板契约
    eve.rpgc.skill.json      技能契约（多段动画 + 效果 + 等级覆盖 + 武学/组合技反引用）
    eve.rpgc.event.json      过场事件契约（有序步骤 + 一层分支/并行）
    eve.rpgc.condition.json  条件词表（唯一一份；event 与 world 都 ref 它）
    eve.rpgc.rules.json      战斗规则契约（五行表 / 破绽阈值 / 回合秒数 / 特征表）
    eve.rpgc.world.json      世界契约（时刻分档 / 传送门条件 / 换肤变体）
    eve.rpgc.art.json        武学契约（品级表与每级解锁）
    eve.rpgc.heart.json      心法契约（附加特征与效果）
    eve.rpgc.combo.json      组合技契约（成员 / 五行条件 / 分段 / 合击）
    eve.rpgc.item.json       物品契约（引擎物品定义 + 装备加成 + 使用效果与秘籍）
    eve.rpgc.enemy.json      敌人契约（战斗数值 + 五行归属/弱点 + 掉落 + 精灵）
    eve.rpgc.encounter.json  遭遇契约（敌人 id + 数量 + 整场奖励；投影成引擎数组）
    eve.rpgc.battle.json     战场契约（画布 + 两块阵地 + ≤8 敌位 / ≤5 我位；无引擎投影）
  lib/
    rpgc.nut                 唯一入口：import 全部模块并汇报版本（rpgc.nut:26-37）
    rpgc_json.nut            严格 JSON 编解码 + 规范化 + 指纹
    rpgc_core.nut            Result/诊断形状、id/路径规则、尺寸上限
    rpgc_iso.nut             等距投影、拾取一致性、footprint、屏幕映射
    rpgc_store.nut           文档读写、revision、两个写后端、暂存
    rpgc_project.nut         清单解析与内容索引
    rpgc_host.nut            编辑器 drawer 注册表与帧泵
    rpgc_tilemap.nut         tileset / map 语义门、图层纪律与引用
    rpgc_skill.nut           anim / effect / skill 语义门与引用
    rpgc_event.nut           event 语义门、步骤字段表与引用
    rpgc_systems.nut         rules / world / art / heart / combo / item / enemy / party / encounter / battle
                             语义门与全部跨文档门
    rpgc_battle.nut          战斗系统：公式求值、命中/暴击、五行击破、状态与资源池、回合序、
                             敌方 AI、胜负与结算，以及阵位→屏幕坐标的投影
    rpgc_items.nut           物品系统：定义索引、背包容量与堆叠、装备槽与加成合成、消耗品的 use、
                              掉落进包与存档快照（项目侧复述 inventory 模块，见 08 §7）
    rpgc_validate.nut        六层校验门、跨引用、提交入口
  editors/
    tilemap.editor.json      等距地图编辑器：View
    tilemap.vm.nut           ... 与 ViewModel
    skill.editor.json        技能编辑器：View
    skill.vm.nut             ... 与 ViewModel
    event.editor.json        过场事件编辑器：View
    event.vm.nut             ... 与 ViewModel
    battle.editor.json       战场编辑器：View
    battle.vm.nut            ... 与 ViewModel
    item.editor.json         物品编辑器：View
    item.vm.nut              ... 与 ViewModel
  content/
    tilesets/ maps/ anims/ effects/ skills/ events/ rules/ world/ arts/ hearts/ combos/ items/ enemies/ party/ encounters/ battles/
    tilesets/sbs-*.json      五个全量地形图集，共 2447 块瓦片（见 tilesets/CREDITS.md）
    tilesets/kenney-*.json   四个 Kenney 等距微缩图集，共 809 块瓦片
    tilesets/CREDITS.md      图集素材来源（Screaming Brain Studios / Kenney，CC0）
    anims/CREDITS.md         角色/怪物素材来源与授权；以及为什么这里不放多朝向角色精灵
    anims/enemy-*.png        五张敌人精灵图：四张骸骨（N/E/S/W 行走）与一张 18 种妖物图集
    battles/backdrops/       四张 CC0 战斗背景（1920×1080）+ CREDITS.md；tools/import_battle_backdrops.py 生成
    rules/rules.wuxing.json  全项目唯一一份规则表（五行 / 破绽 / 回合秒数 / 特征表 / 装备槽位表）
    world/world.main.json    时刻分档 + 传送门开启条件 + 换肤变体
    arts/art.taiji-fist.json 太极拳的品级表（1/3/5 品与绝招）
    arts/art.liuhe-blade.json 六合刀的品级表（1/3/5 品与绝招）
    hearts/heart.ice-mind.json 玄冰心法
    combos/combo.twin-sword.json 双剑合璧
    combos/combo.frost-blade.json 冰雷交击（六合刀 × 玄冥神功）
    items/weapon.liuhe-blade.json 六合刀（引擎 ItemDefinition + 装备加成 + 品级要求）
    items/manual.liuhe-blade.json 六合刀谱（秘籍：teaches 同时指 art 与 skill）
    items/potion.heal.json   金创药（消耗品：use.effects 是项目侧半段）
    maps/                    14 张地图：村庄外郊/迷雾森林，中原五城，边地七镇（见 07-world-atlas.md）
    enemies/                 22 个敌人原型（见 09-enemies-and-encounters.md）
    party/party.default.json 默认五人名单：数值 + 五行 + 武学品级（招式表由武学在运行期编译）
    encounters/              14 场遭遇编队，每张地图一场
    battles/                 6 块战场：左上敌阵（≤8 位）与右下我方（≤5 位），外加可选的战斗背景与界面层；见 10-battle-scene.md
  tools/
    rpgc.py                  CLI：validate / check / eval / script / stage / export / status / log / selftest
    modules_check.nut        模块边界 + 全量门 + **121 条文档探针**（112 反例 + 9 正向对照）+ 五套编辑器的
                             View/VM 解析检查、**文件夹绑定检查**、**战斗界面检查**与**物品运行时检查**
                             （`eve run --no-window -r tools/modules_check.nut`）
    build_sbs_atlas.py       从 assets/ 的 CC0 素材包生成精选图集 content/tilesets/sbs-atlas.*
    import_terrain_assets.py 全量导入 assets/ 下的 SBS 与 Kenney 包 → 9 个规则图集
    bake_tilesets.py         把规则图集按需展开成引擎加载器读的 *.baked.json（生成物，已 gitignore）
    build_world_maps.py      由 data/world-regions.json 生成 12 张聚落地图 + 既有地图上的 portal
    import_bestiary_assets.py 下载并校验 CC0 怪物素材 → assets/*/，再合成 content/anims/enemy-*.png
    import_battle_backdrops.py 下载并校验 CC0 战斗背景 → assets/*/，再裁切缩放到 content/battles/backdrops/
    build_encounters.py      把 content/enemies + content/encounters 投影成 data/encounters.engine.json
  docs/
    01-tilemap-editor.md     等距关卡编辑器
    02-skill-editor.md       技能编辑器
    03-event-editor.md       过场事件编辑器
    04-runtime-integration.md 游戏怎么消费这些文档
    05-ai-safe-operation.md  为什么这套设计对 AI 安全
    06-game-design.md        武侠开放世界 RPG 核心系统的游戏设计（世界/武学/五行/心法/组合技）
    07-world-atlas.md        世界图志：中原五城与边地七镇、旅行图、生成器与一图一图集的限制
    08-items-and-equipment.md 物品与装备：引擎物品定义、装备加成、消耗品与秘籍，以及引擎的四处沉默
    09-enemies-and-encounters.md 敌人与遭遇：引擎的 EncounterCatalogue、投影工具、22 个原型与素材来源
    10-battle-scene.md       战斗场景：左上敌阵 / 右下我方的屏幕布局、8 与 5 的容量、六块战场与「引擎没有这一半」
    11-battle-system.md      战斗系统：谁先动手、打多少、什么时候算完；项目侧复述了引擎的哪几个函数
```

**当前落地状态**（本机实测，非推断）：`lib/`、`schema/`、`content/`、`tools/rpgc.py`
与五套 `editors/<id>.editor.json` + `<id>.vm.nut` 全部落地，五个 ViewModel 都通过宿主
使用的原生 Squirrel 编译器。

16 个 kind、共 151 份内容文档（anim=10 art=4 battle=6 combo=2 effect=11 encounter=14
enemy=22 event=2 heart=1 item=25 map=14 party=1 rules=1 skill=28 tileset=9 world=1）。验证入口是：

```bash
cd .  # repository root
<repo>/build/win32-debug/src/engine/eve.exe run --no-window -r tools/modules_check.nut

# 内容文档过六层门。宿主脚本用 import，所以必须指向仓库自建的 eve.exe：
EVE_BIN=<repo>/build/win32-debug/src/engine/eve.exe python tools/rpgc.py validate
```

第二条需要 `eve mcp` 真的监听端口；**本机已经监听不了**（本轮实测，见下面关于
`selftest` 的说明），所以本机实际只用第一条。它跑的是同一个
`RpgcValidate.validateProject()`。

实测结果（本机 `eve.exe`，2026-09-16 构建）：

```text
[modules] gate PASS: 1 warning(s)
[modules] view item:   18 command(s), 47 bind(s) checked against ItemVM
[modules] battle  status: battle.forest-clearing | canvas 1920x1080 | enemy 8 / ally 5
[modules] PASS (0 failure(s))
```

本轮加入物品系统后，同一条命令的检查总数是 **369 条**（`[modules] ok/FAIL` 行数），
0 失败。

那唯一一条 warning 是刻意保留的：`systems.encounter-quest-unregistered` 汇总列出
遭遇结算要求的 `requiredQuestId`（新增项目侧 quest 尚未桥接引擎 QuestDefinition，现有这两个任务也尚无定义）。
把它做成分级 warning 而不是 error，是因为引擎要求 `requiredQuestId` 指向**已注册**的任务，
而注册发生在运行期；门能做的是把必须注册的 id 一次列清楚（见
[`09-enemies-and-encounters.md`](docs/09-enemies-and-encounters.md) §6）。

`tools/modules_check.nut` 是这套工作流自己的自检，除模块边界外还包含 **121 条文档探针**：
79 条把一份**故意写坏**的文档喂给语义门、33 条喂给跨文档门、9 条正向对照，每条都断言
看到预期的诊断 `code`。反例覆盖：五行表断环、特征缺 target、`turns × turnSeconds`
推导不一致、破绽阈值超上限、时刻分档形状/空档、门 portal 形状与重复、未知 moment、
tint 越界与 tint/atlas 混用、品级乱序与超 maxGrade、`elementOverride` 与
`attackElement` 同时声明、`minGrade > maxGrade`、stages 数与 members 不符、actor 槽重复、
地图缺 `terrain` 层 / 层号非 0 / 两个 `moment.*` 层同层号、物品的类别↔槽位耦合
（装备缺槽 / 非装备带槽 / 装备叠堆 / 非装备带加成 / 消耗品缺 `use` / 秘籍缺 `teaches`）、
敌人的 `maxHp ≤ 0` / 空 `displayName` / 招式轮换漏掉 `skillId` / `ai.opener` 不在轮换里 /
掉落重复或区间倒置、遭遇的 `xpReward ≤ 0` / 同一敌人写两条 / 投影成员数超 32 /
结算 id 为空、战场的敌位超 8 / 我位超 5 / 阵地越过中线（x 与 y 分别）/ 阵地出画布 /
阵位越出自己阵地 / 同侧阵位重合 / 阵位 id 重复，
以及跨文档的缺失或重复
`rules`、门指向不存在的对象、地图图层与对象属性上的未知 moment、skill 反引用不一致、
未知特征、绝招未打 tag、同组心法要求蕴含、组合技五行链走不通、合击 clip 不存在、
图集变体不同构、物品槽位不在规则表里、秘籍 teaches 指向别家武学的招式、
物品品级要求高于该武学自己的上限、敌人的五行/弱点属性不在规则表里、敌人弱于自身属性、
破绽上限超过规则表、敌人精灵 clip 不存在、遭遇所在图不在敌人 `habitat` 里、
**战场容量装不下它承接的遭遇、遭遇没有任何战场承接、同一场遭遇被两块战场承接**。

物品那一族探针尤其值得看一眼，因为它们钉住的全是引擎**不报错**的地方：
`Item.cpp:48` 把 `maxStack <= 0` 悄悄改成 1（这条由 schema 的 `minimum: 1` 拦下，
探针因此断言 `validate.schema` 而不是一条语义 code），而装备加成的 `op` 拼错时
`AttributeSystem::addModifier` 只是提前 `return {}`（`AttributeSystem.cpp:66-69`），
`syncEquipModifiers` 连这个返回值都丢掉（`EquipmentSystem.cpp:73`）。
`equipSlot` 那一条本轮改写过：它**确实会被比较**（`Equipment.cpp:108-111`），
引擎不做的只是拿它去建槽位，所以拼错的后果是「两边各自漂移」而不是「一定穿不上」。

### 文件夹绑定检查（65 条）

同一份脚本还有一族 `folder.*` 检查，盯的是"编辑器读的是项目文件夹"这件事本身：

- **正向 55 条**（`folder.<kind>.*` + `folder.<editor>.*`）：清单目录与磁盘一致、
  `folder()` 的 label/count/ids 与目录一致、ViewModel 的列表槽位**等于磁盘上的目录内容**、
  当前选中项确实是列表里的一行、存在重扫命令、视图里**没有任何 `open*` 命令**、
  文档列表带 `onChange`。
- **负向 10 条**（`folder.detector.*` + `folder.stale.*`）：前四条用人工构造的节点证明
  两个探测器**确实会失败**（一个永远答 ok 的检查和一个什么都不做的检查无法区分）；
  后六条证明 `folder()` 修复过期索引这件事**真的会发生**——先让缓存滞后
  （`cached 14 vs on disk 6`），再断言 `folder()` 之后索引与磁盘一致、`loadById` 接受那一行。

> **`tools/modules_check.nut` 里的新检查必须放进函数。** `-r` 脚本编译进 `load.nut`
> 的作用域，所以每个顶层 `local` 都和 `load.nut` 自己的局部变量挤在**同一个**帧里，
> 而 EveScript 编译器的上限约 250 个局部变量。超了不一定报错：本轮实测，
> 再加六个顶层 `local` 就让 VM 在 `SQVM::Return`（`sqvm.cpp:472`，
> `SQObjectPtr::operator=`）里踩了访问违例，**而且是时有时无的**；
> 同样两段代码放进小脚本里跑完全正常。写成一个函数，局部变量就进了自己的帧，
> 不占那份预算。把超限逼出来时的报错是
> `internal compiler error: too many locals`。

### 战斗界面检查（23 条）

`battle` 文档多了两个**可选**层：`background`（画出来的背景）与 `ui`（右下人物 HUD、
左边操作环）。人物 HUD 是**一排头像、血条在头像底下**，不是「头像左 / 数字右」的五行
堆叠。它们和战场几何一样**没有任何下游**——一份把 HUD 压在怪身上的文档渲染得好好的，
运行期一句话都不说。所以规则全部写在语义门里，探针里正反两面都在：

- **正向 2 条**：带 `ui` 的完整战场被接受、`background` 路径被接受。
- **负向 21 条**：HUD 不在右下、操作环越到中线右边、两者出画布、环压住敌阵、
  头像数超 5 / 头像数盖不住阵位、头像横排宽过面板、头像条没给血条留高度、
  血条溢出预算、条的 id 重复或非法、**条的名字对不上规则文档里的资源池**
  （`systems.battle-ui-bar-unregistered`，六份文档里的 `mp` 就是被它抓到的）、
  键数超 8、键越出环、两键重叠、键 id 重复或非法、`background` 为空。
- **另外 3 条**不做文档校验、只断言**这套素材**是通的：声明过的背景路径都能解析到
  磁盘上真实存在的文件（`battle-backdrop.files-exist`），加上一条"存在性判断确实
  会说不"的对照（`detector-sees-missing`）。运行期 `newTextureFromFile` 会吞掉
  缺文件，不查的话场景只是安静地不画背景。

这一族探针**逼掉了四条本来就写好的检查**，因为它们证明不了自己会失败：
「两个面板重叠」（两条半屏规则已蕴含不可能）、「HUD 压住敌阵」（同上）、
「面板零面积 / 环零半径」（schema 的 `minimum: 1` 先拦）、「`ui` 缺面板」
（schema 标了 `required`）。**一条永远不会点火的门等于没有门**，所以它们被删掉了，
理由写在 `RpgcSystems.battleUiDiagnostics` 上方的注释里。同样地，头像数 / 条数 / 键数的
**上界**刻意没有写成 schema 的 `maximum` / `maxItems`，否则语义门就跑不到。

### 物品运行时检查（53 条）

`lib/rpgc_items.nut` 是这棵树里第一个**明确因为引擎够不着而存在**的库：`inventory`
模块在清单里只有 `SCRIPT` 没有 `SLOT`（`cmake/module_manifest/core_foundation.cmake:105`），
所以 `eve.Inventory` 根本不在 `eve` 表上——这不是推断，探针第一条断言的就是它不在
（`items.inventory-unbound`、`items.rpg-unbound`）。docs/08 §7 原来那段
`eve.Inventory().registerItemsFromJson(...)` 因此是不能运行的代码，本轮已改写。

- **正向 36 条**：定义全部加载（数量与目录一致）、槽位词表来自 `rules.equipmentSlots`、
  续堆/开新槽、`maxWeight = 0` 表示不限、属性合成的加/百分比/倍率与优先级顺序、
  装备换下旧件、卸下回包、`use` 扣一件并把效果列表交出去、秘籍 `teaches`、
  掉落进包、快照往返、`battleCommands` 的形状、战斗里提交一次物品命令后
  **状态真的挂上了、回合真的花掉了**（`items.battle-turn-spent`：单挑时对手的回合在
  `advanceTurn` 里跑完，`pending` 可能转回同一人，所以这条盯的是回合计数器——
  实测 `round=2`），以及**装船的 `party.default.startingItems` 真的能全部放进背包**
  （`items.starting-kit-resolves` / `-fits`，因为 `main.nut` 开局就是照它播种的）。
- **负向 17 条**：槽位不够（`items.no-slot`）、超重（`items.over-weight`）且**部分入包要如实返回**、
  未知容量策略**失败关闭**（`items.unknown-policy`）、未知物品、非装备不能穿、
  背包里没有、槽位词表外的槽、空槽卸不下、不认识的 `op` **什么都不加但要报出来**
  （`items.unknown-op-is-reported`）、没有 `use` 的物品用不了、背包为空、
  掉落放不下要报 `lost`、快照指向不存在的物品要整份拒绝、战斗命令缺效果要拒绝
  **且不花回合**（`items.battle-refusal-keeps-turn`），再加上 `party.startingItems` 的
  重复 / 非法 id / `count = 0`（第三条断言 `validate.schema`，钉住真正生效的那一层）。

> **`equipStats` 的三条合成探针用的是合成文档，不是内容树。** 内容里的装备只有 `add`
> 一条加成，证明不了「先加后乘」「priority 排序」「`multiply N` 是倍数」这三件事，
> 所以探针自己造了三份只存在于内存里的物品定义。断言值直接取自
> `computeAttributeValue`：`(100 + 10) × (1 + 1.0) = 220`、`multiply 2.0` → `×2`、
> `priority` 让 `override 5` 排在 `clamp_min 50` 之后（不排序会得到 50）。
> **必须用仓库自建的 `eve.exe`，不要用 SDK 里那份。** `lib/` 与 `mcp.nut` 全靠
> `import`，而 `dofile` / `EditorHost::runSquirrel` 只有先 `ScriptCompiler::compileBuffer`
> 再 `instantiateDependencies` 才能实例化依赖；这条修改已落在本工作树
> （`src/modules/filesystem/physfs/FileApi.cpp:51-106`）。已发布的 SDK 二进制
> （本机 `eve-sdk/win32/bin/eve.exe`，v0.5.0 / 2026-09-14 构建）早于这次修改：
> `eve run` 在 `load.nut:767` 报 `invalid type tag`，`eve mcp` 报
> `MCP host script load failed: error: runtime failed`。两者都与内容无关——
> 一个只含一条 `import` 的空脚本即可复现。仓库自建的
> `build/win32-debug/src/engine/eve.exe` 两条路都正常，所以下面的命令一律用
> `EVE_BIN` 指过去。

> **`eve mcp` 的 eval 入口靠根表门面。** `eve_eval` / `eve_run_script` 以 root 表为
> 运行环境，而 `import` 进来的名字是模块局部的。`mcp.nut` 因此在加载后调用
> `RpgcPublishRoot()` 把工具链对象发布到根表，`tools/rpgc.py` 与
> `docs/05-ai-safe-operation.md` 里那些 `RpgcValidate.reportJson(...)` 形状的调用才成立。
> 赋值必须走 `getroottable()`：直接写 `RpgcHost <- RpgcHost` 会与模块作用域的同名槽
> 冲突，宿主只报 `compile failed`。

上面这些结论里，凡是需要**活宿主**的，都可以被这条命令重新验证：

```bash
EVE_BIN=<repo>/build/win32-debug/src/engine/eve.exe python tools/rpgc.py selftest
```

`selftest` 会实测：启动门、五套编辑器与 ViewModel 是否注册、每个 drawer 的 `status()`
是否抛错、**View JSON 里声明的每一条 `command`** 是否都能从 `eve_run_script` 调用、
store 后端、校验门接受好文档 / 拒绝未知字段且不暂存、以及 `stage → takePendingJson → export`
的往返。命令清单直接从 `editors/*.editor.json` 推导，所以按钮改名时不会与文档脱节。

> **本机跑不了 `selftest` / `validate`：`eve mcp` 不监听端口。** 本机实测（本轮）：
> `eve mcp --port <p> --root workflow/rpg-classic` 创窗、建好 Vulkan、打完
> `hotreload: watchTree`（约 3 s）之后**再也没有输出**，`rpgc.py` 轮询到超时，
> 报 `rpgc: engine did not start listening.`（`--wait 180` 同样超时）。
> 因此 `validate` / `check` / `eval` / `script` / `stage` / `export` / `selftest`
> 这条 TCP 路线在本机全部走不通。历史记录里那次
> `selftest PASS (8/8)、42/42 条声明命令可调用`（tilemap + skill + event 三套）
> 来自宿主还肯监听的时候，本轮**无法复现**，所以不往上加第四套的数字。
>
> 替代路径是同一次调用的 Squirrel 入口——`tools/modules_check.nut` 直接跑
> `RpgcValidate.validateProject()`，也就是 `validate` 命令本身跑的那一个函数，
> 外加本轮新增的**静态** View/VM 解析检查（不需要宿主，就能发现点不动的按钮和
> 永远不刷新的字段）：
>
> ```text
> [modules] gate PASS: 1 warning(s)
> [modules] view tilemap: 19 command(s), 22 bind(s) checked against TilemapVM
> [modules] view skill:   11 command(s), 29 bind(s) checked against SkillVM
> [modules] view event:   12 command(s), 33 bind(s) checked against EventVM
> [modules] view battle:  10 command(s), 18 bind(s) checked against BattleVM
> [modules] PASS (0 failure(s))
> ```
>
> 四套共 52 条声明命令，静态解析全部命中。GUI 按钮走 C++ 派发、Agent 走 EveScript
> 编译器，两条路的成功条件并不相同，这正是 `selftest` 要盯住的东西：实测中改掉了四个
> 撞名的命令，见 [`docs/05-ai-safe-operation.md`](docs/05-ai-safe-operation.md) §3.6。

## 内容 kind 表

清单是权威（`workflow.json`）；下表是它的展开。

| kind | 目录 | schema | 负责模块 | 是什么 |
|------|------|--------|----------|--------|
| `tileset` | `content/tilesets/` | `eve.rpgc.tileset` | `RpgcTilemap` | Tiled-flat 图集。`version: 2` 存规则（网格 + 尺寸 `runs` + `classes`），逐块 `region`/`pivot` 由 `RpgcTilemap.tilesOf` 重放得出；`version: 1` 逐块写出，可直接给引擎的 `tilesets[].source` |
| `map` | `content/maps/` | `eve.rpgc.map` | `RpgcTilemap` | 等距关卡：宽高、tile 尺寸、renderSpacing、origin、图层数据、对象层。**同时是合法引擎地图文件**。基础层必须叫 `terrain` 且 `layer == 0` |
| `anim` | `content/anims/` | `eve.rpgc.anim` | `RpgcSkill` | 精灵动画集：帧网格 + 命名剪辑（帧列表、fps、loop、事件） |
| `effect` | `content/effects/` | `eve.rpgc.effect` | `RpgcSkill` | 引擎效果模板：durationPolicy/duration/period/stackPolicy/maxStacks/modifiers/extra |
| `skill` | `content/skills/` | `eve.rpgc.skill` | `RpgcSkill` | 技能：玩法半段（targetType/costs/effects/damage）+ 表现半段（多段动画 + 等级覆盖）+ 反向声明 `art` / `combo` |
| `event` | `content/events/` | `eve.rpgc.event` | `RpgcEvent` | 过场事件：trigger + 有序步骤，一层 branch/parallel 嵌套 |
| `rules` | `content/rules/` | `eve.rpgc.rules` | `RpgcSystems` | 战斗规则：五行相生相克、破绽阈值、回合秒数、特征表。**全项目唯一一份**，art/heart/combo 都读它 |
| `world` | `content/world/` | `eve.rpgc.world` | `RpgcSystems` | 开放世界：时刻分档、传送门开启条件、换肤变体。**唯一一份** |
| `art` | `content/arts/` | `eve.rpgc.art` | `RpgcSystems` | 武学：品级表（`maxGrade` 自声明）与每级解锁的招式 / 绝招 / 特征 / 被动 |
| `heart` | `content/hearts/` | `eve.rpgc.heart` | `RpgcSystems` | 心法：给已有招式附加特征与效果，不给新招式 |
| `combo` | `content/combos/` | `eve.rpgc.combo` | `RpgcSystems` | 组合技：2..4 名成员按序出手 + 合击收尾 |
| `item` | `content/items/` | `eve.rpgc.item` | `RpgcSystems` | 物品：引擎物品定义（`ItemRegistry` 解析的九个键）+ 装备加成（`EquipmentSystem` 持有的那组 stat）+ 消耗品 `use` 与秘籍 `teaches`（项目侧半段）。`category` 是封闭集合，`equipSlot` 必须落在 `rules.equipmentSlots` 里。运行时是 `lib/rpgc_items.nut`——本树的 `inventory` 模块只有 `SCRIPT` 没有 `SLOT`，`eve.Inventory` 根本不在 `eve` 表上（[`docs/08`](docs/08-items-and-equipment.md) §7） |
| `enemy` | `content/enemies/` | `eve.rpgc.enemy` | `RpgcSystems` | 敌人原型：`combat` + `skillId` + `displayName` 是引擎 `EncounterMemberDefinition` 的那一半（`EncounterCatalogue.cpp:135-158`），`sprite`/`drops`/`ai`/`habitat`/`lore` 是项目侧半段。**攻击力与血量只在这里存在一份**，遭遇只引用 id + 数量 |
| `party` | `content/party/` | `eve.rpgc.party` | `RpgcSystems` | 我方名单：`combat` 与敌人同形，外加五行归属与 `art` + `grade`。**招式表不写在这里**——运行期由武学文档的品级编译出来（`06-game-design.md` §2.4），所以名单里没有会和武学漂移的副本。名单人数 ≤ 5（`RpgcSystems.maxBattleAllySlots`，全项目唯一一份）。`startingItems[]` 是开局背包，由 `RpgcItems` 读（[`docs/08`](docs/08-items-and-equipment.md) §7.5）。引擎没有任何我方内容类型，门是唯一的读者 |
| `encounter` | `content/encounters/` | `eve.rpgc.encounter` | `RpgcSystems` | 遭遇编队：敌人 id + `count` + 整场奖励与任务结算，由 `tools/build_encounters.py` 投影成引擎 `replaceEncountersFromJson` 读的严格数组。引擎的加载器是**原子**的：一条坏文档会让全部遭遇一起消失 |
| `battle` | `content/battles/` | `eve.rpgc.battle` | `RpgcSystems` | 战斗场景：设计空间画布 + 左上敌阵（≤ **8** 位）+ 右下我方（≤ **5** 位）+ 承接的遭遇。**引擎没有任何对应类型，也没有投影产物**——`src/modules/rpg` 里没有战场/阵型/阵位，所以六层门是唯一会看这份文档的东西（见 [`docs/10-battle-scene.md`](docs/10-battle-scene.md)） |

`RpgcValidate.moduleFor`（`lib/rpgc_validate.nut`）按清单里的 `module` 字段把
kind 分派到语义门模块。四个模块（`RpgcTilemap` / `RpgcSkill` / `RpgcEvent` /
`RpgcSystems`）都是静态 `import`，所以「模块没加载」这种状态不存在了：清单里写了
`module` 却对不上这四个名字，`RpgcValidate.moduleMissing` 会给出
`validate.unknown-module` 并**让门失败**，而不是静默跳过那一层的语义门与引用门。
所以新增 kind 时必须同时给出 `module` 与实现。

`RpgcSystems` 一个模块服务十个 kind。跨文档检查按**模块**去重调用一次
（`RpgcValidate.validateProject`），不是按 kind：否则 `RpgcSkill` 的三条
skill-vs-anim 检查会各报三遍，`RpgcSystems` 的会各报九遍。

`rules` 与 `world` 是**单例**（各恰好一份）。两份就是同一张表的两个权威，
零份则所有依赖它们的检查会在空表上静默通过——两种情况都由门报
`systems.no-rules` / `systems.many-rules`。

## 六层校验

`RpgcValidate` 是唯一的提交入口。它的分层顺序是有意的：越早的层越便宜、越机械，
越晚的层越接近语义；任何一层报 error，后面的层不会执行。

| 层 | 实现 | 抓什么 |
|----|------|--------|
| 0 严格 JSON 解析 | `rpgc_json.nut`（`parse`） | 重复键、尾随逗号、注释、`NaN`/`Infinity`、裸控制字符、非法/未闭合转义、前导零、`+` 号、无数字的 `-`、指数溢出、尾随垃圾、深度超 64 |
| 1 Eve Schema v1 | `eve.Schema().validateJson`（`rpgc_validate.nut`） | **权威层**：字段类型、必填、枚举、数值区间、数组长度、`additionalProperties:false` 的未知字段拒绝、整 schema `ref`。用的是引擎自己的 C++ 校验器，不是复刻 |
| 2 文档语义门 | `RpgcTilemap` / `RpgcSkill` / `RpgcEvent` / `RpgcSystems` 的 `semanticDiagnostics` | 图集：GID≥1、重复 GID、region/pivot/footprint 形状；地图：图层 id 唯一、对象名唯一、属性名唯一、data 长度、GID 范围、有无 spawn、拾取一致性、图集与地图的 firstGid/tile 尺寸一致、**基础层必须是 `terrain`@layer 0、`moment.*` 层的 `layer` 不重复**；技能：剪辑 id 唯一、事件帧升序且在范围内、sheet 帧在网格内、等级行升序唯一、伤害公式词法检查；事件：步骤字段表、duration>0、facing 非零且只占一轴、嵌套深度 ≤2；规则：`generates`/`overcomes` 必须是覆盖全部元素的**单环**、特征 kind 与 target 合法、破绽阈值 ≤ max、**`breakEffects[].turns × clock.turnSeconds` 必须等于该 effect 的 `duration`**；世界：时刻分档形状/空档/小时范围、门 `portal` 是 `<map>/<object>`、门唯一、变体 tint 四分量与 0..1、tint/atlas 不混用；武学：品级升序唯一且 ≤ `maxGrade`、requirement 有 kind 且非负、修饰符有属性；心法：`elementOverride` 与 `attackElement` 特征不得同时声明、`requires.minGrade ≤ art.maxGrade`；组合技：`stages.len()` 落在 `members.min..max`、actor 槽不重复；物品：`category` 与 `equipSlot` 的耦合（装备必须有槽、非装备不得有槽、装备不得叠堆）、`equipStats` 只允许出现在装备上且每条要有 `attribute`、消耗品必须给 `use.effects` 且不得为空、秘籍必须有 `teaches` 且只允许 `manual` 声明；**名单**：`startingItems[].itemId` 的形状与重复（`count ≥ 1` 交给 schema，语义门不重写一条永远触发不了的检查）；敌人：**`combat.maxHp > 0`（引擎用的是严格下限，而 Eve Schema v1 没有 `exclusiveMinimum`）**、`displayName` 非空且 ≤512 字节、`skills` 必须包含 `skillId`、`ai.opener` 必须在 `skills` 里、掉落不得重复且 `max ≥ min`、单条落败不会拖垮别人的 id 形状；遭遇：**`xpReward > 0`（同样是严格下限）**、`xpGrowth ≥ 1`、同一敌人不得出现在两条 `members` 里（投影的成员 id 由敌人 id 派生，引擎拒绝重复 id）、`count` 之和 ≤ 32（schema 只能限住**条目数**，限不住投影后的成员数）、五个结算 id 非空；战场：id 与 `displayName` 非空、canvas 为正、两块阵地有面积且在画布内、**两块阵地各在正确的一半（x 与 y 两个轴都要满足）**、阵位 id 合法且同侧不重复、阵位落在自己阵地内、同侧阵位不落在同一点、**敌位 ≤ 8 / 我位 ≤ 5（刻意不写成 `maxItems`：schema 失败会让语义门根本跑不到，那个检查就成了死代码）**、`encounters[]` 的 id 形状与不重复 |
| 3 跨文档引用 | `RpgcValidate.validateReferences` + 各模块 `references()` | 悬空引用。地图 → tileset（`tilesets[0].source`）；技能 → effect（`/effects/i`）与 anim（段与等级段的 `/anim`）**以及 `art` / `combo` 反引用**；事件 → map（trigger/load_map/consume_object/condition）与 anim（`play_animation`）；规则 → effect（`breakEffects[].effect`）；世界 → map（门的 portal 与 `object_consumed` 条件）与 tileset（变体的 `tileset` / `baseTileset`）；武学 → skill（`skills[]` / `ultimates[]`）；心法 → effect（`grants.effects[]` / `onHit[].effectId`）与 art（`requires.artId`）；组合技 → skill（`stages[].skill` / `finish.skill`）与 anim（`finish.anim.anim`）；物品 → effect（`use.effects[]`）与 art / skill（`teaches.art` / `teaches.skill` / `requires.artId`）；敌人 → skill（`skillId` / `skills[]`）、map（`habitat[]`，注意方向是**敌人指向地图**）、anim（`sprite.anim`）、item（`drops[].itemId`）；遭遇 → enemy（`members[].enemy`）与 map（`map`）；战场 → encounter（`encounters[]`）、**名单 → item（`startingItems[].itemId`）** |
| 4 模块额外检查 | `module.extraDiagnostics()`，**按模块去重调用一次** | schema 与引用门都表达不了的跨文档约束。原有：技能段与事件 `play_animation` 引用的 clip 必须真实存在。新增（`rpgc_systems.nut`）：`rules`/`world` 必须恰好一份；门的 portal 对象必须在目标地图里存在且类型为 `portal`；地图 `moment.*` 层与对象 `moment` 属性必须命中 `world.clock.moments`；武学列出的 skill 必须反向声明同一 `art`，绝招必须带 `ultimate` tag，特征必须在规则表里；心法引用的特征必须存在、`elementOverride` ∈ 五行表、同一 `exclusiveGroup` 内相同 `artId` 的心法构成蕴含关系要报错；组合技的 skill 必须反向声明同一 `combo`、五行链必须能在 `generates`/`overcomes` 上走通、合击 clip 必须存在；**图集换肤变体必须与基准图集 GID 逐项同构**；物品的 `equipSlot` 必须落在规则表的 `equipmentSlots` 里、秘籍同时点名 art 与 skill 时该 skill 必须属于那门 art、`requires.minGrade ≤ art.maxGrade`；**敌人的 `element` / `weakElements` / `weakStyles` 必须落在规则表的 `elements` / `weakStyles` 里（引擎按字符串查表，拼错不是「倍率不对」而是「没有倍率」）、敌人不得弱于自身属性、`breakMax ≤ rules.break.max`、`sprite` 的 `{anim, clip}` 必须命中真实剪辑；遭遇所在图必须在该场每个敌人的 `habitat` 里**（`habitat` 与 `map` 是对同一件事的两句陈述，门把它们逼到同一个答案）。另有一条**汇总 warning** `systems.encounter-quest-unregistered`：遭遇要求的 `requiredQuestId` 必须由运行期先注册，而项目侧 quest 尚未桥接引擎任务注册，门保留此汇总诊断。**战场**：承接的每场遭遇投影后的出场人数必须 ≤ 该战场的敌位数（`systems.battle-capacity`），并且**每场遭遇恰好被一块战场承接**——0 块是「这场战斗没有布局」，2 块是「同一件事有两个答案」（`systems.encounter-without-battle` / `systems.encounter-hosted-twice`）；战场自己也不能一场都不承接（`systems.battle-no-encounter`） |
| 5 失败关闭 | `rpgc_validate.nut` | `eve.Schema()` 模块不存在时**直接报错并拒绝**，而不是跳过校验；`registerSchemas` 找不到 schema 文件同样报错；kind 写了 `module` 却对不上任何模块也报错。任何一层没跑，门就是失败 |

**条件词表只有一份。** `eve.rpgc.condition` 是 `event` 的 `branch` 条件与 `world` 的
门条件共同 `ref` 的 schema，`RpgcSystems.conditionDiagnostics` 是它们共同的语义实现
（`RpgcEvent.conditionDiagnostics` 现在只是转调）。两处各写一份枚举正是两套语法开始
漂移的方式，所以这里刻意只有一处。

提交路径只有两条，且都经过全部门：
`RpgcValidate.commitDocument(path, document)` 与
`RpgcValidate.commitRaw(path, text)`。前者先规范化编码再交给后者；
后者按路径反推 kind（`kindOfPath`，最长目录前缀优先），跑 layer 0+1+2，
**只有零 error 才调 `RpgcStore.stage`**。

## 文档之间怎么组合

四种编辑器共享同一份内容树，靠**引用**互相咬合，而不是靠导入导出。
`06-game-design.md` 的七个系统接在同一个图上：规则表在根、世界文档管地图与时刻、
武学 / 心法 / 组合技都落在既有的 `skill` 上。`08-items-and-equipment.md` 的 `item`
接在 `effect` / `art` / `skill` / `rules` 上，但不引入第五个权威：装备加成落在
`rules.equipmentSlots`，教学落在已经被 `art` 反向声明的 `skill` 上。
`10-battle-scene.md` 的 `battle` 接在 `encounter` 上，方位是**战场指向遭遇**：
遭遇说「打谁、几个」，战场说「站在屏幕的哪里」，两者互不重复。

```text
tileset ──(map.tilesets[0].source)──▶ map ──(event.steps[].mapId)──▶ event
   ▲                                    ▲                              │
   │                                    │                              │
   └── GID / pivot / walkable / cost ────┘                              │
                                                                        │
anim ──(skill.presentation.segments[].anim + clip)──▶ skill ◀───────────┘
                                                       ▲  (event.steps[].anim + clip)
effect ──(skill.effects[])──▶ skill
   ▲
   └──(rules.breakEffects[].effect)──▶ rules ◀── art.grades[].skills[]
                                          ▲            │
                                          │            └─(skill.art 反引用)
              heart.grants.traits/effects │
                     └──(requires.artId)─▶ art
   world ──(gates[].portal)──▶ map
      └──(styleVariants[].tileset/baseTileset)──▶ tileset
      └──(clock.moments)◀── map 的 moment.* 层与对象 moment 属性
   combo.condition.elements ──▶ rules.generates / overcomes
   combo.stages[].skill / finish.skill ──▶ skill（combo 反引用）
   item.use.effects[] ──▶ effect
   item.teaches.art / teaches.skill ──▶ art / skill
   item.requires.artId ──▶ art
   item.equipSlot ──▶ rules.equipmentSlots
   party.startingItems[].itemId ──▶ item（开局背包；玩家侧的名单指向物品）
   battle.encounters[] ──▶ encounter（战场指向遭遇；一块战场可承接多场，
                          背景因此取自 encounter.map 而不是战场文档）
```

- **地图指向图集**：`map.tilesets[0].source` 是相对地图目录的路径（如
  `../tilesets/sbs-overworld.json`）。`RpgcTilemap.atlasFor` 把它规范化成项目相对路径再读；
  `references()` 把 stem 作为 tileset id 交给引用门。因为引擎自己就认
  `tilesets[].source`，这条引用不需要任何转换步骤。
- **武学 / 心法 / 组合技都落在既有 `skill` 上**，不引入新的表现层：
  `art.grades[].skills[]` 指向某品级自己的 skill 文档，该 skill 必须反向声明 `art`；
  `combo.stages[].skill` 与 `finish.skill` 同理必须反向声明 `combo`。
  反向声明就是防串门：只改一边会立刻被门抓住。
- **规则表是根**：`rules` 的五行表被 combat 半边共用——心法的 `elementOverride` 要对
  `elements` 求值，组合技的五行链要在 `generates`/`overcomes` 上走通，`breakEffects`
  是 turn→second 推导的唯一出处。两处各写一份表正是漂移的来源，所以 `rules` 恰好一份。
- **技能指向动画与效果**：`presentation.segments[]` 与 `presentation.levels[].segments[]`
  各有一个 `{anim, clip}`；`skill.effects[]` 是 effect id 列表。
- **事件指向地图与动画**：trigger 的 `mapId`/`targetMap`，以及 `load_map`/`consume_object`
  /`object_consumed` 条件里的 `mapId`，`play_animation` 的 `{anim, clip}`。

三者**不需要同时打开**。每一项都是独立文档，改一个不需要重建另一个；这也是为什么
AI 可以一次只改一份文档，而校验门能立刻告诉它有没有打破别处。

## 持久化：为什么不能直接写盘

这是整个设计里最容易做错的一点，必须说清楚。

**Squirrel 在 `eve mcp` 宿主里不能写项目文件。** 两个已核实的事实：

1. `installScriptFileApi`（[`src/modules/filesystem/physfs/FileApi.cpp:129`](../../src/modules/filesystem/physfs/FileApi.cpp)）
   用只读的 PhysFS 句柄替换了 stdlib 的 `file()`，**没有写方法**；
2. `Filesystem::setupWriteDirectory()` 需要先 `setIdentity()`，写目录落在**引擎存档目录**，
   永远不是项目根；在 MCP 宿主里它直接报失败。

因此 `RpgcStore` 只有两个**可观测**后端，由 `probe()`（`lib/rpgc_store.nut:42-86`）决定：

| 后端 | 何时 | 行为 |
|------|------|------|
| `engine-save` | `setupWriteDirectory()` 成功 | `save()` 走 `eve.Filesystem().writeTextAtomic(path, text)` 原子写；文档落在引擎存档目录。这是 `examples/terrain-editor`、`examples/scene-editor`、`examples/level-designer` 同一套约定 |
| `deferred` | 宿主里没有 writer（**MCP 宿主的常态**） | 文本暂存在 VM 里（`pending` 表），`save()` 返回一个 `store.deferred` warning 并在 `value` 里给 `persisted = false`——**任何调用方都不可能把暂存误认为落盘** |

`deferred` 下唯一的落盘路径是：

```text
# 编辑器（或 Agent）提交，动作是「校验 + 暂存」
eve_eval  RpgcValidate.commitDocument("content/maps/village.json", <document>)
# 或经宿主脚本
eve_eval  RpgcCommit("content/maps/village.json", <document>)
# 或经 CLI
python tools/rpgc.py stage content/maps/village.json /tmp/village.json

# Agent 读回暂存内容（结构化）
eve_eval  RpgcStore.takePendingJson()      # JSON: [{path, text, fingerprint}, ...]

# 唯一的项目写：原子替换
python tools/rpgc.py export [--dry-run]
```

`export` 在目标目录建临时文件、写入、再 `os.replace` 原子替换（`tools/rpgc.py:437-455`），
成功后调 `RpgcProject.invalidate()` 让内容索引立刻看到新文件。`takePendingJson()`（以及它包装的
`takePending()`）**不清空**暂存，
所以一次导出失败可以重试；`RpgcStore.clearPending()` 才是显式丢弃。

两条硬约束：

- **校验不过就不暂存。** `commitRaw` 只有在 layer 0+1+2 全无 error 时才 `stage`
  （`lib/rpgc_validate.nut:337-350`）。暂存区里不可能存在一份没被门放行的文档。
- **暂存是会话状态。** 保存 `mcp.nut` 会重载它和整条 `import` 依赖闭包，暂存被一并清掉。
  改库之前先 `export`。（库里不再有 `RpgcWorkflow.reload()`：模块只实例化一次，
  热重载由 `lib/*.nut` 的 `import` 依赖图决定，不再需要手工维护的文件名列表。）

另外，写之前编辑器会做一次 `RpgcStore.checkRevision(path)`（`:231-243`）：如果磁盘内容
自本次读取后被别人改过，返回 `store.stale-revision` 并拒绝暂存，避免 AI 的编辑静默覆盖人工编辑。

## 明确不提供的东西

- **没有"打开文档"这个动作。** 五个编辑器都不弹文件对话框、不让你输入路径：
  面板绑定的就是 `workflow.json` 里那个 kind 的目录，列表是它的内容，选中即载入。
  这是刻意的——"当前有哪些文档"必须只有一个真源（清单里的目录），多一个"打开"手势
  就多一个可以和磁盘不同步的状态。`tools/modules_check.nut` 把"没有 open 手势"
  写成断言（`folder.<editor>.no-open-gesture`），因为它是**功能的缺席**，
  而缺席不写下来就会被下一个人重新加回去。
- **没有把五个编辑器合成一个 IDE。** 人用入口是五个独立的 `eve run` 应用
  （`apps/tilemap` / `apps/skill` / `apps/event` / `apps/battle` / `apps/item`），各自只开一块面板。
  View + ViewModel 仍是 `editors/<id>.editor.json` + `.vm.nut`。
- **`rules` / `world` / `art` / `heart` / `combo` 目前没有编辑器抽屉。**
  `06-game-design.md` §7 的落地清单把「编辑器抽屉」列为每个新 kind 的一环，这一环
  对这五类**尚未实现**：它们现在靠直接编辑 + 校验门，而不是靠面板。门、schema、引用、
  文档与示例内容都已就位，所以缺的是编辑体验而不是正确性——`RpgcSystems` 的语义门与
  跨文档门对人工和 AI 编辑同样生效。`battle` 与 `item` 是**有**抽屉的那两个：
  前者因为「把 8 个位置摆在哪」本身就是空间工作，后者因为
  「类别 ↔ 槽位 ↔ 加成 ↔ 使用效果」四条耦合写在字段列表里最容易看漏。补齐其它任何一个只需
  `editors/<id>.editor.json` + `editors/<id>.vm.nut`，再到 `apps/` 下加一个入口
  （`RpgcApp.openEditor` 不需要注册表，它按 `<id>` 找那两个文件）。
- **运行时文档门不解析图片。** 新工具 `toolkit assets` 额外检查文件存在性和 PNG 头尺寸（不完整解码）；以下限制描述原有运行时门。 `tileset.image` / `anim.image` 是字符串，工作流不检查文件是否存在、
  不检查尺寸是否匹配——这条限制在 [`docs/01-tilemap-editor.md`](docs/01-tilemap-editor.md)
  「引擎不检查、工作流才检查」一节里逐条说明。
- **图集存规则，不存元素。** `tileset` 文档的 `version: 2` 只写图集网格与有序尺寸
  `runs`；每块瓦片的 `region` 由确定性的货架打包重放得出，`pivot` 由 `classes` 的
  `pivotRule` 现算。3256 块瓦片因此是 163 KB 而不是 1.5 MB，且运行时不留逐块表——
  `RpgcTilemap.tilesOf` 按需算。引擎加载器只认逐块 `tiles[]`，所以需要时用
  `tools/bake_tilesets.py` 展开成 `*.baked.json`（生成物，已 gitignore）。
  细节与验证范围见 [`content/tilesets/CREDITS.md`](content/tilesets/CREDITS.md)。
- **库本身不运行游戏。** 校验与文档形状在 `lib/`；可玩投影在根目录 `main.nut`
  （`eve run .`）。**例外是 `lib/rpgc_battle.nut` 与
  `lib/rpgc_items.nut`**：它们都是纯计算的（不碰纹理、不碰鼠标、不读工程文件），
  所以既能被 `-r` 脚本无头驱动，也能被 `main.nut` 每帧驱动——这条纪律不是风格问题，
  是探针能无头跑的前提。完整对话树仍见
  [`docs/04-runtime-integration.md`](docs/04-runtime-integration.md)，战斗规则见
  [`docs/11-battle-system.md`](docs/11-battle-system.md)，物品规则见
  [`docs/08-items-and-equipment.md`](docs/08-items-and-equipment.md) §7。
- **不做版本迁移。** 每份 schema 的 `version` 固定为 1，未知字段一律拒绝；
  没有 migration 链，也没有兼容读取旧版本的代码。唯一例外是 `tileset`：它接受
  `version: 1`（逐块写出，引擎形态）与 `version: 2`（规则形态），两者是不同的
  文档形状而不是同一形状的两代，`RpgcTilemap.tilesOf` 同时读得了。
- **不做第二份规则。** CLI 与库都不重新实现文档规则；规则只存在于 `schema/` 与 `RpgcValidate`。

共享剧情运行时已开始接入主游戏：`T` 打开向导委托，空格/Enter推进对话，数字键选择，`L`切换语言，Esc取消。可独立运行 `python tools/rpgc.py dialogue dialogue.toolkit-guide --actions examples/toolkit/dialogue.actions.json` 做真实VM预览；`python tools/rpgc.py world-checks` 验证状态、事件、对话和任务。详见[使用指南](docs/13-toolkit-usage.md)。

世界存档已接入F5/F9：安全点保存、独立用户目录原子写入、上一代备份、候选校验后恢复。`python tools/rpgc.py world-save --help` 提供快照检查、旧库存导入与显式内容迁移；完整说明见[使用指南](docs/13-toolkit-usage.md)。

地图制作工具已扩展八邻域blob／双地形、数据库模板三方更新和地图对象组实例化。`python tools/rpgc.py map-qa` 调用游戏共用的原生导航检查；`python tools/rpgc.py preview map village-outskirts --screenshot /tmp/new-map.png` 输出真实窗口预览。候选不会直接覆盖内容，详见[W4使用说明](docs/13-toolkit-usage.md#w4-地图制作模板和原生-qa)。

独立地图检查器：`python tools/rpgc.py preview map village-outskirts --window`。窗口支持阻挡／对象／候选变更标记、点击选格与QA问题定位；用 `--changes` 查看隔离候选，原地图保持不变。可复跑演示见 `examples/map-inspector/generate.py`。

地图对象组支持三方升级：`python tools/rpgc.py toolkit template objects-update request.json` 保留人工修改、报告字段冲突，并将同一地图的多个实例合成候选。运行 `examples/object-group-update/generate.py --eve /path/to/eve --output /tmp/new-group-demo` 可复现正常与冲突更新；详见[模板说明](docs/13-toolkit-usage.md#数据库模板与地图对象组)。

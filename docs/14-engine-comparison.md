# 与主流引擎的工作流对照及第三阶段改进

## 结论

rpg-classic 现在是以内容契约、命令行与无窗口验证为核心的可复用 RPG 工具套件。它适合版本控制、批量制作、AI/CI 调用和可重复测试；在可视化编辑深度、完整对话/存档、平台运行验证和生态方面，仍落后于成熟引擎。这里比较制作工作流，不以“功能个数”给引擎打分，也不把编译器、生成素材或源码封装等同于完整引擎能力。

对比对象限定为 RPG Maker MZ、GameMaker、Godot 4 和 Unity 的常见 2D 工作流；不比较定价、最新版本变更或未测量的性能。通用引擎通常需要脚本、包或插件实现 RPG 专项系统，这不表示它们缺乏实现能力。

## 能力矩阵

| 工作流 | RPG Maker MZ | GameMaker | Godot 4 | Unity | rpg-classic 当前状态 |
|---|---|---|---|---|---|
| RPG 数据库 | 原生角色/职业/技能/物品/敌群等数据库 | 通常使用数据结构、资源或自定义工具 | Resource、Inspector及自定义类型 | ScriptableObject、Inspector及编辑器扩展 | 18类文档（新增dialogue/quest）、schema、语义门、跨引用；带指纹的CSV批量交换 |
| 地图/房间制作 | 地图编辑、自动图块、事件布置 | Room/Tile Set编辑及自动图块工作流 | TileMapLayer/TileSet与terrain连接 | Tilemap及2D Tilemap Extras RuleTile | 等距编辑、16-mask/v2 blob47与受限双地形；原生地图QA、独立窗口截图 |
| 场景/对象复用 | 地图事件复制、公共事件和插件 | Objects/Instances、继承与脚本 | Scene实例化与继承、Resource共享 | Prefab/Variants与组件 | 数据库模板单继承、三方更新冲突；地图对象组实例化与三方更新；非通用Prefab系统 |
| 事件/剧情 | 图形事件命令、公共事件、消息和选择项 | 对象事件、GML与Sequence等组合 | 节点信号、脚本、动画；对话常由插件提供 | 脚本、Timeline等；对话常由自定义/插件提供 | 共享事件执行器、条件选项对话、任务目标/原子领奖已接入；move_actor仍明确拒绝，非完整演出系统 |
| 动画与资源 | 面向RPG的资源约定与动画工具 | Sprite/Sequence/资源编辑 | SpriteFrames、AnimationPlayer及导入系统 | Sprite Editor、Animator/Timeline及导入器 | 网格动画候选、PNG审计、WAV裁剪；没有完整动画状态图和压缩导入流水线 |
| 战斗调试 | 内建战斗测试、RPG默认运行时 | Debugger/Profiler；战斗通常由项目实现 | Debugger/Profiler；战斗通常由项目实现 | Debugger/Profiler/Test Framework；战斗通常由项目实现 | 真实VM固定种子模拟、技能命令录制和逐步回放；非通用性能Profiler |
| 存档 | 默认RPG存档流程，可扩展 | 文件/JSON等API，由游戏组织 | FileAccess/Resource等，由游戏组织 | 序列化/文件API，由游戏组织 | 战斗外世界快照、原子用户存档、上一代备份、显式内容迁移；战斗/演出中途续接尚未提供 |
| 本地化 | 文本事件/插件/项目流程 | 由数据和项目工具组织 | Translation资源及导入工作流 | Localization包及项目集成 | 指定字段提取/回填；对话稳定文本键、默认语言fallback和运行时中英文切换，未覆盖全项目文本 |
| 批量与自动化 | 插件及外部脚本扩展 | 项目构建工具与脚本流程 | 命令行/无头/导出预设 | batchmode、构建API、测试/CI | JSON CLI、纯Python API、隔离候选门；新增持久化发布预检profile |
| 分发 | 项目部署到支持目标 | 对应平台导出模块/目标 | Export Presets及平台模板 | Build Profiles/Player及平台工具链 | 本地SDK+源码三平台启动目录；不交叉编译、不包办系统依赖 |

## 本轮实现的三个优先项

### 1. 自动地形规则笔刷

目标是补上 RPG Maker 自动图块、GameMaker Auto Tiles、Godot Terrains、Unity RuleTile 所代表的“画地形而非逐格挑边缘”的效率。

`terrain.py` 接受完整16-mask规则；N/E/S/W分别为1/2/4/8，绘制和擦除后更新受影响格及四邻格。只识别指定地形GID，拒绝静默覆盖其他图块；变体由seed+格坐标+mask确定，跨进程一致。结果是现有map候选，无需新增运行时。

最初v1的边界是四邻域连接；后续W4已新增47-mask blob8与受限双地形transition8。仍不支持RPG Maker子图块拼接、三种以上材质交汇或Unity完整RuleTile条件系统。规则必须与实际图集的边缘图块一一对应，工具不会生成美术。只更新受影响区域，不重新生成整张地图。

### 2. 类型明确的数据库CSV交换

RPG Maker的数据库视图便于批量调参；通用引擎的Inspector和自定义工具解决类似问题。本项目沿用“可复用工具，不做新IDE”的原则，提供 `database export/import`，让表格软件承担表格UI。

每行包含路径、ID、原始指纹及显式JSON Pointer字段。数据单元格使用JSON字面量，保留字符串、数字、布尔、数组和null；空格表示不修改。导入拒绝过期指纹、身份变更、重复行、非有限数值、字段重叠及模糊的数组插入，输出现有change-set。未导出的字段与未导入的文档保留不动；全量门仍由check-changes负责。

边界：不是XLSX公式求值器；字符串必须保留JSON双引号；不新增隐式删除或自动重命名。此设计牺牲一点表格输入便利，换取可追踪类型和可靠候选合并。

### 3. 发布预检profile

Godot/Unity等工具的构建预设将常用发布配置固定下来。本项目新增的profile固定“发布前要检查什么”，不冒充平台编译器或完整Build Profile。

`pipeline.py` 提供quick/release和严格JSON自定义profile，固定允许 engine/assets/placeholder-anims/encounters/modules 五种检查，逐项预算与结构化结果。缺必需SDK、缺生成器、超时或失败均关闭必需门；前一项失败后继续采集其它结果。profile不能携带任意shell命令。

边界：预检报告是检查时刻的状态，不是源码封印或签名。打包仍是独立动作，不能将报告与后续改动后的包混为一谈；可选检查失败会显示fail，但不阻断聚合ok。默认release把完整模块套件列为可选，严格团队profile可将其设为required。

## 目前最值得继续投入的差距

| 优先级 | 差距 | 下一步验收标准 |
|---|---|---|
| 高 | 剧情运行时剩余表现能力 | move_actor等尚缺步骤需真实宿主确认；已交付对话/任务闭环继续回归 |
| 中 | 存档迁移深度 | 安全点存档已交付；任务定义变化的专用迁移、战斗/演出续存仍缺 |
| 高 | 地图与复用工具剩余范围 | 事件片段、外部Tiled、面积footprint与条件可达性 |
| 中 | 可重复的输入回放与性能分析 | 从技能回放扩展物品/世界输入；测量真实帧耗时和资源占用 |
| 中 | 真正平台发布验证 | Windows/macOS目标系统启动检查、依赖清单与发布签名 |
| 中 | 媒体导入深度 | 图片完整解码、图集打包、压缩与音频转码可重复且许可明确 |

## 参考资料与证据范围

- [RPG Maker MZ 官方产品介绍](https://www.rpgmakerweb.com/products/rpg-maker-mz)：数据库、地图、事件与部署的产品定位参考。
- [GameMaker Manual](https://manual.gamemaker.io/monthly/en/)：Rooms、Tile Sets、Objects、Sequences等工作流参考。
- [Godot 官方 TileMap 文档源](https://github.com/godotengine/godot-docs/blob/master/tutorials/2d/using_tilemaps.rst)：本轮实际读取，明确描述terrain连接的Connect/Path/Patterns等模式。
- [Unity 官方 2D Extras](https://github.com/Unity-Technologies/2d-extras)：本轮实际读取，列明RuleTile、Isometric Rule Tile、RuleOverrideTile及多种Brush；具体包版本应以项目所用Unity文档为准。

Godot与Unity上述开源文档本轮进行了联网核对；RPG Maker和GameMaker列的是稳定的产品工作流认知与官方入口，未复核它们当前在线手册每一页。没有运行四款引擎的横向性能基准，也没有据此宣称功能等价。

本轮实现验证：92项测试通过，严格发布profile五项检查全部通过；包含真实SDK、真实CSV候选全量校验和原项目不变检查。性能与跨平台实机能力未在本轮横向测量。

## 后续补全设计

依赖顺序、共享运行时协议、工作包及验收标准见 [15-completion-plan.md](15-completion-plan.md)。该文档按工作包定义目标与验收；已有原型不等于完成游戏接入，当前能力仍以本对照、使用指南及验收证据为准。

补全实施首批验收：共享状态、事件、对话与任务已接入主游戏；104项Python测试通过，世界/对话/任务共117个真实VM探针通过，严格发布预检六项全部通过。Linux软件Vulkan窗口中20项游戏宿主烟测通过（MCP调用真实游戏函数，非OS键盘模拟），覆盖开箱、领奖、镜头/动画、地图转移及取消恢复。复跑入口为 `tools/gameplay_smoke.py`；完整存档、move_actor与后续制作/发布工作包仍未完成。

W3安全点存档验收：111项Python测试通过；存档核心45项真实VM探针、原生用户目录12项检查及15项真实窗口断言通过。窗口测试实际关闭并重启引擎，从磁盘恢复已领奖任务，验证损坏主档备份回退、地图加载失败不替换世界。尚不支持战斗/演出中途保存、自动任务定义迁移和存档格式v2；平台证据仅为Linux。


## W4 制作增量实现

已交付可复用的八邻域47-mask规则与闭合双地形过渡、数据库模板／变体及三方冲突报告、原生world坐标对象组静态实例化。地图QA和独立截图入口使用与主游戏相同的导航和图层适配器，真实SDK检查地图加载、寻路、拾取及传送落点连通性。候选继续经过隔离全量权威门。

相较主流引擎的地图／Prefab工作流，当前仍缺对象组模板继承、事件片段模板、外部Tiled导入、面积footprint QA及剧情条件可达性模拟。预览仅地图，动画状态／媒体和世界回放仍属于后续工作包。八邻域示例规则不包含专用过渡美术，不将规则支持等同于美术资源齐全。

本轮最终验收：147项测试通过；严格发布预检7项全部通过。原生QA覆盖14张地图、8024格坐标拾取、97个对象和26条传送边。独立地图窗口截图通过；共用导航改动后的游戏跨进程存读档15项窗口检查通过（MCP调用游戏处理函数，非OS按键注入）。证据位于 `build/verification/w4/summary.json`，截图为 `preview-final.png`，平台仅Linux/Xvfb/Mesa llvmpipe。

地图预览后续增量已接入独立交互检查器：阻挡／对象／差异开关、原生选格、对象选择、缩放、QA对象定位和隔离候选预览。正常与错误候选均有真实窗口截图；158项测试、7项预检、13项窗口检查通过。它仍是只读检查工具，不扩充为统一IDE，也未提前完成剩余W4/W5能力。

对象组复用后续增量已实现三方更新：同图批量实例、按名合并属性、显式增删／改名、人工覆盖保留、冲突整图排除与旧侧车迁移。相较 Prefab 工作流补上了模板升级环节；尚未提供对象组模板继承和事件片段。170项测试与严格发布预检7项通过，真实SDK接受正常更新候选，冲突候选被拒绝；181个原内容文件保持不变。复跑示例为 `examples/object-group-update/generate.py`，证据为 `build/verification/object-groups/summary.json`。

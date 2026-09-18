# 引擎依赖与 C++ 回流

本仓库是 **EVEngine 游戏项目**（Squirrel、Eve Schema、`content/`、美术）。
它不包含引擎源码，也不在这里编译 C++。

## 运行时从哪里来

按这个顺序找 `eve`：

1. 命令行 `--eve <path>`（`tools/rpgc.py`）
2. 环境变量 `EVE_BIN`
3. `EVE_SDK_DIR` / `EVENGINE_SDK` 下的 `bin/eve`
4. `PATH` 上的 `eve`
5. `EVENGINE_ROOT` 指向的引擎源码树里的
   `build/<platform>-debug/src/engine/eve`
6. 与本仓库同级的 `../EVEngine` 或 `../EVEngine--worktrees/<name>` 里同样的构建产物

下载 SDK：<https://github.com/EVEngine/EVEngine/releases>
文档：<https://evengine.github.io/EVEngine/>

本地改引擎时，把 `EVENGINE_ROOT` 指到你的 checkout，或把编译出的 `eve` 放到 PATH。

## 什么改本仓库，什么改引擎

| 改这里（本仓库） | 开 PR 到 EVEngine `dev` |
|---|---|
| `content/`、`assets/`、schema、`lib/*.nut`、编辑器 | C++ 模块、脚本绑定、EditorHost / MCP、文件系统、地图加载器 |
| 项目校验门、workflow.json、游戏玩法脚本 | 引擎公共 API、崩溃、性能、校验器实现 |

必要的引擎修复必须进 `dev`，否则别的项目和 SDK 用户拿不到。

## 给引擎开 PR

1. Clone <https://github.com/EVEngine/EVEngine>，从 `dev` 拉分支（建议 `codex/` 前缀）。
2. 先做最小复现（单测或最小 `eve run` 脚本），再改生产路径。
3. 打开 `EVENGINE_VULKAN_VALIDATION=1` 做短跑。
4. 按引擎仓库 `AGENTS.md` 跑相关测试；接口/模块边界变更还要跑
   `ARCHITECTURE_BASE=HEAD make check/architecture-contracts`。
5. PR 目标分支是 **`dev`**，不要直接打 `main`。
6. 本仓库只记录依赖的引擎行为（schema、绑定、加载规则）。不要把 C++ 补丁提交到这里。

引擎侧文档入口：

- [AI 与 MCP](https://github.com/EVEngine/EVEngine/blob/dev/docs/dev/AI%E4%B8%8EMCP%E6%94%AF%E6%8C%81.md)
- [Editor tool protocol](https://github.com/EVEngine/EVEngine/blob/dev/docs/dev/editor-tool-protocol.md)

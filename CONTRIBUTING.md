# 贡献

- **内容、脚本、编辑器、资源**：在本仓库开 PR。
- **引擎 C++ / 公共 API**：开 PR 到 [EVEngine/EVEngine](https://github.com/EVEngine/EVEngine) 的 `dev` 分支，流程见 [ENGINE.md](ENGINE.md)。

内容文档改完后在仓库根目录跑：

```bash
python tools/rpgc.py validate
python tools/rpgc.py selftest
```

需要本机有可用的 `eve`（SDK 或本地构建）。

无显示器或 MCP 的 CI 环境可调用同一权威门与完整模块探针：

```bash
python tools/rpgc.py validate --headless
python tools/rpgc.py selftest --headless
python tools/build_placeholder_anims.py --check
python tools/rpgc.py toolkit assets
```

`selftest --headless` 要求探针逐项通过、最终 PASS 与进程正常退出三者同时成立。
新的 Squirrel 探针必须写在函数内；不要向 `modules_check.nut` 顶层持续增加局部变量，
因为 `-r` 与 SDK 的 `load.nut` 共享帧，越界可引起错误结果和原生崩溃。

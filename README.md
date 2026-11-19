# AgentBar

原生 macOS 液态玻璃（Liquid Glass）菜单栏 AI Agent 监控与一键审批工具。支持实时汇总本机与 SSH 服务器上的 **Codex（桌面版 / CLI）、Claude（桌面版 / Claude Code CLI）、DeepSeek Harness、Cursor、Trae、豆包、DeepSeek 对话** 会话状态、工具调用、Token、上下文窗口、缓存命中率、进程内存，并支持一键审批、一键跳转终端、面板内 Markdown 预览及余额 Dashboard（含 SSO 网页提取）。

## 构建与打包 DMG

```bash
git clone https://github.com/tangziyi1226-lab/AgentBar.git
cd AgentBar
./scripts/build_dmg.sh
```

产物路径：
- 应用包：`dist/AgentBar.app`
- 安装镜像：`dist/AgentBar.dmg`

## 文档与原型

- [需求文档 v0.2](docs/REQUIREMENTS.md)
- [技术设计 v0.2](docs/DESIGN.md)
- [交互原型 v0.2](prototype/index.html)
- [PR 说明](PR.md)

# Cloudflare 三入口代理配置指南

从一台新购买的 VPS 开始，搭建 **Xray VLESS + WebSocket + TLS、Cloudflare 三入口 fallback、Windows TUN 与指定代理的 HTTPS DNS**。

这里提供两条阅读路线：自己按步骤配置，或让 AI 按固定架构逐阶段辅助。文档为公开脱敏材料，模板需要填写你自己的参数后使用。

> 本仓库沿用文档中固定版本的 WS 架构，所选 Xray 版本会提示 WebSocket 弃用。版本、验证范围和升级注意事项见教程；不要把历史案例当成你的网络已经验收通过。

## 选择你的路线

| 我想做什么 | 从这里开始 |
| --- | --- |
| 第一次购买 VPS，自己按步骤操作 | [完整新手教程](docs/beginner/README.md) |
| 让 AI 一步一步指导部署 | [AI 辅助部署手册](docs/ai/README.md) |
| 把目标和交互方式发给 AI | [给 AI 的启动提示词](docs/ai/给AI的启动提示词.txt) |
| 记录进度，换会话后继续 | [阶段记录模板](docs/ai/阶段记录模板.md) |
| 在本地保存自己的参数 | [本地参数记录模板](docs/ai/本地参数记录模板.txt) |
| 查看实际完成了哪些检查 | [新手教程验证说明](docs/beginner/验证说明.md) · [AI 手册验证说明](docs/ai/验证说明.md) |

**下载使用：**点击仓库的 **Code → Download ZIP**，完整解压后保留目录结构。只下载生成脚本，会缺少旁边的模板。

## 网络结构

~~~mermaid
flowchart TD
    A["Windows / Android 应用"] --> B["FlClash / Clash Meta / Mihomo"]
    B -->|"明确的直连规则"| D["本地网络"]
    B -->|"代理规则"| P["PROXY fallback"]
    B -->|"DNS 上游连接"| N["DNS-PROXY fallback"]
    P --> E["CF-A / CF-B / CF-C 三个入口"]
    N --> E
    E --> C["Cloudflare 边缘"]
    C -->|"回源 TLS"| V["同一台 VPS · Xray VLESS / WS / TLS"]
    V --> T["目标网站"]
    D --> T
~~~

- 三个入口共用同一台 VPS，不是三台独立服务器。
- 两个 fallback 组都只包含三个个人节点，不含 DIRECT；原有明确的直连规则仍保留。
- Windows 配置包含物理网卡绑定、入口 /32 排除、端点保护与严格路由；Android 版移除电脑专用网卡绑定。
- 目标网站看到的代理出口仍是 VPS；直连网站使用本地出口。本文不承诺完全匿名、永久可达或所有网络低延迟。
- IPv6 不在教程主线验收范围。DNS、WebRTC、手机和故障切换分别验收。

## 文件与模板

~~~text
.
├── README.md                         仓库导航
├── docs/
│   ├── beginner/
│   │   ├── README.md                 完整人工教程
│   │   ├── generate-config.ps1       本地参数生成脚本
│   │   ├── templates/                服务端 / Windows / Android 模板
│   │   ├── 验证说明.md
│   │   ├── SOURCE_SHA256SUMS.txt      原稿附带的历史校验清单
│   │   └── SHA256SUMS.txt             当前发布文件校验清单
│   ├── ai/
│   │   ├── README.md                 AI 辅助部署手册
│   │   ├── 给AI的启动提示词.txt
│   │   ├── 阶段记录模板.md
│   │   ├── 本地参数记录模板.txt
│   │   ├── 验证说明.md
│   │   └── 技术底稿/                 AI 包内原有完整技术底稿
│   └── 发布说明.md                   文件映射、占位符和本轮检查范围
└── SHA256SUMS.txt                     整个仓库公开文件的校验清单
~~~

| 配置文件 | 用途 |
| --- | --- |
| [xray-server.json](docs/beginner/templates/xray-server.json) | VPS 服务端完整占位模板 |
| [mate-windows.yaml](docs/beginner/templates/mate-windows.yaml) | Windows 三节点、双 fallback、DNS 与 TUN |
| [mate-android.yaml](docs/beginner/templates/mate-android.yaml) | 移除电脑网卡绑定的 Android 模板 |
| [generate-config.ps1](docs/beginner/generate-config.ps1) | 在本地新目录中填参并生成匹配配置 |

模板含占位符，**不能直接导入**。请先阅读完整教程，完成服务端、证书和入口验证，再按教程运行脚本。脚本只生成新文件，不替你安装、部署或加载客户端配置。

## 发布内容与占位符

正文沿用作者经润色的文档，命令、模板与脚本内容原样保留；发布时统一目录和文件名，并另外增加本首页与校验清单。

**正文中的 Google 搜索地址是作者保留的占位符，本次按要求原样保留。**需要访问实际文件时，请使用本页导航或仓库目录；不要把占位符当成真实部署参数或已验证的参考链接。

原稿附带的校验清单保留为 SOURCE_SHA256SUMS.txt，仅作历史记录。请使用本次重新计算的 SHA256SUMS.txt 核对发布文件。具体映射与检查范围见 [发布说明](docs/发布说明.md)。

## 分享与使用

本仓库不包含作者的实际公网地址、VPS 出口、个人域名、UUID、证书私钥或原始日志。读者填好后的本地参数表、generated 配置、证书、私钥和排错日志属于自己的私有材料，不要重新打包上传。

.gitignore 提供常见私有文件排除规则，但不能替代上传前的人工检查。请按当地规定及服务商规则使用；修改版本、网络或配置后重新完成相应验收。

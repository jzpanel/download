# jzpanel download（分发备用源）

极致面板安装/升级的**下载分发仓库**，作为主 OSS 之外的备用源。三源故障切换：

| 优先级 | 源 | 地址前缀 |
|---|---|---|
| 1 主 | OSS（国内快） | `https://download.jzpanel.com` |
| 2 备（国内） | jsDelivr 加速 | `https://cdn.jsdelivr.net/gh/jzpanel/download@main` |
| 3 备（国外） | GitHub 直连 | `https://raw.githubusercontent.com/jzpanel/download/main` |

`install.sh` / `jz` 内置上述顺序，逐源尝试，任一成功即停，每个源都做 SHA256 校验。

## 目录结构（三源必须完全一致）

```
install.sh                                   # 一键安装脚本
jz                                           # 面板管理工具
latest.json                                  # 版本信息（官网 API 挂了的兜底）
releases/
  <版本>/                                     # 如 1.0.0（无 v 前缀）
    panel-linux-amd64.gz                      # gzip 压缩的面板二进制
    panel-linux-amd64.gz.sha256
    panel-linux-arm64.gz
    panel-linux-arm64.gz.sha256
```

- 版本目录用纯版本号 `1.0.0`，与脚本 `releases/${ver}/panel-linux-${arch}.gz` 对齐。
- **二进制以 gzip 压缩入库**：面板二进制约 50MB，超过 jsDelivr 单文件 50MB 上限，压缩后约 20MB，三源（含 jsDelivr）均可服务。脚本下载 `.gz` 后本地 `gunzip -dc` 还原。
- `.sha256` 校验的是 **`.gz` 文件**（下载物），内容：`<64位hash>  panel-linux-amd64.gz`（脚本取第 1 列）。
- 主 OSS 也要保持同样的 `releases/...` 结构和 `latest.json`（它是首选源）。

## 发布新版本流程

1. 编译 `panel-linux-amd64` / `panel-linux-arm64`，生成各自 `.sha256`。
2. 放入 `releases/<新版本>/`，同步上传到主 OSS 同路径。
3. 更新 `latest.json` 的 `version`（及 url 里的版本号），同步到主 OSS。
4. `git add . && git commit -m "release <新版本>" && git push`。
5. jsDelivr `@main` 首次拉新路径即最新（新版本是新路径，不受旧缓存影响）。

## 安装命令

```bash
# 主（推荐）
bash <(curl -fsSL https://download.jzpanel.com/install.sh)
# 备用（国内加速）
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/jzpanel/download@main/install.sh)
# 备用（国外直连）
bash <(curl -fsSL https://raw.githubusercontent.com/jzpanel/download/main/install.sh)
```

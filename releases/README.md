# releases

按版本号存放面板二进制，目录名用纯版本号（无 v 前缀），例如：

```
releases/1.0.0/panel-linux-amd64
releases/1.0.0/panel-linux-amd64.sha256
releases/1.0.0/panel-linux-arm64
releases/1.0.0/panel-linux-arm64.sha256
```

生成 sha256：`sha256sum panel-linux-amd64 > panel-linux-amd64.sha256`

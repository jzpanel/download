# releases

按版本号存放面板二进制（**gzip 压缩**），目录名用纯版本号（无 v 前缀），例如：

```
releases/1.0.0/panel-linux-amd64.gz
releases/1.0.0/panel-linux-amd64.gz.sha256
releases/1.0.0/panel-linux-arm64.gz
releases/1.0.0/panel-linux-arm64.gz.sha256
```

生成方式：
```
gzip -9 -c panel-linux-amd64 > panel-linux-amd64.gz
sha256sum panel-linux-amd64.gz > panel-linux-amd64.gz.sha256
```
压缩是为了适配 jsDelivr 单文件 50MB 上限（面板二进制约 50MB，压缩后约 20MB）。

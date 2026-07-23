# AceHub 品牌资产

定稿方案 **aperture(光圈)**:三片涡旋叶片围合出中心端口,像微微张开的相机光圈——网关就是一个可控的开口,所有流量经由中心端口进出。全程曲线、零棱角。

## 文件清单

| 文件 | 用途 |
|---|---|
| `icon-primary.svg` | 主图标(透明底),站内 logo、宣传物料 |
| `icon-app-dark.svg` | App 图标(深色圆角底),头像、社交账号 |
| `favicon.svg` | 加粗简化版(叶片更短更粗、端口更大),浏览器标签页小尺寸专用 |
| `favicon.ico` | 多尺寸 ICO(16/32/48/64/128/256,PNG 压缩条目),直接替换部署产物 |
| `logo-horizontal-light.svg` | 横版 Logo,浅色背景 |
| `logo-horizontal-dark.svg` | 横版 Logo,深色背景 |
| `export/` | 预导出 PNG:`logo-512`、`app-icon-512/1024`、`favicon-16~256/192` |
| `preview.html` | 浏览器打开即可预览全部资产(深浅底、多尺寸) |

历史方案存档:`icon-v1-*` / `favicon-v1` / `logo-v1-*`(V1 字母 A 拓扑)、`icon-alt-*`(V1 备选)、`icon-v2-*`(V2 融合方案)、`icon-v3-*`(V3 探索方案,aperture 出自此轮)。

## 配色

| 名称 | 色值 | 用途 |
|---|---|---|
| Indigo | `#6366F1` | 渐变起点(深色底用 `#818CF8` 提亮) |
| Cyan | `#22D3EE` | 渐变终点 |
| Ink | `#0B1220` | 深色底 / App 图标底色 |
| Slate | `#0F172A` | 浅色底文字 |

单色场景(印刷、水印):把渐变统一替换为 `#6366F1` 或 `currentColor`。

## 重新导出

```bash
# macOS: brew install librsvg
rsvg-convert -w 512 -h 512 icon-primary.svg > export/logo-512.png
rsvg-convert -w 64 -h 64 favicon.svg > export/favicon-64.png
```

或把 favicon.svg 丢给 realfavicongenerator.net 一键重新生成全套 ico/png。

## 应用到 New API / AceHub

静态资源已落盘到前后端入口(源码侧,构建时会打进产物):

| 目标 | 文件 |
|---|---|
| `web/public/` | `logo.png` / `logo.svg` / `favicon.ico` / `favicon.svg` |
| `electron/` | `icon.png`(app-icon-512) / tray 模板 |
| `new-api-docs-v1/public/` | `favicon.ico` + `assets/logo.png` + `assets/newapi.svg` |

运行时覆盖(可选):

1. 后台 **系统设置 → 通用设置 → Logo**,填入可公网访问的图片 URL
2. 未配置时前端回退到 `/logo.png`(即上面的静态资源)

注意:不要移除仓库中 new-api / QuantumNous 的版权与署名(项目政策保护项);站点换标只通过上述系统设置项与自有静态资源完成。

横版 Logo 里的文字用的是系统字体栈(Inter 优先),正式对外发布前建议在 Figma/Illustrator 中把文字转曲,避免不同设备字体回退不一致。

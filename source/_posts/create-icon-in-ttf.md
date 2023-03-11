---
title: 创建自己的icon字体
abbrlink: 47585
date: 2023-03-11 13:29:59
tags:
---

## 背景

在很多软件中，想要显示一个图标，除非是开源软件中存在的图标，否则图标就无法适配，当前文章将会描述如何从png生成icon。

## 实现一个icon

### PNG2SVG

首先，通过png转换为svg：

[freeconvert](https://www.freeconvert.com/png-to-svg/download)

### SVG to TTF

再通过svg生成对应的ttf文件，建议对图片进行处理：

[svg2ttf](https://icomoon.io/app/)

### Show Icon in TTF 

最终，在css文件中，增加相关内容，即可使用`icon-excalidraw-plus-icon-filled`类来显示icon。

```
@font-face {
  font-family: 'icomoon';
  src:  url('fonts/icomoon.eot?1jeat0');
  src:  url('fonts/icomoon.eot?1jeat0#iefix') format('embedded-opentype'),
    url('fonts/icomoon.ttf?1jeat0') format('truetype'),
    url('fonts/icomoon.woff?1jeat0') format('woff'),
    url('onts/icomoon.svg?1jeat0#icomoon') format('svg');
  font-weight: normal;
  font-style: normal;
  font-display: block;
}

[class^="icon-"], [class*=" icon-"] {
  /* use !important to prevent issues with browser extensions that change fonts */
  font-family: 'icomoon' !important;
  speak: never;
  font-style: normal;
  font-weight: normal;
  font-variant: normal;
  text-transform: none;
  line-height: 1;

  /* Better Font Rendering =========== */
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

.icon-excalidraw-plus-icon-filled:before {
  content: "\e900";
}

```
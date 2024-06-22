---
title: Git automation completes hexo deployment
abbrlink: 33903
date: 2024-06-22 20:50:34
tags:
---
# 0. 前言
在hexo使用上，将deploy和生成功能分开，同时需要2个命令来控制是一个很好的设计。
但是，对于我这么懒惰的人，我当然是希望将这个流程自动化了。
然后，其中遇到了几个问题：
- hexo环境自动化部署
- hexo提交自动化

# Setup.sh

环境自动化，一般都是通过一个统一的脚步来实现即可。那么，就可以实现一个setup.sh脚本来初始化，例如：
```
#!/bin/bash

echo "Provisioning resources..."
npm install hexo-cli -g
git submodule update --init --recursive
git config core.hooksPath hooks
chmod +x hooks/*
```

这里面会完成以下初始化操作：
- `hexo-cli`安装
- `submodule`：拉取主题信息，这里用的是cactus
- `hooksPath`: 配置hooks路径
- `chmod`: 提供可执行能力

# Hooks

hooks只能在本地使用，然后，我希望能在push的时候，能自动化的完成部署，那么，只需要支持`pre-push`脚本来实现即可。

```
#!/bin/sh
hexo g
hexo d
```

# Image

参考[使用VSCode编辑Hexo博客时插入图片](https://gs42.org/posts/VSCode_Hexo_insert_image/) 文章，我们需要设置相关的image路径。

修改`_config.yml`文件：
```
post_asset_folder: false
```

并在vscode的配置修改元素、找到`markdown > Copy Files ：Destination`，点击Add Item，添加的对应的键值如下（需要根据自己的目录结构和自定义页面自行修改）：
```
"/source/_posts/**/**/*": 
"${documentWorkspaceFolder}/source/img/${documentBaseName}-${fileName}"

"/source/about/*": 
"${documentWorkspaceFolder}/source/img/about-${fileName}"

"/source/cross/*": 
"${documentWorkspaceFolder}/source/img/cross-${fileName}"

"/source/**/*": 
"${documentWorkspaceFolder}/source/img/pages-${fileName}"
```

当前，也可以支持`settings.json`文件：
```
{
    "markdown.copyFiles.destination": {
        "/source/**/*": "${documentWorkspaceFolder}/source/images/pages-${fileName}"
    }
}
```

# Result

这样， 我就不用再纠结hexo的环境了。我只需要拉取仓库，并执行`bash setup.sh`，再继续编写我的文档即可。
---
title: "Mac升级bash到最新版本"
date: 2019-07-22T13:50:34+08:00
categories: ["mac"]
tags: ["mac", "bash", "shell"]
---

## Mac升级bash到最新版本

先检查当前`bash`版本信息

```shell
$ /bin/bash --version
GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin18)
Copyright (C) 2007 Free Software Foundation, Inc.
```

使用`brew`安装最新的bash

如果没有安装`brew`的:

```shell
$ /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
```

使用`brew`安装最新的bash:

```shell
$ brew install bash
```

替换bash

```shell
$ sudo mv /bin/bash /bin/bash.origin
$ sudo ln -s /usr/local/bin/bash /bin/bash 
```
**注:** 使用brew安装应用时, 默认会在`/usr/local/bin`目录下生成相应可执行文件  

验证最新bash版本
```shell
$ bash --version
GNU bash，版本 5.0.7(1)-release (x86_64-apple-darwin18.5.0)
Copyright (C) 2019 Free Software Foundation, Inc.
许可证 GPLv3+: GNU GPL 许可证第三版或者更新版本 <http://gnu.org/licenses/gpl.html>

本软件是自由软件，您可以自由地更改和重新发布。
在法律许可的情况下特此明示，本软件不提供任何担保。
```

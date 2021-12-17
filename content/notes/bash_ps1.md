---
title: "设置个性化的终端命令提示符(PS1 prompt)"
date: 2019-08-08T10:36:49+08:00
categories: ["mac"]
tags: ["mac", "bash", "shell"]
---

## 设置个性化的终端命令提示符(PS1 prompt)

如果想改变`终端命令行提示符(PS1 prompt)`, 是通过修改当前用户的`~/.bashrc`文件里的`PS1`变量来实现的

把`PS1`设置为如下的样子:

```shell
PS1='>>> '
```

在`source ~/.bashrc`后, 终端将变为如下的样子:

```shell
>>> _
```

如果想显示用户名和当前目录, 并且以`$`结束, 可以按照如下来设置:

```shell
PS1='\u \w $ '
```

在终端的显示如下:

```shell
john ~ $ _ 
```

如果还想显示当前时间, 并且`$`是在下一行的开头, 则可以这样设置:

```shell
PS1='[\t] \u \w\n$ '
```

显示结果如下:

```shell
[01:13:55] john ~
$ _
```

以下是`bash`里的可用的转义字符以及代表的含义:

| 参数名 | 说明        |
| :-----: | :--------- |
|  \u   |  当前用户  |
|  \w   | 当前工作目录 |
|  \W   | 当前工作目录的最后一段. 例如, 如果当前在`/usr/local/bin`, 将显示为`bin`|
|  \h   | 计算机的名称, 截止到(`·`).例如, 如果名称为`ubuntu.pc`, 将显示为`ubuntu`|
|  \H   | 完整计算机的名称|
|  \d   | "星期 月份 日前"格式化的日期, (例如, Tue 21 July)|
|  \t   | 24小时制的当前时间|
|  \T   | 12小时制的当前时间|
|  \\@   | 12小时制 AM/PM 显示的当前时间|
|  \n   | 下一行 |

参考资料: [https://www.booleanworld.com/customizing-coloring-bash-prompt/](https://www.booleanworld.com/customizing-coloring-bash-prompt/)

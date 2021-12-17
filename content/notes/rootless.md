---
title: "Mac OS的Rootless机制"
date: 2019-07-22T10:14:43+08:00
categories: ["mac"]
tags: ["mac"]
---

## Mac OS的Rootless机制

Mac 系统自动更新了`OS X 10.14.5`后, `/bin`和`/usr/bin`目录的文件使用`sudo`也出现权限问题:

```shell
$ sudo mv /bin/bash /bin/bash.origin
mv: rename /bin/bash to /bin/bash.origin: Operation not permitted
```

搜索之后, [midmirror的简书](https://www.jianshu.com/p/22b89f19afd6)里说, 是`El Capitan`加入了`Rootless机制`, 不再能够随心所欲的读写很多路径下了.即使使用`sudo`也不行.

> Rootless机制将成为对抗恶意程序的最后防线

如果想关闭`Rootless`. 重启mac按住`Command+R`, 进入恢复模式, 打开Terminal.

```shell
$ csrutil disable
```

重启即可. 如果要恢复默认, 那么

```shell
$ csrutil enable
```

### 附录:

csrutil 命令参数格式:

> csrutil enable [--without kext | fs | debug | dtrace | nvram][--no-internal]

禁用: csrutil disable

> （等同于csrutil enable --without kext --without fs --without debug --without dtrace --without nvram

其中各个开关, 意义如下:

> * B0: [kext] 允许加载不受信任的kext（与已被废除的kext-dev-mode=1等效）
> * B1: [fs] 解锁文件系统限制
> * B2: [debug] 允许task_for_pid()调用
> * B3: [n/a] 允许内核调试 （官方的csrutil工具无法设置此位）
> * B4: [internal] Apple内部保留位（csrutil默认会设置此位，实际不会起作用。设置与否均可）
> * B5: [dtrace] 解锁dtrace限制
> * B6: [nvram] 解锁NVRAM限制
> * B7: [n/a] 允许设备配置（新增，具体作用暂时未确定）

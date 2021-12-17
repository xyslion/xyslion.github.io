#!/bin/bash

[[ -d dev ]] && rm -rf dev
hugo server --buildDrafts --destination dev --disableFastRender

# -D, --buildDrafts[=false]    文章的默认状态是草稿，草稿默认不会构建，必须加上这参数才会生成页面。
# -w, --watch    文件有改动时自动重新构建并刷新浏览器页面。（默认就带这个，不传也行）
# -d, --destination DIR    输出目录。不传这参数的话构建出来的文件只会放在内存里。
# --disableFastRender    有改动时触发完整构建。反正 Hugo 非常快，几百毫秒根本感觉不到。
# 笔记屋

使用hugo进行markdown文件渲染出静态博客网页

使用主题: `beautifulhugo`
```shell
mkdir themes
cd themes
git submodule add https://github.com/halogenica/beautifulhugo.git beautifulhugo
```

`master`分支保存源码，`gh-pages`分支用于保存hugo编译好的文件，用于`github pages`显示

使用`GitHup Action`的任务流，监听到`master`分支提交，然后进行`hugo`编译，接着将编译好放在`/public`文件夹提交到`gh-pages`分支

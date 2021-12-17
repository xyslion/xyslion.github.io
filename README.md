# 笔记屋

使用hugo进行markdown文件渲染出静态博客网页

使用主题: `beautifulhugo`
```shell
mkdir themes
cd themes
git submodule add https://github.com/halogenica/beautifulhugo.git beautifulhugo
```

使用`githup`的个人主页功能
1. 新建project: `xyslion/xyslion.github.io`
2. 添加为当前project的`submodule`，对应目录为`public`
   ```shell
	 # 设置submodule
	 git submodule add https://github.com/halogenica/beautifulhugo.git public
	 # 更新submodule
	 cd public
	 git submodule update --recursive --remote
	 ```

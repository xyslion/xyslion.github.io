---
title: "利用 GitHub Pages, Hugo, Markdown 搭建个人笔记博客"
date: 2021-12-17T13:54:49+08:00
slug: hugo-note
tags: ["hugo", "blog", "note"]
categories: ["hugo"]
---

## 利用 GitHub Pages, Hugo, Markdown 搭建个人笔记博客

* `GitHub Pages` 是一个静态站点托管服务，直接将个人、组织或项目的页面托管于 GitHub 库或仓库 (repository) 中。
* `Hugo` 是一个用 Go 语言编写的静态站点生成器，它针对速度、易用性和可配置性进行了优化，快速灵活。
* `Markdown` 是一种轻量级标记语言，它允许人们使用易读易写的纯文本格式编写文档。

### 安装 Hugo

1. Hugo安装指南: [https://gohugo.io/getting-started/installing/](https://gohugo.io/getting-started/installing/)
2. Mac 安装Hugo，打开一个终端 Terminal, 输入`brew install hugo`
3. 确认是否安装成功，输入`hugo version`

### 使用 Hugo 写笔记

1. 新建 Hugo 站点，`hugo new site blog`
2. 设置网站主题
   ```shell
	 # 进入hugo站点目录
	 cd blog
	 # 新建themes目录用于主题保存地址
	 mkdir -p themes
	 # 进入主题目录
	 cd themes
	 # 使用git下载主题
	 git submodule add https://github.com/halogenica/beautifulhugo.git beautifulhugo
	 # 设置网站主题
	 echo theme = "beautifulhugo" > config.toml
	 ```  
	 **注：可以在 Hugo 主题页面 [https://themes.gohugo.io/](https://themes.gohugo.io/)挑选自己喜欢的主题**
3. 写文章
   ```shell
	 # 进入网站(项目)根目录
	 cd blog
	 # 使用hugo命令创建文章
	 hugo new notes/my-fist-note.md
	 # 编辑notes/my-fist-note.md，然后保存就可以
	 ```  
	 **注：最好使用hugo命令来创建文件，因为这样可以自动在markdown文件头部加入一下标记**
	 ```markdown
	 ---
   title: "利用 GitHub Pages, Hugo, Markdown 搭建个人笔记博客"
   date: 2021-12-17T13:54:49+08:00
   slug: hugo-note
   tags: ["hugo", "blog", "note"]
   categories: []
   draft: true
   --- 
	 ```  
4. 本地预览网站效果
   ```shell
	 hugo server -D
	 ```  
	 使用浏览器打开`http://localhost:1313`预览
5. 构建 Hugo 网站
   ```shell
	 # 需要先将markdown文件中的`draft: true`才能将该篇文件构建出来
	 hugo  # 构建你的 Hugo 网站，默认将静态站点保存到 "public" 目录。
	 ```  
	 **注：Hugo 会将构建的网站内容默认保存至网站根目录的 public/ 文件夹中**

### 使用 Git 关联到 GitHub 仓库
1. 注册一个[GitHub](https://github.com/)账号。如果你已有账号，直接登录。如果你没有账号，注册并登录。  

2. 打开 GitHub Pages 官网，浏览并了解 User or organization site 部分对应的操作步骤。  
GitHub Pages: [https://pages.github.com](https://pages.github.com)  

3. 新建一个 GitHub repository，库名为 username.github.io，username 即你的 GitHub 账号 username。新建 repository：[github.com/new](https://github.com/new)  

4. 初始化 git 仓库 
   ```shell
   cd blog 
   git init  # 初始化 Git 库。
   ```  

5. 关联到远程仓库
   ```shell
   git remote add origin git@github.com:xyslion/xyslion.github.io.git  # "xyslion/xyslion.github.io.git" 代表 "your-github-id/your-github-id.github.io.git"。
   ``` 

6. 提交修改到远程仓库
   ```shell
   git add .  # 添加所有修改过的文件。你也可以只添加某个文件。
   git commit -m "Add a new post"  # "Add a new post" 是 commit message.
   git push -u origin master
   ```    

### 使用 GitHub Action 进行自动发布文章

`master`分支放 Hugo 站点原文件，然后将`/public`提交到`gh-pages`分支用于`GitHub Pages`显示

1. 生成 `ACTIONS_DEPLOY_KEY`
   ```shell
	 ssh-keygen -t rsa -b 4096 -C "$(git config user.email)" -f gh-pages -N ""
	 ```  
	 将生成的私钥文件`gh-pages`(注意不是公钥`gh-pages.pub`) 中的内容复制填写到 GitHub 仓库设置中，即在`xyslion.github.io`项目主页中，找到 Repository Settings -> Secrets -> 添加这个私钥的内容并命名为 `ACTIONS_DEPLOY_KEY`。 然后在`xyslion.github.io`项目主页中，找到 Repository Settings -> Deploy Keys -> 添加这个公钥的内容，命名为`ACTIONS_DEPLOY_KEY`，并勾选 Allow write access。
2. 配置workflow
	* 创建workflow文件
	  ```shell
		mkdir -p .github/workflows/
		touch .github/workflows/gh-pages.yml
		```    

	*	编辑 gh-pages.yml，内容如下:  
        ```yaml
        name: github pages
    
        on:
          push:
            branches:
              - master # 每次推送到 master 分支都会触发部署任务
          workflow_dispatch: # 允许手动触发部署
    
        jobs:
          deploy:
            runs-on: ubuntu-18.04
            steps:
              - uses: actions/checkout@v2
                with:
                  submodules: true # Fetch Hugo themes (true OR recursive)
                  fetch-depth: 0 # Fetch all history for .GitInfo and .Lastmod
    
              - name: Setup Hugo
                uses: peaceiris/actions-hugo@v2
                with:
                  hugo-version: latest 
                  extended: true
    
              - name: Build
                run: hugo --gc --minify --cleanDestinationDir
    
              - name: Deploy
                uses: peaceiris/actions-gh-pages@v3
                with:
                  deploy_key: ${{ secrets.ACTIONS_DEPLOY_KEY }}
                  publish_branch: gh-pages 
                  publish_dir: ./public
        ```  

这样配置之后，当提交修改到master分支后，就会触发这个workflow，然后自动的将`/public`目录内容发送到`gh-pages`分支

### 参考文档

* [Hugo](https://gohugo.io/getting-started/quick-start/)
* [GitHub Pages](https://pages.github.com)
* [Host on GitHub](https://gohugo.io/hosting-and-deployment/hosting-on-github/)
* [GitHub Action Deploy Key](https://github.com/marketplace/actions/github-pages-action#tips-and-faq)
* [Markdown语法](https://www.markdown.xyz/basic-syntax/)
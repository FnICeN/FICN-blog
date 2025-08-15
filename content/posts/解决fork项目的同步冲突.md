+++
date = '2025-08-15T11:47:25+08:00'
draft = true
title = '使用VSCode解决fork项目的同步冲突'
tags = ["心得", "Git"]
categories = ["经验"]
showToc = false
math = false

+++

在Github上Fork了一个[iptv-api](https://github.com/Guovin/iptv-api)的项目，设置自动获取信息的Action实现了对IPTV源的每日更新，但有时上游仓库会对项目功能作更新或修复，这时就需要将Fork仓库与上游仓库同步，此时就可能出现冲突

Github无法在线解决冲突，这里使用VSCode解决

首先打开VScode，进入Fork项目的目录中，确保VScode已识别本地仓库且已添加上游仓库，然后新建终端执行：

```bash
git fetch upstream
```

接着输入`git branch`确保正在需要同步的分支上，在本例中，只存在一个分支`master`，如果存在多个分支，则使用`git checkout <branch>`切换即可

执行合并：

```bash
git merge upstream/master
```

执行后，VSCode左侧导航栏就会提示存在冲突的文件，可以鼠标点击选择是否保留先前内容，选择完成后保存、提交并同步即可，流程与正常使用VSCode执行Git操作一致


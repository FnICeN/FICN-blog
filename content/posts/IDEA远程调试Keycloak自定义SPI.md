+++
date = '2025-08-21T15:51:01+08:00'
draft = false
title = 'IDEA远程调试Keycloak自定义SPI'
tags = ["IDEA", "心得", "Keycloak"]
categories = ["经验"]
showToc = true
math = false

+++

在基于Keycloak开发调试自定义SPI时，为了使其运行，通常需要：

1. 手动将项目打包为jar文件
2. 将其放入Keycloak的`/providers`目录中
3. 在命令行重启Keycloak服务

对于需要观察运行状态、乃至打断点的调试来说十分不便

**考虑使用JVM远程调试 + HotSwap实现对Keycloak的实时调试**

## JVM配置

首先需要让JVM在5005端口上监听调试请求，所以在终端设置参数（以Windows为例）：

```cmd
set JAVA_OPTS_APPEND=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005
```

然后在同一个终端下加载jar包、运行服务：

```cmd
bin\kc.bat start-dev
```

{{< admonition note "注意" >}}
使用`set`命令设置的环境变量**仅在当前终端窗口生效**，所以需要在同一个终端下运行以上两条命令；或者可以手动在系统设置中配置环境变量，然后打开一个新终端直接运行Keycloak
{{< /admonition >}}

服务启动后终端显示大概如下：

![启动调试-终端](https://img.fnicen.top/PicGo/启动keycloak调试终端.png)

## IDEA配置

打开IDEA，在右上角找到调试下拉框（就是正常运行、调试代码的部分），进入编辑配置页面后点击页面左上角加号添加新调试，在左侧选择添加【远程JVM调试】

{{< figure align=center src="https://img.fnicen.top/PicGo/添加配置.png">}}

接下来配置该调试的各参数，名称随意，注意主机和端口要正确填写：

![配置远程调试参数](https://img.fnicen.top/PicGo/配置远程调试参数.png)

完成后点击调试按钮，即可看到IDEA下方调试栏中提示：`已连接到地址为 ''localhost:5005'，传输: '套接字'' 的目标虚拟机`，则环境配置成功

## HotSwap

在已连接的情况下，对代码进行修改时，代码编辑框体的右上角会出现Code changed提示与按钮，点击后即可实现JVM对class的热更新

{{< figure align=center src="https://img.fnicen.top/PicGo/热更新.png">}}

如此一来，每次修改代码、需要调试时，无需重新打包、导入自定义SPI的繁复操作，点击按钮即可自动编译项目、更新JVM中运行的class文件

{{< admonition important "局限" >}}由于HotSwap只能对编译生成的class文件热更新，所以本文章的方法并不能对前端FTL文件进行实时调试，每当修改了FTL文件时，仍然需要重新打包并导入Keycloak；另外，HotSwap也不支持对类名、类增减以及方法增减的热更新{{< /admonition >}}

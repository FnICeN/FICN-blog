+++
date = '2025-02-17T20:04:58+08:00'
draft = false
title = 'Docker环境下安装AList过程与心得'
tags = ["Docker","AList","心得"]
categories = ["经验"]
showToc = true
math = false

+++

最近在树莓派上使用Docker部署了AList作为个人云盘使用，同时AList还支持整合各大网盘资源，可以极大方便我管理自己的网盘资源，在这里记录一下部署的过程，供之后参考

## Docker环境安装

在Linux环境中安装Docker非常方便，直接下载即可。我的树莓派是基于Debian的系统所以直接安装即可，没有遇到什么问题，注意国内网络需要在`/etc/docker/daemon.json`配置一下镜像源。

> docker有效镜像源持续更新网站：[Docker/DockerHub 国内镜像源/加速列表（2月15日更新-长期维护）](https://cloud.tencent.com/developer/article/2485043)

对于Windows系统，安装Docker的步骤相对比较复杂，参考文章：[Windows 11：Docker Desktop 安装和配置指南](https://www.sysgeek.cn/install-docker-desktop-windows-11/)，因为我是在树莓派上安装的AList，所以有关Windows系统部署AList的过程不在本文讨论中

安装完成后，执行`systemctl status docker`检查Docker服务是否正常运行

## 外接硬盘配置

为了能让AList担当个人云盘的功能，我在树莓派外部设置了一个1TB的机械硬盘用于存储数据，硬盘插在硬盘盒上，通过USB线与树莓派连接

连接硬盘后，命令`sudo fdisk -l`可以查看硬盘的相关信息

在Linux中连接一个硬盘后，一些图形化的系统可以自动挂载硬盘，我的树莓派系统也可以自动挂载，但默认挂载点是在`/media`的，我不想让它挂载在这个地方，于是决定手动挂载

创建目录：`/mnt/1TB_disk`作为指定挂载点，然后进行挂载：

```bash
sudo mount /dev/sda1 /mnt/1TB_disk
```

挂载完成后，命令`lsblk -f`可以查看硬盘的文件系统类型、UUID等信息：

```bash
FICN@FICN:~ $ lsblk -f
NAME        FSTYPE FSVER LABEL  UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
sda
└─sda1      exfat  1.0          67AF-3F5B                             926.7G     1% /mnt/1TB_disk
```

但这样的话，每次连接硬盘时都需要手动挂载一次，很麻烦，所以可以使用**autofs**实现自动将连接的硬盘挂载至指定目录，当一段时间不使用硬盘资源时，autofs也会自动取消硬盘挂载

### autofs自动挂载

`sudo apt-get install autofs`下载autofs，然后`systemctl enable autofs`、`systemctl start autofs`启动服务，创建`/etc/auto.master`添加：

```bash
/mnt /etc/auto.disk --timeout=60
```

最后创建`/etc/auto.disk`并设置：

```bash
1TB_disk -fstype=exfat,raw,noatime :/dev/disk/by-uuid/67AF-3F5B
```

这里指定了硬盘文件系统类型为**exfat**，并使用**UUID**来指定需要被挂载的硬盘，这两个都是之前执行`lsblk -f`命令获得的信息

如此配置后，硬盘将被自动挂载至`/mnt/1TB_disk`目录

最后还要禁用系统原有的自动挂载服务：`systemctl stop fstab`、`systemctl disable fstab`

> Q：为什么不直接改fstab的配置，反而要再下载一个autofs进行自动挂载？
>
> A：因为听说fstab配置不好会无法开机，而且看起来autofs的配置比fstab的配置写法更好懂

为了磁盘空间管理方便，在磁盘中创建一个目录`/mnt/1TB_disk/AList`专门用于存储AList相关数据

## AList安装

参考官方文档，使用Docker安装AList只需要一行命令即可

**这里有一个注意点，如果想要在AList中使用除SimpleHttp之外的下载方式（如Aria2），那么最好不要下载文档中提供的docker镜像`alist:latest`**

虽然完全可以安装AList后再在Docker容器中下载Aria2，但我自己尝试后感觉略显繁琐，何况官方也提供了预装Aria2的镜像版本，何不直接使用呢？另外如果已经安装了`alist:latest`想要更换版本，官方也提供了清晰的文档，见：https://alist.nn.ci/zh/guide/install/docker.html#%E6%9B%B4%E6%96%B0

这里我选择使用预装Aria2的镜像版本，部署命令：

```bash
docker run -d --restart=unless-stopped -v /mnt/1TB_disk/AList:/opt/alist/data -p 5244:5244 -e PUID=0 -e PGID=0 -e UMASK=022 --name="alist" xhofe/alist:latest-aria2
```

注意这里`-v /mnt/1TB_disk/AList:/opt/alist/data`设置了容器内数据的挂载卷，此后目录`/mnt/1TB_disk/AList`存储的就是容器中目录`/opt/alist/data`的数据内容

安装完成后，可以使用以下命令设置用户名与密码：

```bash
docker exec -it alist ./alist admin set NEW_PASSWORD
```

## AList配置

AList安装完成后，浏览器输入`127.0.0.1:5244`即可访问系统前端，输入正确的账户名密码后即可进入系统主页

### 添加存储

系统主页在未配置存储的情况下是什么都没有的，需要点击下方的【管理】进入管理界面添加存储：在管理页面的侧边导航栏点击【存储】，选择【添加】进入添加存储页面

可以提前在`/mnt/1TB_disk/AList`中创建一个`local`文件夹，用于存储将来的云盘数据

- 在【驱动】下拉框选择【本机存储】，表示要添加的存储类型是本机的存储

- 【挂载路径】就是在AList前端能看到的目录，这里可以设置为`/本地`

- 【根文件夹路径】要格外注意，这个属性指的是这个存储中的文件将要被放置到的目录，这里设置为`/opt/alist/data/local`，因为`/opt/alist/data`对应着树莓派的`/mnt/1TB_disk/AList`目录，所以实际上文件会被存储在`/mnt/1TB_disk/AList/local`中

  > 如果这个属性没有设置到挂载的硬盘上，会导致之后所有本地文件都存储在树莓派自己的存储空间中

{{< figure align=center src="../../img/AList配置本地存储.png" height=30% width=30% >}}

以上三个属性配置完成即可，其他的配置保持默认即可，点击【保存】并返回主页即可看到刚刚添加的“本地”文件夹

### 设置WEBDAV

我希望能在AList上实现家庭影院的效果，可以考虑在电视机上安装支持WebDAV播放的软件（例如[KODI](https://kodi.tv/)），然后使用KODI访问AList，由AList提供WebDAV服务即可实现在电视机上观看AList存储中的视频文件

当我安装好AList和KODI后却发现KODI无法访问到AList的WebDAV服务，检查后发现是**当前的admin用户没有使用WebDAV服务的权限**

想要开放权限也十分简单，在【管理】页面选择【用户】，对admin角色的权限进行编辑，开放【WEBDAV读取】和【WEBDAV管理】即可

{{< figure align=center src="../../img/AList编辑权限.png">}}

## 参考

[Docker/DockerHub 国内镜像源/加速列表（2月15日更新-长期维护）](https://cloud.tencent.com/developer/article/2485043)

[Windows 11：Docker Desktop 安装和配置指南](https://www.sysgeek.cn/install-docker-desktop-windows-11/)

[AList文档](https://alist.nn.ci/zh/guide/)

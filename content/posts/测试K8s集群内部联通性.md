+++
date = '2025-04-16T19:23:13+08:00'
draft = false
title = '测试K8s集群内部联通性'
tags = ["Kubernetes", "心得"]
categories = ["k8s学习", "经验"]
showToc = false
math = false

+++

设置集群时，有时需要测试集群内部Pod之间的连通性，或是测试DNS服务是否正常

可以使用`kubectl run`命令来创建一个Pod，并指定Pod名称、镜像以及命名空间

例如，创建一个busybox镜像，目的是测试`kube-authen`命名空间下的Pod是否能`ping`通、DNS服务是否生效：

```bash
kubectl run ping-test --image=busybox -n kube-authen -it -- sh
```

以上命令的含义是：在`kube-authen`命名空间内创建一个镜像为busybox的Pod，Pod名称为ping-test，创建后立刻打开一个交互式终端

在终端内即可进行`ping`测试或是`nslookup`测试

---

有时仅需要进行临时测试，测试完毕后需要立刻删除Pod，那么可以执行指令：

```bash
kubectl run ping-test --image=busybox -n kube-authen -it --rm -- ping google.com
```

这里的`--rm`参数意为“会话结束后自动删除Pod”

## 注意

如果<u>仅创建了busybox的Pod而没有指定运行命令<u>，例如`kubectl run ping-test --image=busybox -n kube-authen`，则会导致Pod无限重启，原因是：

在未指定命令的情况下，busybox使用默认入口点，默认行为是启动shell，但启动shell后没有可执行的命令，于是shell自动退出，这表现为容器进程退出，K8s即认为容器启动失败并进行自动重启，如此不断循环，产生`CrashLoopBackOff`错误


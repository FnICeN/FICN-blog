+++
date = '2025-01-15T17:16:42+08:00'
draft = false
title = 'kubeadm init 等待超时问题'
tags = ["kubernetes","debug"]
categories = ["k8s学习"]
showToc = false
math = false

+++

## 问题描述

配置master节点时，执行`kubeadm init --config kubeadm-config.yaml --v=5`命令后，执行至初始化Pod步骤时报错：

```
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests". This can take up to 4m0s
[kubelet-check] Initial timeout of 40s passed.

Unfortunately, an error has occurred:
	timed out waiting for the condition
This error is likely caused by:
	- The kubelet is not running
	- The kubelet is unhealthy due to a misconfiguration of the node in some way (required cgroups disabled)
......
```

经过检查，host配置无误，cluster的IP地址也与本机相同

## 解决方案

报错后百度到几个可能有用的解决方法，但没能解决问题，**最后发现是由于个人疏忽，忘记配置containerd**

以下把几种方法列出供参考：

---

修改/lib/systemd/system/kubelet.service，添加kubelet启动参数如下：

```bash
[Service]
ExecStart=/usr/bin/kubelet --kubeconfig=/etc/kubernetes/kubelet.conf --config=/var/lib/kubelet/config.yaml
```

然后重启计算机，执行`sudo kubeadm reset`后重新执行`sudo kubeadm init`

---

到/etc/docker/daemon.json配置文件中，至少添加如下一段内容，修改docker的cgroup驱动：

```json
{
	"exec-opts":["native.cgroupdriver=systemd"]
}
```

然后执行`sudo systemctl restart docker`重启docker，执行`sudo kubeadm reset`并重新`sudo kubeadm init`

---

将docker 的版本换成 19.03.9

kube* 版本换成 kubelet-1.17.3 kubeadm-1.17.3 kubectl-1.17.3

---

**以上几种方法都没能解决问题，后来发现问题也许出在containerd上**

以下是解决了我的问题的方案：

首先进行初始化：`mkdir -p /etc/containerd`，然后生成配置文件：`containerd config default | sudo tee /etc/containerd/config.toml`

然后编辑配置文件：`sudo vi /etc/containerd/config.toml`：

```toml
[plugins."io.containerd.grpc.v1.cri"]
# k8s.gcr.io/pause:3.6改为"registry.aliyuncs.com/google_containers/pause:3.9" 
sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.9"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
# SystemdCgroup，false改为true
SystemdCgroup = true
[plugins."io.containerd.grpc.v1.cri".registry]
# config_path，配置镜像加速地址（此目录之后手动创建）
config_path = "/etc/containerd/certs.d"
```

然后创建目录：`mkdir /etc/containerd/certs.d/docker.io -pv`，在`docker.io`中新建一个`hosts.toml`文件，文件中的镜像链接是[配置docker](Docker配置阿里云镜像后仍报错问题.md)时得到的镜像链接：

```toml
# hosts.toml
server = "https://docker.io"
[host."https://ok5mwqnl.mirror.aliyuncs.com"]
  capabilities = ["pull", "resolve"]
```

配置并加载containerd的内核模块：`sudo vi /etc/modules-load.d/containerd.conf`：

```bash
# containerd.conf
overlay
br_netfilter
```

最后执行`sudo modprobe overlay`、`sudo modprobe br_netfilter`即可

## 参考

[历尽艰辛的问题：Waiting for the kubelet to boot up the control plane......This can take up to 4m0s](https://huaweidevelopers.csdn.net/65b9e520dafaf23eeaee798d.html?dp_token=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpZCI6NTQ0OTEzOSwiZXhwIjoxNzM3NDQ3NzAxLCJpYXQiOjE3MzY4NDI5MDEsInVzZXJuYW1lIjoibTBfNjIwNDA3NDEifQ.Z9ImbTUUOBplKtoKKG3vPc8MVNsw2VOtHwEH5eCebY8)

[关于Kubernetes-v1.23.6-初始化时报错[kubelet-check] It seems like the kubelet isn't running or healthy](https://www.cnblogs.com/5201351/p/17378926.html)

[k8s初始化master失败 Waiting for the kubelet to boot up the control plane asInitial timeout of 40s passed.](https://blog.csdn.net/weixin_43639667/article/details/144606574)

[ubuntu20.04安装Kubernetes(k8s 1.27.4)](https://www.cnblogs.com/tjw-bk/p/17566029.html)

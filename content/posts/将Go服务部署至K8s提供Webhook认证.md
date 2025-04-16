+++
date = '2025-04-10T15:02:05+08:00'
draft = false
title = '将Go服务部署至K8s提供Webhook认证'
tags = ["Docker", "Kubernetes", "Containerd", "心得"]
categories = ["经验"]
showToc = true
math = false

+++

以之前构建完成的Webhook工程为例，将此Go应用部署至k8s中并指定为认证服务器

## 构建镜像

在工程根目录创建`Dockerfile`：

```bash
FROM alpine:3.17
WORKDIR /app
# 复制已编译好的二进制文件（此处hook-demo为已构建的Go应用）
COPY hook-demo /app/
# 设置可执行权限
RUN chmod +x /app/hook-demo
# 暴露服务端口
EXPOSE 9999
# 运行应用
CMD ["/app/hook-demo"]
```

在`Dockerfile`所在目录中，运行`sudo docker build -t webhook-auth:v1.0 .`

完成后检查：

```bash
ficn@master:~/k8s-webhook-auth$ sudo docker images
REPOSITORY     TAG       IMAGE ID       CREATED          SIZE
webhook-auth   v1.0      536c17b2a66c   13 seconds ago   31.8MB
alpine         3.17      775f483016a7   7 months ago     7.08MB
```

## Pod与Service部署

创建`deploy-webhook.yaml`：

```yaml
# ~/deploy/deploy-webhook.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-auth
  namespace: kube-system  # 命名空间
  labels:
    app: webhook-auth
spec:
  replicas: 1  # 本地开发环境，使用单个副本
  selector:
    matchLabels:
      app: webhook-auth
  template:
    metadata:
      labels:
        app: webhook-auth
    spec:
      containers:
      - name: webhook-auth
        image: webhook-auth:v1.0  # 本地镜像名称
        imagePullPolicy: Never  # 强制使用本地镜像，不尝试从远程拉取
        ports:
        - containerPort: 9999  # webhook实际端口
          name: http
```

创建`service-webhook.yaml`：

```yaml
# ~/deploy/service-webhook.yaml
apiVersion: v1
kind: Service
metadata:
  name: webhook-auth-svc
  namespace: kube-system  # 与Deployment使用相同的命名空间
spec:
  ports:
  - port: 443  # 外部访问端口，通常使用标准HTTPS端口
    targetPort: 9999  # 指向容器的9999端口
    name: https
  selector:
    app: webhook-auth
```

## docker镜像导入containerd

k8s在较新的版本中移除了`dockershim`，默认使用`containerd`作为容器运行时，所以想要使集群正确找到并识别容器镜像，需要将该镜像导入至containerd中

在master机，将docker镜像导出为`.tar`文件：

```bash
ficn@master:~/deploy$ sudo docker save > webhook-auth.tar webhook-auth
```

然后使用`scp`命令将该文件传输至工作节点：

```bash
# 提前在node上创建 ~/images 目录
ficn@master:~/deploy$ scp webhook-auth.tar node@192.168.92.129:~/images
```

最后在工作节点上，使用`ctr`导入镜像，同时指定导入的命名空间为`k8s.io`：

```bash
# cd ~/images
node@node01:~/images$ sudo ctr -n k8s.io images import webhook-auth.tar
```

## 配置API-Server

编写webhook配置文件`/etc/kubernetes/pki/webhook.json`：

```json
{
  "kind": "Config",
  "apiVersion": "v1",
  "preferences": {},
  "clusters": [
    {
      "name": "github-authn",
      "cluster": {
        "server": "http://webhook-auth-svc.kube-system.svc.cluster.local:9998/auth"
      }
    }
  ],
  "users": [
    {
      "name": "authn-apiserver",
      "user": {
        "token": "secret"
      }
    }
  ],
  "contexts": [
    {
      "name": "webhook",
      "context": {
        "cluster": "github-authn",
        "user": "authn-apiserver"
      }
    }
  ],
  "current-context": "webhook"
}
```

> If the `<cluster-ip>` is an IPv4 address, an `A` record of the following form must exist.
>
> - Record Format:
>   - `<service>.<ns>.svc.<zone>. <ttl> IN A <cluster-ip>`
> - Question Example:
>   - `kubernetes.default.svc.cluster.local. IN A`
> - Answer Example:
>   - `kubernetes.default.svc.cluster.local. 4 IN A 10.3.0.1`

编辑`/etc/kubernetes/manifests/kube-apiserver.yaml`，增加以下配置以选择Webhook认证模式：

```yaml
spec:
  containers:
  - command:
  - ...
  - --authentication-token-webhook-config-file=/etc/kubernets/pki/webhook.json
  - --authentication-token-webhook-version=v1
  - ...
```

## 参考

[K8S容器运行时由docker变为containerd后的必知必会](https://hex-go.github.io/posts/kubernetes/2024-09-10-k8s-%E7%94%B1docker%E8%BF%81%E7%A7%BB%E8%87%B3containerd%E5%90%8E%E7%9A%84%E6%94%B9%E5%8F%98/)

[有关Service DNS的文档](https://github.com/kubernetes/dns/blob/master/docs/specification.md)

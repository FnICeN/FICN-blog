+++
date = '2026-06-01T19:46:35+08:00'
draft = false
title = '无外网环境使用helm部署Falco'
tags = ["Falco","Docker","Kubernetes","心得"]
categories = ["经验"]
showToc = true
math = false

+++

## 背景

在K8s集群中，希望引入Falco进行统一的集群操作审计

这就需要先安装Falco，借助`json`插件与`k8saudit`插件创建一个Webhook客户端，专用于接收API Server的操作审计数据

当前已有`falco:0.44.0`镜像，以及一个Falco的`custom_values.yaml`：

```yaml
driver:
  enabled: false

collectors:
  enabled: false

controller:
  kind: deployment

services:
  - name: k8saudit-webhook
    type: NodePort
    ports:
      - port: 9765
        protocol: TCP

falco:
  rules_files:
    - /etc/falco/k8s_audit_rules.yaml
    - /etc/falco/rules.d

  plugins:
    - name: k8saudit
      library_path: /usr/share/falco/plugins/libk8saudit.so
      init_config: ""
      open_params: "http://:9765/k8s-audit"

    - name: json
      library_path: /usr/share/falco/plugins/libjson.so
      init_config: ""

  load_plugins:
    - k8saudit
    - json

  json_output: true
  json_include_output_property: true
  json_include_tags_property: true
```

{{< admonition tip "关于格式" >}}values文件的格式可参考：https://raw.githubusercontent.com/falcosecurity/charts/refs/heads/master/charts/falco/values.yaml{{< /admonition >}}

在机器可以访问外网的情况下，执行`helm install falco falcosecurity/falco -n kube-audit -f custom_values.yaml`即可将Falco部署到集群

但我们的集群无法访问外网，**首先拉取不到Chart，其次也拉取不到`falcoctl`以及两个插件，甚至连插件的`index`文件都无法获取**

因此，需要考虑离线安装Falco

## 手动下载Chart

执行：

```bash
wget https://github.com/falcosecurity/charts/releases/download/falco-9.0.0/falco-9.0.0.tgz
```

即可获取`falco-9.0.0.tgz`Chart文件，如此一来，Chart的本地化解决

## falcoctl离线安装

在Pod启动时，会尝试拉取`falcoctl`容器镜像，它会被自动配置为Falco Pod的一个Init Container，用于管理安全规则Rules、插件Plugins

而master在离线情况下无法拉取`falcoctl`镜像，需要在其他可访问外网的机器上先拉取`falcoctl:0.13.0`镜像，然后将镜像上传至集群内部的Harbor镜像仓库，并在`custom_values.yaml`中注明镜像地址：

```yaml
falcoctl:
  image:
    # 镜像仓库地址
    registry: 192.168.5.96:30003
    repository: falco/falcoctl
    tag: "0.13.0"
```

如此，集群即可正常从本地镜像仓库拉取`falcoctl`镜像

## 插件与规则离线安装

尽管现在可以正常拉取`falcoctl`，但`falcoctl`启动后还会尝试先从https://falcosecurity.github.io/falcoctl/index.yaml拉取所有默认插件与规则的详细信息，master不具备外网环境所以会拉取失败

此外，即使将此URL的内容放入内网，其中指向的插件仓库仍然在外网，master无法拉取

```bash
master@master:~/audit/falco$ kubectl logs falco-6c6ffbb495-zr2n7 -n kube-audit -c falcoctl-artifact-install

{"level":"ERROR","msg":"unable to fetch index \"falcosecurity\" with URL \"https://falcosecurity.github.io/falcoctl/index.yaml\": unable to fetch index: cannot fetch index: Get \"https://falcosecurity.github.io/falcoctl/index.yaml\": dial tcp: lookup falcosecurity.github.io on 10.244.0.10:53: server misbehaving","timestamp":"2026-06-01 09:19:25"}
```

至此，有两条路可以选择：

- 自定义index文件内容，使其中所有规则、插件的仓库都指向内网的OCI仓库，将所有需要的插件、规则都放入内网仓库
- 基于`falco`镜像构建一个新镜像，内部原生拥有所需的规则与插件，就无需再去下载了

鉴于实施复杂度，最后我决定使用第二个方案

### 获取插件

一般来说，应该由一个可访问外网的机器将镜像构建好，然后上传至内网仓库，由master拉取并使用。但我当前可访问外网的机器CPU架构与master不同，前者是x86，后者是arm64，如果直接在前者构建镜像，则无法正常运行于master

因此决定，**首先在该机器上获取`.so`插件，然后将插件、规则yaml统一转移到master机，在master机上进行构建**

在index文件中可以看到两个需要安装的插件信息：

```yaml
- name: json
  type: plugin
  registry: ghcr.io
  repository: falcosecurity/plugins/plugin/json
  signature:
    cosign:
        certificate-oidc-issuer: https://token.actions.githubusercontent.com
        certificate-oidc-issuer-regexp: ""
        certificate-identity: ""
        certificate-identity-regexp: https://github.com/falcosecurity/plugins/
        certificate-github-workflow: ""
        key: ""
        ignore-tlog: false
  description: Extract values from any JSON payload
  home: https://github.com/falcosecurity/plugins/tree/main/plugins/json
  keywords:
    - json-events
    - json-payload
    - extractor
    - json
  license: Apache-2.0
  maintainers:
    - email: cncf-falco-dev@lists.cncf.io
      name: The Falco Authors
  sources:
    - https://github.com/falcosecurity/plugins/tree/main/plugins/json
- name: k8saudit
  type: plugin
  registry: ghcr.io
  repository: falcosecurity/plugins/plugin/k8saudit
  signature:
    cosign:
        certificate-oidc-issuer: https://token.actions.githubusercontent.com
        certificate-oidc-issuer-regexp: ""
        certificate-identity: ""
        certificate-identity-regexp: https://github.com/falcosecurity/plugins/
        certificate-github-workflow: ""
        key: ""
        ignore-tlog: false
  description: Read Kubernetes Audit Events and monitor Kubernetes Clusters
  home: https://github.com/falcosecurity/plugins/tree/main/plugins/k8saudit
  keywords:
    - audit
    - audit-log
    - audit-events
    - kubernetes
    - k8saudit
  license: Apache-2.0
  maintainers:
    - email: cncf-falco-dev@lists.cncf.io
      name: The Falco Authors
  sources:
    - https://github.com/falcosecurity/plugins/tree/main/plugins/k8saudit
```

可以看到，插件作为OCI Artifact存在GHCR，而非普通`.so`文件

要获取这样的文件，可以使用`oras`：

```bash
mkdir -p plugins/k8saudit
oras pull \
--platform linux/arm64 \
-o ./plugins/k8saudit \
ghcr.io/falcosecurity/plugins/plugin/k8saudit:0.7.0
```

另一个插件：

```bash
mkdir plugins/json
oras pull \
  --platform linux/arm64 \
  -o ./plugins/json \
  ghcr.io/falcosecurity/plugins/plugin/json:0.7.0
```

得到的是`.tar.gz`压缩文件，解压即可

---

关于yaml规则文件，不存在架构适配问题，在任意机器上都可以获取，甚至可以直接`wget`

### 构建镜像

**在master机上进行构建操作**

首先创建目录结构：

```bash
mkdir -p ~/falco-offline-arm64-build/plugins
mkdir -p ~/falco-offline-arm64-build/rules
mkdir -p ~/falco-offline-arm64-build/config.d
```

接下来将两个`.so`插件放入`plugins`，将yaml规则文件放入`rules`，再在`config.d`中创建空文件`falco.container_plugin.yaml`，用于禁用默认情况下启动`container`插件

{{< admonition note "关于container" >}}禁用container插件的行为完全是我经验之谈，因为调试时Pod经常报错找不到container插件

后来分析感觉其实不一定要禁用，只要作为其替代的k8saudit起来就行{{< /admonition >}}

设置权限：

```bash
chmod 0755 ~/falco-offline-arm64-build/plugins/libjson.so
chmod 0755 ~/falco-offline-arm64-build/plugins/libk8saudit.so
chmod 0644 ~/falco-offline-arm64-build/rules/k8s_audit_rules.yaml
```

在`~/falco-offline-arm64-build`下创建Dockerfile：

```dockerfile
FROM docker.io/falcosecurity/falco:0.44.0

USER root

RUN mkdir -p /usr/share/falco/plugins \
    && mkdir -p /etc/falco/rules.d \
    && mkdir -p /etc/falco/config.d

COPY plugins/libk8saudit.so /usr/share/falco/plugins/libk8saudit.so
COPY plugins/libjson.so /usr/share/falco/plugins/libjson.so
COPY rules/k8s_audit_rules.yaml /etc/falco/k8s_audit_rules.yaml

# 覆盖默认启用 container 插件的配置，避免 load_plugins: [container]
COPY config.d/falco.container_plugin.yaml /etc/falco/config.d/falco.container_plugin.yaml

RUN chmod 0755 /usr/share/falco/plugins/libk8saudit.so \
    && chmod 0755 /usr/share/falco/plugins/libjson.so \
    && chmod 0644 /etc/falco/k8s_audit_rules.yaml \
    && ls -l /usr/share/falco/plugins \
    && ls -l /etc/falco/k8s_audit_rules.yaml
```

注意这里`FROM`的镜像要与master上原有的`falco`版本一致，即“根据此镜像扩展”

最后构建镜像：

```bash
sudo docker build -t falcosecurity/falco:offline-arm64 .
```

验证镜像架构：

```bash
sudo docker image inspect falcosecurity/falco:offline-arm64 \
  --format '{{.Architecture}}/{{.Os}}'
```

验证三个文件存在：

```bash
sudo docker run --rm \
  --entrypoint /bin/sh \
  falcosecurity/falco:offline-arm64 \
  -c 'ls -l /usr/share/falco/plugins/libjson.so /usr/share/falco/plugins/libk8saudit.so /etc/falco/k8s_audit_rules.yaml'
```

做完这些，只需要将此镜像上传至内网镜像仓库

### 禁用自动安装

需要在`custom_values.yaml`中禁止插件的自动安装（因为环境原生就有了），另外还需要注明`falco`镜像的拉取地址

完整的`custom_values.yaml`：

```yaml
image:
  pullPolicy: IfNotPresent
  registry: 192.168.5.96:30003
  repository: falco/falco
  tag: "offline-arm64"

driver:
  enabled: false

collectors:
  enabled: false

controller:
  kind: deployment

services:
  - name: k8saudit-webhook
    type: NodePort
    ports:
      - port: 9765
        protocol: TCP

falco:
  rules_files:
    - /etc/falco/k8s_audit_rules.yaml
    - /etc/falco/rules.d

  plugins:
    - name: k8saudit
      library_path: /usr/share/falco/plugins/libk8saudit.so
      init_config: ""
      open_params: "http://:9765/k8s-audit"

    - name: json
      library_path: /usr/share/falco/plugins/libjson.so
      init_config: ""

  load_plugins:
    - k8saudit
    - json

  json_output: true
  json_include_output_property: true
  json_include_tags_property: true

falcoctl:
  image:
    registry: 192.168.5.96:30003
    repository: falco/falcoctl
    tag: "0.13.0"
  artifact:
    install:
      enabled: false
    follow:
      enabled: false
```

## 执行部署

准备工作已经完全完成了：

- 手动下载Chart，解决Chart无法拉取的问题
- 在内网Harbor镜像仓库准备`falcoctl`镜像，解决无法拉取`falcoctl`的问题
- 提前将插件、规则打包至镜像，解决无法安装插件的问题

执行`helm`部署命令：

```bash
helm install falco ./falco-9.0.0.tgz \
  -n kube-audit \
  -f custom_values.yaml
```

可以看到Pod成功Running：

```bash
master@master:~/audit/falco$ kubectl get pods -n kube-audit
NAME                     READY   STATUS    RESTARTS   AGE
falco-6c455cd6f9-h8472   1/1     Running   0          127m
```

Service资源：

```bash
master@master:~/audit/falco$ kubectl get svc -n kube-audit
NAME                     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
falco-k8saudit-webhook   NodePort   10.244.115.57   <none>        9765:31169/TCP   135m
```


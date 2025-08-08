+++
date = '2025-06-10T10:03:08+08:00'
draft = false
title = '为K8s集群配置基于Keycloak的认证'
tags = ["Kubernetes", "Keycloak", "心得"]
categories = ["k8s学习"]
showToc = true
math = false

+++

## 配置证书

由于之后要将keycloak接入k8s，所以Keycloak提供的服务必须也是HTTPS的，需要先生成crt和key文件

不过之前已经配置过Dex的HTTPS，所以可以直接将`dex.crt`和`dex.key`拿来用，这里直接将两个文件设置为`kubectl`的`secret`资源：

```bash
kubectl create secret generic keycloak-tls-secret --from-file=tls.crt=./dex.crt   --from-file=tls.key=./dex.key -n keycloak
```

如此配置后，只要注明secret名称：`keycloak-tls-secret`，`tls.crt`和`tls.key`可以随时被Pod挂载至目录中供引用

## 安装、运行Keycloak

首先获取Keycloak的部署配置文件，执行：

```bash
wget https://gh-proxy.com/raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/kubernetes/keycloak.yaml
```

接着对文件作出修改：

1. 使用`volumes`和`volumeMounts`将`keycloak-tls-secret`挂载至容器目录`/etc/x509/https`

   ```yaml
   volumes:
     - name: keycloak-tls
       secret:
         secretName: keycloak-tls-secret
   ...
   volumeMounts:
      - name: keycloak-tls
        mountPath: /etc/x509/https
        readOnly: true
   ```

2. 设置环境变量，开启HTTPS并设置端口8443，引用挂载的证书和秘钥文件

   ```yaml
   env:
     - name: KC_HTTPS_CERTIFICATE_FILE
       value: /etc/x509/https/tls.crt
     - name: KC_HTTPS_CERTIFICATE_KEY_FILE
       value: /etc/x509/https/tls.key
     - name: KC_HTTPS_PORT
       value: "8443"
     - name: KC_HTTP_ENABLED
       value: "false"
   ...
   ports:
     - name: https
       containerPort: 8443
   ```

3. 设置NodePort将服务暴露，可以映射为：`8443 -> 30443`

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: keycloak
     labels:
       app: keycloak
   spec:
     ports:
       - protocol: TCP
         port: 8443
         targetPort: 8443
         name: https
         nodePort: 30443
     selector:
       app: keycloak
     type: NodePort
   ```

最终的`keycloak.yaml`文件：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  ports:
    - protocol: TCP
      port: 8443
      targetPort: 8443
      name: https
      nodePort: 30443
  selector:
    app: keycloak
  type: NodePort
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: keycloak
  name: keycloak-discovery
spec:
  selector:
    app: keycloak
  publishNotReadyAddresses: true
  clusterIP: None
  type: ClusterIP
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  serviceName: keycloak-discovery
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.2.5
          args: ["start"]
          env:
            - name: KC_HTTPS_CERTIFICATE_FILE
              value: /etc/x509/https/tls.crt
            - name: KC_HTTPS_CERTIFICATE_KEY_FILE
              value: /etc/x509/https/tls.key
            - name: KC_HTTPS_PORT
              value: "8443"
            - name: KC_HTTP_ENABLED
              value: "false"
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: "admin"
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              value: "admin"
            - name: KC_PROXY_HEADERS
              value: "xforwarded"
            - name: KC_HOSTNAME_STRICT
              value: "false"
            - name: KC_HEALTH_ENABLED
              value: "true"
            - name: 'KC_CACHE'
              value: 'ispn'
            - name: 'KC_CACHE_STACK'
              value: 'kubernetes'
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: JAVA_OPTS_APPEND
              value: '-Djgroups.dns.query="keycloak-discovery" -Djgroups.bind.address=$(POD_IP)'
            - name: 'KC_DB_URL_DATABASE'
              value: 'keycloak'
            - name: 'KC_DB_URL_HOST'
              value: 'postgres'
            - name: 'KC_DB'
              value: 'postgres'
            - name: 'KC_DB_PASSWORD'
              value: 'keycloak'
            - name: 'KC_DB_USERNAME'
              value: 'keycloak'
          ports:
            - name: https
              containerPort: 8443
          volumeMounts:
            - name: keycloak-tls
              mountPath: /etc/x509/https
              readOnly: true
          startupProbe:
            httpGet:
              scheme: HTTPS
              path: /health/started
              port: 9000
          readinessProbe:
            httpGet:
              scheme: HTTPS
              path: /health/ready
              port: 9000
          livenessProbe:
            httpGet:
              scheme: HTTPS
              path: /health/live
              port: 9000
          resources:
            limits:
              cpu: 2000m
              memory: 2000Mi
            requests:
              cpu: 500m
              memory: 1700Mi
      volumes:
        - name: keycloak-tls
          secret:
            secretName: keycloak-tls-secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          # 使用国内镜像源
          image: swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/postgres:17
          env:
            - name: POSTGRES_USER
              value: "keycloak"
            - name: POSTGRES_PASSWORD
              value: "keycloak"
            - name: POSTGRES_DB
              value: "keycloak"
            - name: POSTGRES_LOG_STATEMENT
              value: "all"
          ports:
            - name: postgres
              containerPort: 5432
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: postgres-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: postgres
  name: postgres
spec:
  selector:
    app: postgres
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
  type: ClusterIP
```

执行`kubectl apply -f keycloak.yaml -n keycloak`部署即可

当`keycloak`和`postgres`的Pod全部Running后，访问https://192.168.92.128:30443即可看到前端页面（已设置语言本地化）：

![登录页](https://img.fnicen.top/PicGo/keycloak登录页.png)

输入在配置中设置的账户名`admin`和密码`admin`进入管理页面：

![管理页](https://img.fnicen.top/PicGo/keycloak-管理页面.png)

## 配置Keycloak

成功访问Keycloak前端页面后，需要对其进行各项配置，以将其连接至K8s的OIDC认证

创建一个专用于进行K8s认证的领域（Realm），命名为k8s-auth（Keycloak官方并不推荐用户直接在master领域进行各项应用设置），创建后点击切换到该领域中，**之后的各项管理设置操作都将在这个领域中进行**

### 导入LDAP用户

在较新版本的Keycloak侧边导航栏中的【配置】主标签下存在【用户联盟】（User Federation）子标签，点击后选择添加LDAP供应商，即可开始将LDAP服务器中存储的用户信息导入至Keycloak中

| 属性           | 值                          |
| -------------- | --------------------------- |
| 连接地址       | ldap://192.168.92.128:389   |
| 绑定DN         | cn=admin,dc=example,dc=com  |
| 绑定凭据       | 647252                      |
| 编辑模式       | WRITABLE                    |
| 用户DN         | ou=People,dc=example,dc=com |
| 用户名LDAP属性 | cn                          |
| RDN LDAP属性   | cn                          |
| UUID LDAP属性  | cn                          |
| 用户对象类     | inetOrgPerson               |

- 这里的【绑定DN】和【绑定凭据】分别指LDAP服务器中管理员用户的DN和密码
- 原本的LDAP数据库中不存在UUID等字段，因此为了方便，这里将用户名、RDN、UUID都设置为cn

>  在设置连接参数时Keycloak提供了【测试连接】、【测试认证】的功能，可以随时查看填入的参数是否正确

完成后，进行**LDAP到Keycloak用户属性映射关系的设置**，根据LDAP中的字段设置即可，例如`username`字段设置为`cn`，亦即将LDAP数据库中的`cn`映射至Keycloak用户的`username`属性

因为**Keycloak的用户默认没有groups属性**，因此需要在映射处**新增一个映射器**：

![用户groups映射](https://img.fnicen.top/PicGo/groups映射配置.png)

全部完成后，可以在【用户管理】标签页看到导入的LDAP用户：

![导入用户成功](https://img.fnicen.top/PicGo/成功导入用户.png)

点击用户，在详细信息的【群组管理】中也可以确认用户所在群组已经被正确读取：

![用户群组信息](https://img.fnicen.top/PicGo/用户所在群组.png)

### 创建连接的客户端

为了将Keycloak连接至K8s，需要创建一个客户端用于管理连接，创建时，设置：

| 属性            | 值                           |
| --------------- | ---------------------------- |
| 客户端类型      | OpenID Connect               |
| 客户端ID        | keycloak-k8s-auth            |
| 客户端认证      | 开                           |
| 认证流程        | 标准流程、直接访问授权       |
| 根网址          | https://192.168.92.128:30443 |
| 主页URL         | https://192.168.92.128:30443 |
| 有效的重定向URI | http://localhost:8000        |

这里的认证流程原本只有标准流程，**开放【直接访问授权】是为了在之后的测试过程中可以直接通过用户名-密码的形式获取token**，方便开发

客户端创建完成后，从理论上说，只要再将K8s处的API-Server配置好，就可以实现OIDC认证了

但需要注意一点，我们先前在集群中配置的是**根据用户所在用户组确定权限的RBAC策略**，而**Keycloak进行OIDC认证时返回的JWT默认不包含groups字段**，这就需要在客户端设置中添加必要的JWT字段

点击进入客户端后，进入【客户端范围】，选择“此客户端的专用范围和映射器”对应的范围，然后**根据配置添加映射器**：

![客户端groups映射](https://img.fnicen.top/PicGo/客户端groups映射.png)

注意这里最好关闭【Full group path】，否则JWT中的groups字段将成为`/g-admin`的形式

> 另外还可以增加`name`映射等，根据实际需要自由添加

**至此，有关Keycloak的配置告一段落**

- 进入【领域设置】，在页面最下方找到【OpenID Endpoint Configuration】点击进入，可以查看此领域的`issuer`、`authorization_endpoint`、`token_endpoint`等属性
- 进入【客户端】、【客户端详情】、【凭证】处，可以查看并复制客户端密码`client_secret`

可以在终端运行：

```bash
curl -ks -X POST <token_endpoint> -d grant_type=password -d client_id=keycloak-k8s-auth -d username=jack -d password=123456 -d scope=openid -d client_secret=<client_secret>
```

即通过用户名-密码的方式得到Keycloak客户端给出的`refresh_token`、`id_token`等身份参数（这就是开放【直接访问授权】的目的），如果将获得的各参数填入身份文件`config`中，即可完成身份的认证

但很明显现在还不行，因为当前还没有配置API-Server，集群并不识别Keycloak给出的身份参数

## 配置API-Server

API-Server的配置与之前Dex的十分相似，只需要修改`oidc-issuer-url`和`oidc-client-id`即可，这两个字段都已经在之前的操作中获取过，直接填入即可

> 注意之前的Dex配置了`oidc-username-claim=name`，所以确实需要在客户端中新增一个映射字段`name`

API-Server配置完成并成功重启后，**Keycloak已经能够正常接入K8s集群并提供OIDC认证服务**

### 测试

将Keycloak先前提供的`refresh_token`、`id_token`等粘贴至`config`文件、并正确设置文件中的各项参数后，赶在失效时限之前执行`kubectl get nodes`成功，而执行`kubectl get pods -n keycloak`失败，失败原因为无权限：

```bash
ficn@master:~$ kubectl get no
NAME     STATUS   ROLES           AGE     VERSION
master   Ready    control-plane   54d     v1.28.2
node01   Ready    <none>          5d22h   v1.28.2
ficn@master:~$ kubectl get pods -n keycloak
Error from server (Forbidden): pods is forbidden: User "https://192.168.92.128:30443/realms/k8s-auth#jack Bai" cannot list resource "pods" in API group "" in the namespace "keycloak"
```

## 引入kubelogin

当前的Keycloak已经能为集群提供认证服务，但不同于Dex，Keycloak并不会为用户生成一段身份配置代码，当前仅能通过命令得到必要身份参数，然后手动将参数填入身份文件，略显不便

因此可以考虑引入kubelogin，它可以作为kubectl插件发挥作用：在用户执行`kubectl`指令时自动唤起浏览器，并重定向至Keycloak认证服务，用户在浏览器完成认证后，终端执行的`kubectl`指令即可成功运行；本次认证后的身份数据经过一段时间后自动过期，过期后的下次`kubectl`指令将再次唤起浏览器进行认证

### 安装kubelogin

可以直接下载Github的Release版本并手动解压：

```bash
ficn@master:~$ curl -Lo kubelogin.zip https://github.com/int128/kubelogin/releases/download/v1.32.4/kubelogin_linux_amd64.zip
ficn@master:~$ unzip kubelogin.zip
```

解压完成后，将kubelogin移动到`/usr/local/bin/`：`sudo mv kubelogin /usr/local/bin/`，然后检查运行：

```bash
ficn@master:~$ kubelogin --version
kubelogin version v1.32.4
```

### config格式修改

当前的`config`是通过`auth-provider`的方式配合OIDC完成认证的，但如果要引入kubelogin，这种方式就过时了，需要使用`exec`配置来启动`kubelogin`插件：

```yaml
...
users:
- name: jack-my-cluster
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubelogin
      args:
        - get-token
        - --oidc-issuer-url=<issuer>
        - --oidc-client-id=<client-id>
        - --oidc-client-secret=<client-secret>
        - --token-cache-dir=~/.kube/cache/kubelogin
        - --insecure-skip-tls-verify
...
```

可以看到，新版的`config`写法省略了先前的`refresh-token`、`id-token`等硬编码参数，这些参数实际上是交由`kubelogin`去管理了，此时只需要关心OIDC如何提供即可

> 由于使用了自签名证书，系统默认并不信任，需要配置`--insecure-skip-tls-verify`参数，或者将证书加入操作系统信任列表

### 测试

以上全部配置完成后，执行`kubectl get nodes`命令，将自动唤起浏览器进行认证：

![kubelogin唤起](https://img.fnicen.top/PicGo/kubelogin唤起认证.png)

输入用户名`jack`和密码`123456`完成登录后回到终端，可以看到成功获取节点信息：

```bash
ficn@master:~$ kubectl get no
NAME     STATUS   ROLES           AGE     VERSION
master   Ready    control-plane   54d     v1.28.2
node01   Ready    <none>          5d22h   v1.28.2
```

## 参考

[【官方】在 Kubernetes 上开始使用 Keycloak](https://keycloak.com.cn/getting-started/getting-started-kube)

[在 Kubernetes 中使用 Keycloak OIDC Provider 对用户进行身份验证](https://cloud.tencent.com/developer/article/1983889)

+++
date = '2025-05-23T11:25:45+08:00'
draft = false
title = '在K8s集群部署Dex认证'
tags = ["Kubernetes", "心得", "Dex"]
categories = ["经验", "k8s学习"]
showToc = true
math = false

+++

Dex是一个开源的第三方身份认证系统，简化了与已有身份提供者或其他认证服务进行认证的开发流程，Dex将检查身份的过程对项目开发者隐藏，使得开发者只需要关注、控制认证业务进行的客体，无需亲自管理身份认证的各项细节

## 环境

- OS：Debian-12.10.0-amd64
- Kubernetes：v1.28.0
- kubectl：v1.28.2
- Helm：v3.17.3

**master机已安装Git，已部署LDAP服务器**

**开发者没有备案的域名，无法进行DNS A解析，只能使用自签名证书**

## 获取dex-k8s-authenticator

Dex本身是可以直接使用的，但是如果想要将Dex部署至K8s集群中并提供友好的可视页面，则需要部署dex-k8s-authenticator（之后简称DKA）

执行：`git clone https://github.com/mintel/dex-k8s-authenticator.git`克隆该Git仓库，仓库的`charts/`路径中已经存在Dex和DKA的Chart文件，因此无需再单独克隆获取Dex文件

```bash
ficn@master:~$ git clone https://github.com/mintel/dex-k8s-authenticator.git
ficn@master:~$ cd dex-k8s-authenticator/
ficn@master:~/dex-k8s-authenticator$ ls charts/
dex  dex-k8s-authenticator  README.md
```

## 运行Dex和DKA

执行：

```bash
helm inspect values charts/dex > dex-values.yaml
helm inspect values charts/dex-k8s-authenticator > dka-values.yaml
```

这两个指令目的是根据Dex和DKA的原始Chart生成各自的新values文件，用于之后覆盖原配置

接下来就对这两个values文件进行修改

### Dex

```yaml
# sudo vi dex-values.yaml
# Default values for dex
# Deploy environment label, e.g. dev, test, prod
global:
  deployEnv: dev

replicaCount: 1

image:
  repository: dexidp/dex
  tag: v2.37.0
  pullPolicy: IfNotPresent

env:
- name: KUBERNETES_POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace

service:
  type: NodePort
  port: 5556
  nodePort: 30000

  # For nodeport, specify the following:
  #   type: NodePort
  #   nodePort: <port-number>

tls:
  create: false
 
ingress:
  enabled: false
  annotations: {}
    # kubernetes.io/ingress.class: nginx
    # kubernetes.io/tls-acme: "true"
  path: /
  hosts:
    - dex.example.com
  tls: []
  #  - secretName: dex.example.com
  #    hosts:
  #      - dex.example.com

rbac:
  # Specifies whether RBAC resources should be created
  create: true
  
serviceAccount:
  # Specifies whether a ServiceAccount should be created
  create: true
  # The name of the ServiceAccount to use.
  # If not set and create is true, a name is generated using the fullname template
  name:

resources: {}

nodeSelector: {}

tolerations: []

affinity: {}


# Configuration file for Dex
# Certainly secret fields can use environment variables
#
config: |-
  issuer: http://192.168.92.128:30000

  storage:
    type: kubernetes
    config:
      inCluster: true

  web:
    http: 0.0.0.0:5556

    # If enabled, be sure to configure tls settings above, or use a tool
    # such as let-encrypt to manage the certs.
    # Currently this chart does not support both http and https, and the port
    # is fixed to 5556
    #
    # https: 0.0.0.0:5556
    # tlsCert: /etc/dex/tls/tls.crt
    # tlsKey: /etc/dex/tls/tls.key

  frontend:
    theme: "coreos"
    issuer: "Example Co"
    issuerUrl: "https://example.com"
    logoUrl: https://example.com/images/logo-250x25.png

  expiry:
    signingKeys: "6h"
    idTokens: "24h"
  
  logger:
    level: debug
    format: json

  oauth2:
    responseTypes: ["code", "token", "id_token"]
    skipApprovalScreen: true

  # Remember you can have multiple connectors of the same 'type' (with different 'id's)
  # If you need e.g. logins with groups for two different Microsoft 'tenants'
  connectors:
  # These may not match the schema used by your LDAP server
  # https://github.com/coreos/dex/blob/master/Documentation/connectors/ldap.md
  - type: ldap
    id: ldap
    name: LDAP
    config:
      host: 192.168.92.128:389
      insecureNoSSL: true
      startTLS: false
      bindDN: cn=admin,dc=example,dc=com
      bindPW: "647252"
      userSearch:
        # Query should be "(&(objectClass=inetorgperson)(cn=<username>))"
        baseDN: ou=People,dc=example,dc=com
        filter: "(objectClass=inetorgperson)"
        username: cn
        # DN must be in capitals
        idAttr: DN
        emailAttr: mail
        nameAttr: cn
        preferredUsernameAttr: cn
      groupSearch:
        # Query should be "(&(objectClass=groupOfUniqueNames)(uniqueMember=<userAttr>))"
        baseDN: ou=Group,dc=example,dc=com
        filter: ""
        # DN must be in capitals
        userAttr: DN
        groupAttr: member
        nameAttr: cn

  # The 'name' must match the k8s API server's 'oidc-client-id'
  staticClients:
  - id: my-cluster
    name: "my-cluster"
    secret: "pUBnBOY80SnXgjibTYM9ZWNzY2xreNGQok"
    redirectURIs:
    - http://192.168.92.128:30001/callback
  
  enablePasswordDB: True
  staticPasswords:
  - email: "admin@example.com"
    # bcrypt hash of the string "password"
    hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
    username: "admin"
    userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"  


# You should not enter your secrets here if this file will be stored in source control
# Instead create a separate file to hold or override these values
# You need only list the environment variables you used in the 'config' above
# You can add any additional ones you need, or remove ones you don't need
#
envSecrets:
  # GitHub
  GITHUB_CLIENT_ID: "override-me"
  GITHUB_CLIENT_SECRET: "override-me"
  # Google (oidc)
  GOOGLE_CLIENT_ID: "override-me"
  GOOGLE_CLIENT_SECRET: "override-me"
  # Microsoft
  MICROSOFT_APPLICATION_ID: "override-me"
  MICROSOFT_CLIENT_SECRET: "override-me"
  # LDAP
  LDAP_BINDPW: "123456"
```

如上所示：

- 所有原Chart中出现 `https://dex.example.com` 或 `https://login.example.com` 的地方，**改为实际访问地址**，如 `http://<NodeIP>:<NodePort>`，在这里写为http://192.168.92.128:30000或http://192.168.92.128:30001，30000是Dex服务的端口，30001是DKA的端口，即前端页面端口，如果这里设置错误，在Dex的日志中会报错：

  ```bash
  {"level":"error","msg":"Failed to get auth request: invalid kubernetes resource name: must match the pattern ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ and be no longer than 63 characters","time":"2025-05-21T02:50:55Z"}
  ```

  且会导致前端页面提示`Database Error`错误，这里的报错其实不是命名资源不规范的问题（我调整了很久也没有找到哪里不规范），实际上就是**错将回调地址的端口30001写成30000**导致了这个问题的出现

- 设置service字段，配置**类型**为`NodePort`、容器**内部端口**`port`和**外部端口**`nodePort`，注意`nodePort`需要和实际访问地址的`<NodePort>`保持一致

- 原配置中给出了多种Connector的示例写法，仅保留**LDAP Connector**并根据实际情况作相应配置，包括修改`envSecrets`中的`LDAP_BINDPW`，这里我为了稳定还做了硬编码，不太解耦，不推荐

- 原配置的Dex版本为v2.27.0，这个版本的Dex与版本高于v1.21的K8s之间**存在适配bug**，Pod会报错：

  ```bash
  failed to initialize storage: failed to inspect service account token: jwt claim "kubernetes.io/serviceaccount/namespace" not found
  ```

  官方在Dex v2.30.0之后修复了这个bug，因此需要将`image.tag`版本**替换为新版**，此处换为v2.37.0

  > env字段是我为了解决这个bug时插入的新配置，更新Dex版本后原问题解决，但我并没有移除这个env配置

此外，无需单独使用诸如`kubectl apply -f service.yaml`之类的命令单独配置Service，因为在之后进行Chart部署时会自动设置`NodePort`相应的`Service`

### DKA

```yaml
# dka-values.yaml
# Default values for dex-k8s-authenticator.
# Deploy environment label, e.g. dev, test, prod
global:
  deployEnv: dev

replicaCount: 1

image:
  repository: mintel/dex-k8s-authenticator
  tag: 1.4.0
  pullPolicy: Always

imagePullSecrets: {}

dexK8sAuthenticator:
  port: 5555
  debug: false
  web_path_prefix: /
  #logoUrl: http://<path-to-your-logo.png>
  #tlsCert: /path/to/dex-client.crt
  #tlsKey: /path/to/dex-client.key
  clusters:
  - name: my-cluster
    short_description: "My Cluster"
    description: "Example Cluster Long Description..."
    client_secret: pUBnBOY80SnXgjibTYM9ZWNzY2xreNGQok
    issuer: http://192.168.92.128:30000
    k8s_master_uri: https://192.168.92.128:6443
    client_id: my-cluster
    redirect_uri: http://192.168.92.128:30001/callback
    #k8s_ca_uri: https://url-to-your-ca.crt

service:
  annotations: {}
  type: NodePort
  port: 5555
  nodePort: 30001
  # loadBalancerIP: 127.0.0.1

  # For nodeport, specify the following:
  #   type: NodePort
  #   nodePort: <port-number>

ingress:
  enabled: false
  annotations: {}
    # kubernetes.io/ingress.class: nginx
    # kubernetes.io/tls-acme: "true"
  path: /
  hosts:
    - chart-example.local
  tls: []
  #  - secretName: chart-example-tls
  #    hosts:
  #      - chart-example.local

resources: {}
  # We usually recommend not to specify default resources and to leave this as a conscious
  # choice for the user. This also increases chances charts run on environments with little
  # resources, such as Minikube. If you do want to specify resources, uncomment the following
  # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
  # limits:
  #  cpu: 100m
  #  memory: 128Mi
  # requests:
  #  cpu: 100m
  #  memory: 128Mi

caCerts:
  enabled: false
  secrets: []
  # Array of Self Signed Certificates
  # cat CA.crt | base64 -w 0
  #
  #     name: The internal k8s name of the secret we create. It's also used in
  #     the volumeMount name. It must respect the k8s naming convension (avoid
  #     upper-case and '.' to be safe).
  #
  #     filename: The filename of the CA to be mounted. It must end in .crt for
  #     update-ca-certificates to work
  #
  #     value: The base64 encoded value of the CA
  #
  #secrets:
  #- name: ca-cert1
  #  filename: ca1.crt
  #  value: LS0tLS1......X2F
  #- name: ca-cert2
  #  filename: ca2.crt
  #  value: DS1tFA1......X2F

envFrom: []

nodeSelector: {}

tolerations: []

affinity: {}
```

DKA最后会作为Dex的前端页面展示，与位于端口30000的Dex服务共同完成认证业务

DKA的values文件相对更短一些，配置起来也更容易，需要注意以下几点：

- 同样需要设置`NodePort`将服务暴露，这里设置为`5555:30001`
- `dexK8sAuthenticator.clusters.client_id`的值需要与`dex-values.yaml`文件中的`staticClients.id`保持一致
- `dexK8sAuthenticator.clusters.issuer`的值需要与`dex-values.yaml`文件中的`issuer`保持一致
- `dexK8sAuthenticator.clusters.redirect_uri`的值需要与`dex-values.yaml`文件中的`staticClients.redirectURIs`保持一致
- 将`dexK8sAuthenticator.clusters.k8s_master_uri`的值改为集群实际地址
- 注意`dexK8sAuthenticator.clusters.k8s_master_uri`应为**HTTPS**，因为K8s**默认不接受HTTP请求**，如果写为`http://`则会报`Bad Request`错误

### 部署运行

使用`helm`命令部署两个Dex服务：

```bash
ficn@master:~/dex-k8s-authenticator$ helm install dex --namespace dex --values dex-values.yaml charts/dex
ficn@master:~/dex-k8s-authenticator$ helm install dka --namespace dex --values dka-values.yaml charts/dex-k8s-authenticator
```

使用浏览器访问DKA前端页面`192.168.92.128:30001`即可输入LDAP服务器中的用户完成认证，认证成功的页面：

{{< figure align=center src="https://img.fnicen.top/PicGo/DKA1.png">}}

**注意，到目前为止仅仅完成了将Dex部署至集群并成功连接到LDAP，得以在前端页面进行认证的这个操作，还并未将认证接入集群**，因此如果按照上面成功页面进行操作是**无效的**，为此还需要配置API-Server的OIDC

## 认证接入集群

### 生成自签名证书

Dex的配置本身可以不需要HTTPS，完全可以只使用HTTP，例子就是刚刚我们只使用HTTP和本地IP地址就搭建好了Dex，但如果想将Dex连接到K8s集群，则需要在API-Server**配置OIDC**，而较高版本的K8s-APIServer中的`--oidc_issuer_url`**只支持HTTPS**，因此需要为Dex服务生成自签名证书（无需为DKA生成）

Dex是部署在`192.168.92.128:30000`上的，所以在`/etc/kubernetes/pki`执行：

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=192.168.92.128" -addext "subjectAltName=IP:192.168.92.128" -keyout dex.key -out dex.crt
```

如此生成一个有效期为365天的证书`dex.crt`以及私钥`dex.key`，选择在`/etc/kubernetes/pki`路径执行是因为方便之后API-Server的读取，无需再挂载新的目录

### 配置HTTPS

得到自签名证书后，需要**使Dex通过HTTPS而不是HTTP提供服务**，DKA则可以保持HTTP，但DKA的配置文件中有关连接Dex的部分也需要修改

给出Dex配置：

```yaml
# dex-values.yaml
...
# 打开TLS
tls:
  create: true
  certificate: |-      # dex.crt的内容
   -----BEGIN CERTIFICATE-----
   ...
   -----END CERTIFICATE-----
  key: |-      # dex.key的内容
   -----BEGIN PRIVATE KEY-----
   ...
   -----END PRIVATE KEY-----
...
# issuer改为https
config: |-
  issuer: https://192.168.92.128:30000
  web:
    https: 0.0.0.0:5556     # 注意这里也是https
    tlsCert: /etc/dex/tls/tls.crt
    tlsKey: /etc/dex/tls/tls.key
...
```

`staticClients.redirectURIs`可以保持`http://192.168.92.128:30001`不变

相应的，**DKA需要以HTTPS连接Dex，同时还需要连接API-Server**，这需要为DKA加载Dex的证书和K8s的证书：

1. 执行`cat /etc/kubernetes/pki/ca.crt | base64 -w0`得到集群CA的base64编码用于DKA与集群通信
2. 执行`base64 -w 0 dex.crt`得到Dex证书的base64编码用于与Dex通信

进行配置：

```yaml
# dka-values.yaml
...
image:
# tag: 1.4.0
  tag:latest     # 更改镜像版本为最新
...
dexK8sAuthenticator:
  clusters:
  - name: my-cluster
    issuer: https://192.168.92.128:30000
    k8s_ca_pem_base64_encoded: # 集群CA的Base64
...
caCerts:
  enabled: true
  secrets:
  - name: dex-ca
    filename: dex.crt
    value: # dex.crt的内容
...
```

之所以要将镜像版本改为最新，是因为`k8s_ca_pem_base64_encoded`这个属性配置在Github仓库的最新Release版本1.4.0中还并未出现，但确实在代码上已经实现，所以需要将拉取的镜像改为最新版本（具体从哪个版本`k8s_ca_pem_base64_encoded`开始可用我并未了解）即可

之所以一定要添加`k8s_ca_pem_base64_encoded`这个属性配置，是因为DKA最后会生成`config`文件，而使用该文件的`kubectl`需要与API-Server通信，API-Server就需要对请求证书进行验证，否则会报身份验证相关错误

> 先前已存在如`k8s_ca_pem_file`的属性，但其要求必须引用至一个文件，在本地环境开发中较麻烦，因此考虑将证书硬编码至DKA配置中

当`k8s_ca_pem_base64_encoded`设置完成，DKA认证成功后就会在指导页面中自动生成config的证书配置，成功页面如下：

{{< figure align=center src="https://img.fnicen.top/PicGo/DKA2.png">}}

### OIDC

Dex和DKA已完成配置，最后需要将Dex连接到K8s进行认证服务：

```yaml
# sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
...
spec:
  containers:
  - command:
    - kube-apiserver
    - --oidc-issuer-url=https://192.168.92.128:30000
    - --oidc-client-id=my-cluster
    - --oidc-username-claim=name
    - --oidc-groups-claim=groups
    - --oidc-ca-file=/etc/kubernetes/pki/dex.crt
...
```

- `--oidc-issuer-url`需要与Dex配置的`issuer`一致（DKA也是）
- `--oidc-client-id`需要与Dex配置的`staticClients.id`一致（DKA也是）
- `--oidc-username-claim`和`--oidc-groups-claim`分别决定了集群将从JWT数据中的哪个字段读取用户名和用户组
- `--oidc-ca-file`需要指定为之前使用openssl生成的`dex.crt`

至此，Dex、DKA、API-Server之间的所有交互均已配置完成，Dex已经可以作为集群认证时的身份提供者运行

接下来进行测试，需要为用户组赋予相应的权限，检查集群是否能够拦截越权行为

## 赋权

使用LDAP认证的用户为jack，用户组为g-admin，因此可以基于用户组进行权限绑定，这里我授予用户组g-admin查看nodes的权限：

```yaml
# sudo vi node-viewer-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
```

接着创建`ClusterRoleBinding`，将`node-viewer`权限绑定到`g-admin`用户组：

```yaml
# sudo vi gadmin-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gadmin-node-viewer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-viewer
subjects:
- kind: Group
  name: g-admin
  apiGroup: rbac.authorization.k8s.io
```

执行：

```bash
kubectl apply -f node-viewer-role.yaml
kubectl apply -f gadmin-binding.yaml
```

## 测试

按照DKA认证成功后的导引配置用户`config`后，确定已切换到`jack-my-cluster`身份，执行测试：

```bash
ficn@master:~/dex-k8s-authenticator$ kubectl auth can-i get nodes
yes
ficn@master:~/dex-k8s-authenticator$ kubectl auth can-i get pods
no
```

测试结果正常

## 参考

[Helm安装官方文档](https://helm.sh/zh/docs/intro/install/)

[Helm charts for installing 'dex' with 'dex-k8s-authenticator'](https://github.com/mintel/dex-k8s-authenticator/tree/master/charts)

[Kubernetes storage fails to read namespace from jwt and crashloops pod #2082](https://github.com/dexidp/dex/issues/2082)

[k8s_ca_pem_base64_encoded not used? #172](https://github.com/mintel/dex-k8s-authenticator/issues/172)

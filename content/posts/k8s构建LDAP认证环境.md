+++
date = '2025-04-02T16:34:18+08:00'
draft = false
title = '构建基于Webhook的LDAP认证环境'
tags = ["Kubernetes", "LDAP", "心得"]
categories = ["经验"]
showToc = true
math = false

+++

本文章所描述的各操作最终目的是将Webhook服务接入Kubernetes集群的认证流程中

## LDAP安装

---

对于Ubuntu，使用apt安装命令：`apt-get install -y slapd ldap-utils`

安装过程中会出现交互式界面，可以在其中配置管理员密码（不重要，接下来会再次配置）

安装后，slapd服务即开始执行，此时运行`dpkg-reconfigure slapd`命令，对slapd服务再次进行配置

> 如果提示未找到dpkg-reconfigure命令，则执行`sudo apt install debconf`进行安装，若已安装，则可能是dpkg-reconfigure未被配置到PATH中，可以临时使用绝对路径：`sudo /usr/sbin/dpkg-reconfigure slapd`

配置界面将再次出现，在其中设置：

| 属性                   | 配置        |
| ---------------------- | :---------- |
| Omit configuration     | No          |
| DNS domain             | example.com |
| Organization name      | orgldap     |
| Administrator password | 123456      |
| Remove database        | No          |
| Move old database      | Yes         |

初始设置完成后，在终端输入`sudo slapcat`命令即可查看条目：

```bash
ficn@master:~$ sudo slapcat
dn: dc=example,dc=com
objectClass: top
objectClass: dcObject
objectClass: organization
o: orgldap
dc: example
structuralObjectClass: organization
entryUUID: 8056974e-a31a-103f-8e78-156a6f1ed35c
creatorsName: cn=admin,dc=example,dc=com
createTimestamp: 20250401075602Z
entryCSN: 20250401075602.540676Z#000000#000#000000
modifiersName: cn=admin,dc=example,dc=com
modifyTimestamp: 20250401075602Z
```

## 增加条目

---

### 创建组织

创建文件`base.ldif`，设置三个条目，分别为组织管理者、人员组织单位以及组的组织单位

对于组织管理者，只要在基准DN（即`dc=example,dc=com`）上增加`cn=Manager`作为基本名称即可，其`objectClass`为`organizationRole`：

```yaml
dn: cn=Manager,dc=demo,dc=com
objectClass: organizationalRole
cn: Manager
description: 组织管理者
```

对于人员组织单位，应用于存放“人员”条目，设置为：

```yaml
dn: ou=People,dc=demo,dc=com
objectClass: organizationalUnit
ou: People
```

对于组的组织单位，与人员组织单位类似：

```yaml
dn: ou=Group,dc=demo,dc=com
objectClass: organizationalUnit
ou: Group
```

执行`ldapadd -x -D cn=admin,dc=demo,dc=com -w 123456 -f base.ldif`部署实施组织设定

### 增加人员

编写文件`adduser.ldif`：

```yaml
dn: cn=jack,ou=People,dc=demo,dc=com   # 唯一标识DN
changetype: add   # 增加操作
objectClass: inetOrgPerson   # 对象类型
cn: jack   # 通用名称
departmentNumber: 1   # 部门编号
userPassword: 123456   # 用户密码
sn: Zhang    # 姓氏
mail: jack@demo.com   # 邮箱
displayName: 张三   # 姓名
```

执行`ldapadd -x -D cn=admin,dc=demo,dc=com -w 123456 -f adduser.ldif`添加此人员到`ou=People`的组织单位

### 添加到组

此时，成员jack仅归属于`People`组织，可以将该人员同时设置为**一个组的管理员**作为实际的权限应用

为了创建一个管理员组，执行`sudo vi addgroup`：

```yaml
dn: cn=g-admin,ou=Group,dc=example,dc=com
objectClass: groupOfNames
objectClass: top
cn: g-admin
description: 管理员组
member: cn=admin,dc=example,dc=com
```

此即，在`ou=Group,dc=example,dc=com`的基础上，增加一个条目`cn=g-admin,ou=Group,dc=example,dc=com`，这个条目的类型为`groupOfNames`，添加一个用于占位的成员，DN为`cn=admin,dc=example,dc=com`，即在初始设置时确定的系统管理员

> LDAP中常用的用户组类型主要有：
>
> 1. **posixGroup**：兼容POSIX标准的组
>    - 使用`gidNumber`属性标识组ID
>    - 使用`memberUid`属性列出组成员
> 2. **groupOfNames**：成员由完整DN标识的组
>    - 使用`member`属性列出成员的完整DN
> 3. **groupOfUniqueNames**：类似groupOfNames，但使用`uniqueMember`属性
> 4. **groupOfMembers**：相比groupOfNames允许空组存在

接着，将用户jack加入到刚刚创建的`g-admin`组中：

```yaml
# sudo vi add_to_group.ldif
dn: cn=g-admin,ou=Group,dc=example,dc=com
changetype: modify
add: member
member: cn=jack,ou=People,dc=example,dc=com
```

执行`ldapadd -x -D cn=admin,dc=demo,dc=com -w 123456 -f add_to_group.ldif`

## Webhook与认证调用模块

---

### 服务器

创建`main.go`，编写服务器启动主函数：

```go
package main
import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"github.com/golang/glog"
)
var port string
func main() {
	flag.StringVar(&port, "port", "9999", "http server port")
	flag.Parse()
	// 启动httpserver
	wbsrv := WebHookServer{server: &http.Server{
		Addr: fmt.Sprintf(":%v", port),
	}}
	mux := http.NewServeMux()
	mux.HandleFunc("/auth", wbsrv.serve)
	wbsrv.server.Handler = mux
	// 启动协程来处理
	go func() {
		if err := wbsrv.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			glog.Errorf("Failed to listen and serve webhook server: %v", err)
			log.Printf("err")
		}
	}()
	glog.Info("Server started")
	// 优雅退出
	signalChan := make(chan os.Signal, 1)
	signal.Notify(signalChan, syscall.SIGINT, syscall.SIGTERM)
	<-signalChan
	glog.Infof("Got OS shutdown signal, shutting down webhook server gracefully...")
	_ = wbsrv.server.Shutdown(context.Background())
}
```

创建`webhook.go`文件，编写请求处理逻辑：

```go
package main
import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/golang/glog"
	authentication "k8s.io/api/authentication/v1beta1"
	klog "k8s.io/klog/v2"
)
type WebHookServer struct {
	server *http.Server
}
func (ctx *WebHookServer) serve(w http.ResponseWriter, r *http.Request) {
	// 从APIServer中取出body
	// 将body进行拆分, 取出type
	// 根据type, 取出不同的认证数据
	var req authentication.TokenReview
	decoder := json.NewDecoder(r.Body)
	err := decoder.Decode(&req)
	if err != nil {
		klog.Error(err, "decoder request body error.")
		log.Printf("decoder request body error.")
		req.Status = authentication.TokenReviewStatus{Authenticated: false}
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(req)
		return
	}
	// 判断token是否包含':'
	// 如果不包含，则返回认证失败
	if !(strings.Contains(req.Spec.Token, ":")) {
		klog.Error(err, "token invalied.")
		log.Printf("token invalied")
		req.Status = authentication.TokenReviewStatus{Authenticated: false}
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(req)
		return
	}
	// split token, 获取type
	tokenSlice := strings.SplitN(req.Spec.Token, ":", -1)
	glog.Infof("tokenSlice: ", tokenSlice)
	hookType := tokenSlice[0]
	switch hookType {
    //  case "github":
    //  ...
        case "ldap":
            username := tokenSlice[1]
            password := tokenSlice[2]
            log.Printf("username: %s", username)
            log.Printf("password: %s", password)
            err := authByLdap(username, password)
            if err != nil {
                klog.Error(err, "auth by ldap error")
                req.Status = authentication.TokenReviewStatus{Authenticated: false}
                w.WriteHeader(http.StatusUnauthorized)
                _ = json.NewEncoder(w).Encode(req)
                return
            }
            klog.Info("auth by ldap success")
            req.Status = authentication.TokenReviewStatus{Authenticated: true}
            w.WriteHeader(http.StatusOK)
            _ = json.NewEncoder(w).Encode(req)
            return
	}
}
```

这里对请求的处理逻辑是：仅接收类型为`ldap:xxxx`的token，其中冒号之后的内容格式为`username:password`形式，程序将根据用户名与密码查询对应用户信息

### 查询

创建`ldap.go`文件，编写查询逻辑，此处仅实现【查询特定用户所在用户组】功能：

```go
package main
import (
	"crypto/tls"
	"fmt"
	"log"

	"github.com/go-ldap/ldap/v3"
	"github.com/golang/glog"
	"k8s.io/klog/v2"
)
var (
	ldapUrl = "ldap://" + "localhost:389"   // ldap服务默认运行在本地389端口
)
func authByLdap(username, password string) error {
	groups, err := getLdapGroups(username, password)
    // 查询异常
	if err != nil {
		return err
	}
    // 查询成功，此处仅作测试，返回nil表示无异常
	if len(groups) > 0 {
		return nil
	}
	return fmt.Errorf("No matching group or user attribute. Authentication rejected, Username: %s", username)
}
// 获取user的groups
func getLdapGroups(username, password string) ([]string, error) {
	glog.Info("username:password", username, ":", password)
	var groups []string
	config := &tls.Config{InsecureSkipVerify: true}
	ldapConn, err := ldap.DialURL(ldapUrl, ldap.DialWithTLSConfig(config))
	if err != nil {
		glog.V(4).Info("dial ldap failed, err: ", err)
		return groups, err
	}
	defer ldapConn.Close()
	// 绑定身份，这里用待查询身份查询本身份信息；也可以用管理员admin身份执行查询操作
	binduser := fmt.Sprintf("cn=%s,ou=People,dc=example,dc=com", username)
	log.Printf("Attempting to bind with DN: %s", binduser)
	err = ldapConn.Bind(binduser, password)
	if err != nil {
		klog.V(4).ErrorS(err, "bind user to ldap error")
		return groups, err
	}
	userDN := binduser
	// 查询用户成员所在的组名
	// ldapsearch -x -D "cn=jack,ou=People,dc=example,dc=com" -w "123456" -b "ou=Group,dc=example,dc=com" -s sub "(&(objectClass=groupOfNames)(member=cn=jack,ou=People,dc=example,dc=com))" cn
	searchString := fmt.Sprintf("(&(objectClass=groupOfNames)(member=%s))", userDN)
	searchRequest := ldap.NewSearchRequest(
		"ou=Group,dc=example,dc=com",
		ldap.ScopeWholeSubtree,
		ldap.NeverDerefAliases,
		0,
		0,
		false,
		searchString,
		[]string{"cn"},
		nil,
	)
	searchResult, err := ldapConn.Search(searchRequest)
	if err != nil {
		klog.V(4).ErrorS(err, "Group search failed")
		return groups, err
	}
	klog.Infof("Found %d groups for user", len(searchResult.Entries))
    // 从查询结果中解析所属组名，最后返回
	for _, entry := range searchResult.Entries {
		klog.Infof("Processing group: %s", entry.DN)
		for _, attr := range entry.Attributes {
			if attr.Name == "cn" {
				for _, val := range attr.Values {
					groups = append(groups, val)
					klog.Infof("Added group: %s", val)
				}
			}
		}
	}
	return groups, nil
}
```

## 测试

---

对项目进行编译并运行：

```bash
ficn@master:~$ go build -o hook-demo
ficn@master:~$ ./hook-demo
```

在另一个终端，使用`curl`向Webhook运行的localhost:9999发送POST请求：

```shell
# send.sh
# 设置变量
API_SERVER="localhost:9999"
TOKEN="ldap:jack:123456"

# 直接使用curl发送请求
curl -s -X POST \
  "${API_SERVER}/auth" \
  -d '{
    "apiVersion": "authentication.k8s.io/v1",
    "kind": "TokenReview",
    "spec": {
      "token": "'"${TOKEN}"'",
      "audiences": ["https://myserver.example.com", "https://myserver.internal.example.com"]
    }
  }'
```

执行`send.sh`即可：

```bash
ficn@master:~$ ./send.sh 
{"kind":"TokenReview","apiVersion":"authentication.k8s.io/v1","metadata":{"creationTimestamp":null},"spec":{"token":"ldap:jack:123456","audiences":["https://myserver.example.com","https://myserver.internal.example.com"]},"status":{"authenticated":true,"user":{}}}
```

在运行Webhook的终端可以看到以下日志：

```bash
2025/04/03 10:54:24 username: jack
2025/04/03 10:54:24 password: 123456
2025/04/03 10:54:24 Attempting to bind with DN: cn=jack,ou=People,dc=example,dc=com
I0403 10:54:25.023830  298649 ldap.go:70] Found 1 groups for user
I0403 10:54:25.027867  298649 ldap.go:72] Processing group: cn=g-admin,ou=Group,dc=example,dc=com
I0403 10:54:25.027890  298649 ldap.go:78] Added group: g-admin
I0403 10:54:25.029450  298649 webhook.go:78] auth by ldap success
```

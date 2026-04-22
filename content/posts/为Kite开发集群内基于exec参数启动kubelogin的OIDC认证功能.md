+++
date = '2026-04-09T14:26:51+08:00'
draft = false
title = '为Kite开发集群内基于exec参数启动kubelogin的OIDC认证功能'
tags = ["Kite"]
categories = ["二次开发"]
showToc = true
math = false
+++

## 现状

我在集群中使用Keycloak + kubelgoin + Webhook的认证模式，具体流程如下：

1. 在API-Server中将认证模式设置为Webhook模式，由Webhook手动校验OIDC
2. 执行`kubectl`时，`exec`命令启动`kubelogin`，以`device-code`形式唤起Keycloak进行认证
3. 认证完成后Keycloak给出`token`，由kubectl将`id_token`添加到GET请求的`Authorization`字段发送至API-Server
4. API-Server向Webhook POST一个`TokenReview`，Webhook解析`token`、验证后根据规则组装成`UserInfo`发往后续准入环节等

现在项目中引入了[Kite](https://kite.zzde.me/zh/)作为集群管理面板

Kite的底层是通过`K8s-Client`向API-Server发送HTTP请求执行相应操作，本质上与`kubectl`相似，且都需要读取预先配置的`kubeconfig`文件获取配置上下文，如集群地址、当前集群用户、用户证书等

{{< admonition warning "不足" >}}
Kite本身不负责集群身份认证，而是将安全性转移至进入Kite面板的认证。因此Kite虽然原生支持OIDC，但只能支持进入Kite管理界面时的OIDC认证，而非集群内身份认证

也正因这个原因，Kite无法处理`kubeconfig`中配置了`exec`参数动态获取认证凭证的用户，在界面中将该用户上下文显示为不可用状态

为了解决这个问题，Kite创建了一个专用的Service Account，并使用其`token`通过集群认证（将`token`放入`kubeconfig`然后被Kite正常读取使用）
{{< /admonition >}}

## 需求

我需要二次开发Kite，使Kite支持进行集群内OIDC device-code模式认证

1. 用户只需要指定Issuer、client_secret等必要信息，即可提供Keycloak认证界面供用户进行认证
2. 认证通过后，需要能够接收Keycloak响应的各种`token`
3. 记录该`token`，禁用原`kubeconfig`配置
4. 之后调用`K8s-Client`发送API请求时都在`Authorization`字段附加`token`
5. 如果`token`过期，则在前端提示用户需要重新进行OIDC认证
6. 如果请求被准入环节拦截，需要提示用户根据准入规定重新认证 / 增量认证 / 拒绝请求

## 准备

使用Postman测试不带`Authorization`的API请求响应，返回403：

```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "nodes is forbidden: User \"system:anonymous\" cannot list resource \"nodes\" in API group \"\" at the cluster scope",
  "reason": "Forbidden",
  "details": {
    "kind": "nodes"
  },
  "code": 403
}
```

---

使用Postman附带Keycloak客户端ID、客户端Secret向$base_url发送认证请求：

```json
{
  "device_code": "vfpIiDEl8-M7euodTglJTkbUnKr99l7GGDNQK7If0EM",
  "user_code": "PSWY-TSRS",
  "verification_uri": "https://192.168.5.96:31443/realms/k8s-auth/device",
  "verification_uri_complete": "https://192.168.5.96:31443/realms/k8s-auth/device?user_code=PSWY-TSRS",
  "expires_in": 600,
  "interval": 5
}
```

---

认证完成后尝试拉取Token：

```json
{
  "access_token": "<access_token>",
  "expires_in": 180,
  "refresh_expires_in": 180,
  "refresh_token": "<refresh_token>",
  "token_type": "Bearer",
  "id_token": "<id_token>",
  "not-before-policy": 0,
  "session_state": "07976fb2-e9ed-afda-8c03-09bfed348abc",
  "scope": "openid email profile"
}
```

---

将`id_token`填入GET请求的`Authorization`字段后，可以正常获得预期响应；

`id_token`过期后：

```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

## 认证与token获取开发

### 后端

首先在oauth_provider.go中为`GenericProvider`结构体定义获取认证地址与`token`的方法：

```go
func (g *GenericProvider) StartDeviceCodeFlow() (*DeviceCodeResponse, error) {
	// Construct device code endpoint from token URL
	deviceCodeURL := g.TokenURL
	if strings.Contains(deviceCodeURL, "/token") {
		deviceCodeURL = strings.Replace(deviceCodeURL, "/token", "/auth/device", 1)
	}

	data := url.Values{}
	data.Set("client_id", g.Config.ClientID)
	data.Set("client_secret", g.Config.ClientSecret)
	data.Set("scope", g.Config.Scopes)

	req, err := http.NewRequest("POST", deviceCodeURL, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	var deviceCodeResp DeviceCodeResponse
	if err := json.NewDecoder(resp.Body).Decode(&deviceCodeResp); err != nil {
		return nil, err
	}

	return &deviceCodeResp, nil
}

func (g *GenericProvider) PollToken(deviceCode string) (*TokenResponse, error) {
	data := url.Values{}
	data.Set("client_id", g.Config.ClientID)
	data.Set("client_secret", g.Config.ClientSecret)
	data.Set("device_code", deviceCode)
	data.Set("grant_type", "urn:ietf:params:oauth:grant-type:device_code")

	req, err := http.NewRequest("POST", g.TokenURL, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	var tokenResp TokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return nil, err
	}

	return &tokenResp, nil
}
```

然后就可以在`auth/handler.go`中使用预先配置好的OIDC参数创建`GenericProvider`实例，传入参数调用相应方法即可：

```go
func (h *AuthHandler) StartDeviceCodeFlow(c *gin.Context) {
	// 从配置文件中读取OIDC配置
	oidcConfig := GetOIDCConfig()
	if oidcConfig == nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "加载OIDC配置失败",
		})
		return
	}
	issuer := oidcConfig.Issuer
	clientID := oidcConfig.ClientID
	clientSecret := oidcConfig.ClientSecret
	scopes := oidcConfig.Scopes
	// 创建Keycloak的GenericProvider实例
	oauthProvider, err := NewGenericProvider(model.OAuthProvider{
		Name:         "keycloak",
		ClientID:     clientID,
		ClientSecret: model.SecretString(clientSecret),
		Issuer:       issuer,
		Scopes:       scopes,
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to create Keycloak provider: " + err.Error(),
		})
		return
	}
	// 启动device-code认证，返回响应
	deviceCodeResp, err := oauthProvider.StartDeviceCodeFlow()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to start device code flow: " + err.Error(),
		})
		return
	}
	c.JSON(http.StatusOK, deviceCodeResp)
}

func (h *AuthHandler) PollToken(c *gin.Context) {
    // 从请求获取device-code码
	deviceCode := c.Query("device_code")
	if deviceCode == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "device_code parameter is required",
		})
		return
	}
    // 加载OIDC配置
	oidcConfig := GetOIDCConfig()
	if oidcConfig == nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "加载OIDC配置失败",
		})
		return
	}
	issuer := oidcConfig.Issuer
	clientID := oidcConfig.ClientID
	clientSecret := oidcConfig.ClientSecret
	scopes := oidcConfig.Scopes
	// 创建Keycloak的GenericProvider实例
	oauthProvider, err := NewGenericProvider(model.OAuthProvider{
		Name:         "keycloak",
		ClientID:     clientID,
		ClientSecret: model.SecretString(clientSecret),
		Issuer:       issuer,
		Scopes:       scopes,
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to create Keycloak provider: " + err.Error(),
		})
		return
	}
	// 请求token，返回响应
	tokenResp, err := oauthProvider.PollToken(deviceCode)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
		})
		return
	}
	c.JSON(http.StatusOK, tokenResp)
}
```

最后，在启动文件`main.go`中定义后端API：

```go
authHandler := auth.NewAuthHandler()
authGroup := r.Group("/api/auth")
	{
		authGroup.GET("/providers", authHandler.GetProviders)
		authGroup.POST("/login/password", authHandler.PasswordLogin)
		authGroup.GET("/login", authHandler.Login)
		authGroup.GET("/callback", authHandler.Callback)
		authGroup.POST("/logout", authHandler.Logout)
		authGroup.POST("/refresh", authHandler.RefreshToken)
		authGroup.GET("/user", authHandler.RequireAuth(), authHandler.GetUser)
		// OIDC Device Code Flow
		authGroup.GET("/oidc/device-code", authHandler.StartDeviceCodeFlow)
		authGroup.GET("/oidc/token", authHandler.PollToken)
	}
```

只要前端请求`/api/auth/oidc/*`，即可获取到相应消息

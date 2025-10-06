+++
date = '2025-09-24T16:15:21+08:00'
draft = false
title = '为Keycloak配置电子邮件认证'
tags = ["Keycloak", "SMTP"]
categories = ["Keycloak学习"]
showToc = true
math = false

+++

Keycloak原生支持对用户的电子邮件信息进行认证，可以向用户注册的邮箱发送一条确认邮件，点击邮件中的链接后即可完成认证，此认证手段可用于确认邮件信息真实性或修改账户密码时的身份验证

## 开启SMTP服务

Keycloak的电子邮件认证是基于SMTP协议实现的，因此我们需要先在邮箱平台上开通SMTP服务

> SMTP是一组用于从源地址到目的地址传送邮件的规则，并且控制信件的中转方式。[SMTP协议](https://baike.baidu.com/item/SMTP协议/421587?fromModule=lemma_inlink)属于TCP/IP协议族，它帮助每台计算机在发送或中转信件时找到下一个目的地。通过SMTP协议所指定的服务器，我们就可以把E—mail寄到收信人的服务器上了，整个过程只需要几分钟。SMTP服务器是遵循SMTP协议的发送[邮件服务器](https://baike.baidu.com/item/邮件服务器/985736?fromModule=lemma_inlink)，用来发送或中转用户发出的电子邮件。

以QQ邮箱为例，进入【账号与安全】界面——【安全设置】标签，即可开启SMTP服务（可能需要进行手机号验证）：

![](https://img.fnicen.top/PicGo/QQ邮箱SMTP.png)

点击【生成授权码】后，系统将为该邮箱生成一串字符串作为授权码，此为QQ邮箱用于登录第三方客户端 / 服务的专用密码，将会被Keycloak用于登录发件者邮箱

{{< admonition important "重要" >}}更改QQ帐号密码会触发授权码过期，需要重新获取新的授权码登录{{< /admonition >}}

## 配置Keycloak连接

得到授权码后，进入Keycloak管理后台——【领域设置】——【电子邮件】，配置连接与认证的参数：

![](https://img.fnicen.top/PicGo/连接与认证.png)

- 主机：固定填写`smtp.qq.com`，这是QQ邮箱的SMTP主机
- 端口：官方说明端口号为`465`或`587`，一般填`465`即可
- 加密：官方要求启用SSL
- 用户名：填写与授权码对应的完整邮箱地址
- 密码：填写获得的授权码

在上方模板处**还需要配置发件人邮箱地址**，此外还可自定义发件人名称、回复地址等信息

将必要属性配置完成后，点击页面下方【测试连接】确认信息正确，可以收到测试邮件：

![](https://img.fnicen.top/PicGo/收到测试邮件.png)

{{< admonition note "注意" >}}如果想要测试连接，需要提前为当前访问管理后台的用户配置一个邮箱地址{{< /admonition >}}

至此，Keycloak已经能够提供邮件认证功能，可用于验证邮箱有效性或更改账户密码时的身份验证

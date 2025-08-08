+++
date = '2025-07-13T16:26:33+08:00'
draft = false
title = 'Keycloak安装自定义插件及代码解析'
tags = ["Keycloak", "java", "Kubernetes"]
categories = ["Keycloak学习"]
showToc = true
math = false

+++

参考[官方开发示例](https://github.com/keycloak/keycloak-quickstarts/tree/main/extension/authenticator/src/main/java/org/keycloak/examples/authenticator)，使用Java为Keycloak系统编写一套个人隐私问题的认证模块

代码编写完成后，借助Maven将项目打包为jar文件，传输至集群主节点准备部署

> 注意在打包时需要添加`resources/META-INF/services`目录，并注册Factory类

## 导入插件

首先创建初始ConfigMap：

```bash
kubectl create configmap secret-question-plugin --from-file=SecretQuestion.jar=./kc-plugins/SecretQuestion.jar -n keycloak
```

然后执行`kubectl edit statefulset keycloak -n keycloak`对keycloak的StatefulSet进行修改：

```yaml
spec:
  template:
    spec:
      volumes:
      - name: plugins-volume
        configMap:
          name: secret-question-plugin
      containers:
      - name: keycloak
        # 其他配置...
        volumeMounts:
        - name: plugins-volume
          mountPath: /opt/keycloak/providers/SecretQuestion.jar
          subPath: SecretQuestion.jar
```

## 更新插件

之后每次更新迭代插件时，需要先删除原ConfigMap，然后创建新ConfigMap，最后重启Pod即可

```bash
# 删除旧的ConfigMap
kubectl delete configmap secret-question-plugin -n keycloak

# 创建新的ConfigMap
kubectl create configmap secret-question-plugin --from-file=SecretQuestion.jar=./kc-plugins/SecretQuestion.jar -n keycloak

# 重启Keycloak Pod
kubectl delete pod keycloak-0 -n keycloak
```

## 插件代码解析

将插件导入Keycloak系统后，需要先在【身份验证】【必需的操作】处将之开启，然后将自定义的认证执行器插入流程之中，如此才能使新认证功能发挥作用

这里将新认证器放置在“账户密码验证”之后且作为必需行动

1. 当用户首先进入认证界面（账户密码界面）时，仅账户密码认证执行器在发挥作用

2. 当用户点击登录按钮并通过，根据流程，系统应该执行必需的密保问题验证：

   1. 调用`Authenticator`中的`configuredFor()`方法，**检查用户是否已经配置过相应凭证**

      > 关于用户是否配置过相应凭证，可以在UI界面的用户详细信息中查看，一般未配置的话只有password口令凭证

   2. 若`configuredFor()`返回`true`，代表用户配置过这种凭证，则调用此类的`authenticate()`方法正式进入认证：

      1. `authenticate()`向用户**呈现挑战页面**，用户输入答案点击提交后调用`action()`方法
      2. `action()`方法从上下文**获取用户输入的答案**并封装，交由`Provider`提供的`isValid()`方法**验证答案正确性**
      3. 若答案错误，则构建失败页面并呈现，将上下文设置为**失败**状态
      4. 若答案正确，则将上下文设置为**成功**状态

   3. 若`configuredFor()`返回`false`，代表用户从未配置过这种凭证，**但系统流程中又设置了“必需”执行此操作**，因此会调用此类的`setRequiredActions()`中**所注册的Action相应方法**进行操作（此时的情况是需要用户现场创建一个此类型凭证并储存）

      1. `setRequiredActions()`中使用一个`ID`字符串来注册操作，这个`ID`定义在实现了`RequiredActionProvider`接口的`RequiredAction`类中，作为静态不可修改变量
      2. `RequiredAction`类调用`requiredActionChallenge()`方法呈现一个**添加密保问题的界面**，用户输入问题答案后点击提交调用`processAction()`方法
      3. `processAction()`方法从上下文**提取用户输入信息**，再从上下文的`session`中提取`Provider`，调用`Provider`中存储新凭证的`createCredential()`方法即可**保存凭证**
      4. 将上下文设置为**成功**状态

3. 用户通过密保问题，完成认证

如此来看，`Authenticator`类、`RequiredAction`类以及相应的两个`Factory`类都是**工作在逻辑上的业务层以及应用层**的

而`CredentialModel`和`CredentialProvider`则是**工作在数据层**，其中`CredentialModel`更偏向POJO的感觉，仅仅是负责在内存中保存、装填或获取`Model`对象；`CredentialProvider`则负责信息的交互与存储，包括*检查是否已配置凭证*、*检查答案与存储答案是否一致*、*在数据库中增加或删除凭证*等操作，这些都是需要直接与数据库进行交互查询的（虽然查询交互过程也被提前封装了）

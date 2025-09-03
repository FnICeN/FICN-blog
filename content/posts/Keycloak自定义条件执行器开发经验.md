+++
date = '2025-09-03T15:38:09+08:00'
draft = false
title = 'Keycloak自定义条件执行器开发经验'
tags = ["Keycloak", "心得", "java"]
categories = ["Keycloak学习"]
showToc = true
math = false

+++

## 介绍

Keycloak中的自定义SPI种类有很多，在设计认证流时，可添加三种类型：

1. 执行器（Execution）

   在主流程中标签为`execution`；在子流程中标签为`step`

2. 条件（Condition）

   标签为`condition`

3. 子流程（Sub-flow）

   标签为`flow`

{{< figure align=center src="https://img.fnicen.top/PicGo/三种类型.png">}}

**执行器**用于直接执行某项认证，例如要求用户输入账户名密码、要求用户进行TOTP认证等，通常包括一个或多个用于认证的前端页面以与用户交互

**条件**用于根据某项信息进行决策判断，决定是否执行所在的流程或子流程，一般不包括前端页面（因为只需要与系统内信息交互，不会参与用户操作过程）

**子流程**用于划分更精细的认证流程，通常与**条件**共同构成认证流的某一个条件分支

**接下来开发一个最简单的自定义条件类型SPI**，作用是负责判断当前上下文中的属性`registeringDevice`的值是否为`true`，如果为`true`，则条件成立，否则不成立

## 开发

不同于开发自定义认证器SPI需要继承、实现多个类或接口，自定义条件SPI只需要一个实现了`ConditionalAuthenticator`接口的类以及相应地实现了`ConditionalAuthenticatorFactory`接口的工厂类即可

---

编写`RegisterDeviceConditionAuthenticator`类，实现`ConditionalAuthenticator`接口：

```java
public class RegisterDeviceConditionAuthenticator implements ConditionalAuthenticator {
    @Override
    public boolean matchCondition(AuthenticationFlowContext authenticationFlowContext) {
        String registeringDevice = authenticationFlowContext.getAuthenticationSession().getClientNote("registeringDevice");
        return "true".equals(registeringDevice);
    }

    @Override
    public void action(AuthenticationFlowContext authenticationFlowContext) {}

    @Override
    public boolean requiresUser() {
        return false;
    }

    @Override
    public void setRequiredActions(KeycloakSession keycloakSession, RealmModel realmModel, UserModel userModel) {}

    @Override
    public void close() {}
}
```

这个类唯一需要关注的就是`matchCondition()`方法，这个方法定义了【何种条件下条件成立】，在这里表现为读取`registeringDevice`属性并返回是否为`"true"`

---

接下来编写`RegisterDeviceConditionAuthenticatorFactory`类，实现`ConditionalAuthenticatorFactory`接口：

```java
public class RegisterDeviceConditionAuthenticatorFactory implements ConditionalAuthenticatorFactory {
    public static final String PROVIDER_ID = "register-device-condition";
    private static final ConditionalAuthenticator SINGLETON = new RegisterDeviceConditionAuthenticator();
    private static AuthenticationExecutionModel.Requirement[] REQUIREMENT_CHOICES = {
            AuthenticationExecutionModel.Requirement.REQUIRED,
            AuthenticationExecutionModel.Requirement.DISABLED
    };

    @Override
    public String getDisplayType() {
        return "Condition - 注册设备时触发";
    }

    @Override
    public boolean isConfigurable() {
        return false;
    }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return REQUIREMENT_CHOICES;
    }

    @Override
    public boolean isUserSetupAllowed() {
        return false;
    }

    @Override
    public String getHelpText() {
        return "只有在注册设备流程中才会执行子认证器";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return null;
    }

    @Override
    public void init(Config.Scope scope) {}

    @Override
    public void postInit(KeycloakSessionFactory keycloakSessionFactory) {}

    @Override
    public void close() {}

    @Override
    public String getId() {
        return PROVIDER_ID;
    }
    // create()实际上是执行了getSingleton()，因此重写create()与重写getSingleton()是等价的
    @Override
    public ConditionalAuthenticator getSingleton() {
        return SINGLETON;
    }
}
```

这个工厂类定义了该条件SPI将如何展示于Keycloak系统中，并设置了“必需”、“禁用”两种可选选项，用于开关功能

{{< admonition important "重要提示" >}}

需要注意`getDisplayType()`返回的字符串内容，如果不是以“Condition - ”开头，则此自定义SPI会被Keycloak识别为**执行器**而非**条件**，而与是否实现了`ConditionalAuthenticatorFactory`接口无关！

（暂未测试被识别为执行器的情况下自定义SPI还能否正常工作）

{{< /admonition >}}

---

最后，需要在项目目录下`META-INF/services/org.keycloak.authentication.AuthenticatorFactory`文件中注册该自定义SPI的工厂类，在该文件中添加一行：`org.keycloak.devauth.RegisterDeviceConditionAuthenticatorFactory`，即工厂类的**全限定类名**

{{< admonition note "注意" >}}

虽然是条件类型的SPI，但与执行器相似，都需要在`org.keycloak.authentication.AuthenticatorFactory`中注册工厂类

{{< /admonition >}}

## 效果

打包项目后，将对应jar包放入`providers/`目录中，重启Keycloak，即可看到该自定义条件SPI已被加载：

![](https://img.fnicen.top/PicGo/条件SPI被加载.png)

将条件加入某个子流程，子流程设置为“基于一定条件”、条件设置为“必需”，即可通过条件成立与否来控制子流程的执行

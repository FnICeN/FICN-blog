+++
date = '2025-09-04T18:10:43+08:00'
draft = false
title = 'Keycloak两种自定义认证器配合联动'
tags = ["Keycloak", "java", "Maven"]
categories = ["Keycloak学习"]
showToc = true
math = false

+++

上一篇文章实现了Keycloak中的自定义条件，目的就是为本篇文章**将两种自定义认证器（Execution）配合使用**的操作提供基础

文章开始前，为了表述方便，提出如下简略说法：

- 隐私问题认证：SQA
- 设备指纹认证 / 设备信息认证：DA

## 流程

设计这样一个流程：

1. 用户输入账户名与密码
2. 要求用户进行设备信息验证
   - 若信息正确，则通过认证，不进行SQA
   - 若信息不正确且用户未选择【注册新设备】，则认证失败
   - 若信息不正确且用户选择【注册新设备】，则转到SQA
3. 要求用户进行SQA
   - 若回答正确，则通过认证并保存新设备信息凭证
   - 若回答错误，则认证失败

容易看出：SQA是否执行，取决于**DA的结果**与**用户彼时的选择**；在模块之间，**SQA模块需要与DA模块进行联动**

SQA是否执行的问题可以由上一篇文章中开发的自定义条件SPI解决，而模块之间进行联动的问题则需要进行进一步的开发、重构工作

在Keycloak管理界面下，设计的认证流程表示为：

![](https://img.fnicen.top/PicGo/完整认证流程.png)

{{< admonition important "注意" >}}用户选择注册新设备时，为了使流程继续下去，DA实际上给出的是无条件通过的认证结果，但并不会就此将新设备信息保存，而是待SQA通过后，由SQA模块将新设备信息保存为凭证{{< /admonition >}}

## 传值

分析整个流程可知，设备信息的存储工作是由SQA模块完成的，而问题在于开发时两个模块并不在同一项目下，因此需要借助Keycloak的上下文环境传递信息，这些信息包括：

- 用户是否注册新设备
- 新设备CPUID
- 新设备浏览器指纹
- 新设备名称

{{< admonition note "注意" >}}虽然已有自定义条件SPI负责控制流程分支，但“用户是否注册新设备”这个信息仍然是必要的，这是为了区分当前需要进行**纯粹的隐私问题认证**还是**仅作为其他认证的辅助手段**，关系到本模块后续是否需要获取其他相关数据{{< /admonition >}}

传递方式：使用`authenticationFlowContext.getAuthenticationSession().setClientNote()`传出；使用`authenticationFlowContext.getAuthenticationSession().getClientNote()`接收

## 解耦

### 必要性说明

之所以需要传值，就是因为DA模块需要将设备信息交给SQA模块，由SQA模块存储对应的新设备信息凭证，所以，实际上**凭证存储这个工作是由隐私认证模块完成的**

在原本的设备指纹认证模块中，数据、操作、业务三者是共同存在于同一个jar包里的，在进行凭证存储操作时，`DeviceAuthRequiredAction`中的代码为：

```java
// 从上下文得到Provider实例
DeviceAuthCredentialProvider dacp = (DeviceAuthCredentialProvider) requiredActionContext.getSession().getProvider(CredentialProvider.class, "device-auth");
// 现场构造一个CredentialModel实例，调用Provider实例的createCredential()进行存储
dacp.createCredential(requiredActionContext.getRealm(), requiredActionContext.getUser(), DeviceAuthCredentialModel.createDeviceAuth(hostName, cpuid, visitorId));
```

如果SQA模块想要保存设备信息的凭证，则面临着以下难题：

SQA模块中并未定义`DeviceAuthCredentialProvider`、`DeviceAuthCredentialModel`的类，就算可以从上下文中得到`DeviceAuthCredentialProvider`的实例，也无法调用设备信息类型的`Provider`实例中的任何方法，类似地，也根本无法构造设备信息类型的`CredentialModel`实例

要想解决这个问题，有两个方案：

1. 将设备信息类型的`CredentialModel`、`CredentialProvider`、`CredentialProviderFactory`三个类完全复制到SQA模块中，使得模块可以识别设备信息数据类型。这就相当于**使SQA模块从头开始认识了设备信息类型凭证**，开发难度不高但代码冗余
2. 将DA模块中的数据操作部分独立出来，DA模块与SQA模块都通过**调用这个独立的数据操作部分来完成各自的业务**。需要对代码进行重构但能保证代码的可维护性与简洁性，更符合开发规范

考虑到今后还有可能引入更多需要对设备信息凭证进行操作的自定义认证器，我选择方案2，并决定将DA模块分离为三个部分：数据模型、操作逻辑和上层业务

在这三个部分中，数据模型（`dto`、`CredentialModel`及其他接口）作为API向其他认证器提供操作入口，操作逻辑（`Provider`及对应工厂类）仅负责实现需要对数据模型进行的操作，例如存储新凭证和删除凭证，上层业务（DA、SQA的交互部分）处理用户请求，根据需要调用数据模型提供的API完成业务

{{< admonition important "注意" >}}

在这个方案中，我们规定上层业务只能调用数据模型提供的功能接口，而不能直接调用操作逻辑

{{< /admonition >}}

### 数据模型部分

数据模型部分负责定义数据类型并为上层业务提供可用的接口API，基于此需求，数据模型部分的结构应为：

- DTOs
- `Constants`类
- `CredentialModel`类
- `CredentialProvider`接口

{{< admonition note "说明" >}}

- DTOs和`CredentialModel`类用于定义凭证数据的格式与类型

- `Constants`类负责存储常量字段，例如`ProviderFactory`的`PROVIDER_ID`，这一字段将用于上层业务获取`Provider`实例

- 定义`CredentialProvider`接口的本质就是向上层业务提供API

  在规划中，上层业务并不直接调用操作逻辑，上层业务可以直接从上下文获取到`Provider`，**需要解决的问题仅仅是如何承接获取到的`Provider`实例**，这就是定义`CredentialProvider`接口的目的，它使得上层业务得以承接`Provider`实例并调用其中的各方法

{{< /admonition >}}

这里给出`CredentialProvider`接口代码作为参考：

```java
public interface DeviceAuthCredentialProvider extends CredentialProvider<DeviceAuthCredentialModel>, CredentialInputValidator {
    @Override
    boolean isConfiguredFor(RealmModel realmModel, UserModel userModel, String s);

    @Override
    boolean isValid(RealmModel realmModel, UserModel userModel, CredentialInput credentialInput);

    @Override
    default void close() {
        CredentialProvider.super.close();
    }

    @Override
    String getType();

    @Override
    CredentialModel createCredential(RealmModel realmModel, UserModel userModel, DeviceAuthCredentialModel deviceAuthCredentialModel);

    @Override
    boolean deleteCredential(RealmModel realmModel, UserModel userModel, String s);

    @Override
    DeviceAuthCredentialModel getCredentialFromModel(CredentialModel credentialModel);

    @Override
    default DeviceAuthCredentialModel getDefaultCredential(KeycloakSession session, RealmModel realm, UserModel user) {
        return CredentialProvider.super.getDefaultCredential(session, realm, user);
    }

    @Override
    CredentialTypeMetadata getCredentialTypeMetadata(CredentialTypeMetadataContext credentialTypeMetadataContext);

    @Override
    default CredentialMetadata getCredentialMetadata(DeviceAuthCredentialModel credentialModel, CredentialTypeMetadata credentialTypeMetadata) {
        return CredentialProvider.super.getCredentialMetadata(credentialModel, credentialTypeMetadata);
    }

    @Override
    default boolean supportsCredentialType(CredentialModel credential) {
        return CredentialProvider.super.supportsCredentialType(credential);
    }

    @Override
    default boolean supportsCredentialType(String type) {
        return CredentialProvider.super.supportsCredentialType(type);
    }
}
```

{{< admonition tip "提示" >}}数据模型部分无需在`META-INF`下进行注册，事实上也并没有能够注册的`ProviderFactory`{{< /admonition >}}

### 操作逻辑部分

数据模型部分负责实现对数据模型的各种操作，因此其结构应为：

- `ProviderImpl`
- `ProviderFactory`

{{< admonition note "说明" >}}

- `ProviderImpl`是数据模型部分`Provider`接口的实现类，在实现类中定义各种实际操作
- `ProviderFactory`仍然作为`ProviderImpl`的工厂类，就像原本DA模块中一样

{{< /admonition >}}

这里给出`ProviderImpl`实现类代码作为参考：

```java
public class DeviceAuthCredentialProviderImpl implements DeviceAuthCredentialProvider {
    protected KeycloakSession session;

    public DeviceAuthCredentialProviderImpl(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public boolean isConfiguredFor(RealmModel realmModel, UserModel userModel, String s) {
        if (!supportsCredentialType(s)) return false;
        return userModel.credentialManager().getStoredCredentialsByTypeStream(s).findAny().isPresent();
    }

    @Override
    public boolean isValid(RealmModel realmModel, UserModel userModel, CredentialInput credentialInput) {
        if (!(credentialInput instanceof UserCredentialModel)) return false;
        if (!(credentialInput.getType().equals(getType()))) return false;
        String challengeResponse = credentialInput.getChallengeResponse();
        if (challengeResponse == null) return false;
        String credentialId = credentialInput.getCredentialId();
        if (credentialId == null || credentialId.isEmpty()) return false;

        CredentialModel cm = userModel.credentialManager().getStoredCredentialById(credentialId);
        DeviceAuthCredentialModel dacm = getCredentialFromModel(cm);

        String[] parts = challengeResponse.split("\\|\\|", 2);
        boolean cpuIdFlag = dacm.getDeviceData().getCpuId().equals(parts[0]);
        boolean visitorIdFlag = dacm.getDeviceData().getVisitorId().equals(parts.length > 1 ? parts[1] : "");

        return cpuIdFlag && visitorIdFlag;
    }

    @Override
    public String getType() {
        return DeviceAuthCredentialModel.TYPE;
    }

    // 新注册凭证时会被调用
    @Override
    public CredentialModel createCredential(RealmModel realmModel, UserModel userModel, DeviceAuthCredentialModel deviceAuthCredentialModel) {
        if (deviceAuthCredentialModel.getCreatedDate() == null)
            deviceAuthCredentialModel.setCreatedDate(Time.currentTimeMillis());
        return userModel.credentialManager().createStoredCredential(deviceAuthCredentialModel);
    }

    @Override
    public boolean deleteCredential(RealmModel realmModel, UserModel userModel, String s) {
        return userModel.credentialManager().removeStoredCredentialById(s);
    }

    @Override
    public DeviceAuthCredentialModel getCredentialFromModel(CredentialModel credentialModel) {
        DeviceAuthCredentialModel dacm = DeviceAuthCredentialModel.createFromCredentialModel(credentialModel);
        return dacm;
    }

    @Override
    public CredentialTypeMetadata getCredentialTypeMetadata(CredentialTypeMetadataContext credentialTypeMetadataContext) {
        return CredentialTypeMetadata.builder()
                .type(getType())
                .category(CredentialTypeMetadata.Category.TWO_FACTOR)
                .displayName(DeviceAuthCredentialProviderFactory.PROVIDER_ID)
                .helpText("device-authenticate")
                .createAction("device-auth-authenticator")
                .removeable(false)
                .build(session);
    }

    @Override
    public boolean supportsCredentialType(String type) {
        return getType().equals(type);
    }
}
```

{{< admonition tip "提示" >}}由于涉及的凭证数据操作需要被Keycloak识别，因此需要在`META-INF/services/org.keycloak.credential.CredentialProviderFactory`文件中注册`ProviderFactory`类的完全限定名{{< /admonition >}}

### 上层业务部分

上层业务部分负责处理用户提交的数据、用户的选择，根据选择决定如何对凭证数据进行操作

这个部分从原本的DA模块中修改得来，可以预见由于数据模型与操作逻辑的移除，剩下的文件结构应为：

- `Authenticator`
- `AuthenticatorFactory`
- `RequiredAction`
- `RequiredActionFactory`
- `ConditionAuthenticator`
- `ConditionAuthenticatorFactory`

在代码层面上，原本的凭证保存写法基本不变：

```java
// 从上下文得到Provider实例
DeviceAuthCredentialProvider dacp = (DeviceAuthCredentialProvider) requiredActionContext.getSession().getProvider(CredentialProvider.class, DeviceAuthConstants.credentialProviderFactoryID);
// 现场构造一个CredentialModel实例，调用Provider实例的createCredential()进行存储
dacp.createCredential(requiredActionContext.getRealm(), requiredActionContext.getUser(), DeviceAuthCredentialModel.createDeviceAuth(hostName, cpuid, visitorId));
```

但在实质上，`DeviceAuthCredentialProvider`已**从原本的类变成了数据模型层面提供的接口**，这种变化**保证了DA或SQA可以在未定义`CredentialProvider`的情况下使用其中的自定义方法**；另外，`DeviceAuthCredentialModel`也是由数据模型层面向上提供的数据类型

{{< admonition tip "提示" >}}原本的`META-INF/services/org.keycloak.credential.CredentialProviderFactory`文件已经可以删除，因为此部分已不存在`ProviderFactory`文件{{< /admonition >}}

至此，已经完成对DA模块的三部分解耦

## 引用

这三个部分各自独立开发，完成后是存在互相调用的关系的：

![](https://img.fnicen.top/PicGo/三部分调用关系.png)

将数据模型部分打包为jar文件后，要想将其导入至操作逻辑部分当中，可以进行如下步骤（以Maven导入为例）：

```cmd
# 将jar包安装到Maven本地仓库
mvn install:install-file -DgroupId=com.DeviceAuthApi -DartifactId=DeviceAuthApi -Dversion=1.0-SNAPSHOT -Dpackaging=jar -Dfile=DeviceAuthApi-1.0-SNAPSHOT.jar
```

这里的`Dfile`指定jar包位置，`DgroupId`、`DartifactId`、`Dversion`需要与数据模型项目的`pom.xml`包信息一致：

![](https://img.fnicen.top/PicGo/设备API包信息.png)

完成后，在操作逻辑的`pom.xml`中导入对应的`<dependency>`即可

## 执行

解耦DA模块的目的是使SQA模块能够执行设备信息凭证的存储，现在，SQA完全可以引入DA模块分离出的数据模型部分，通过其提供的数据定义与接口实现对设备信息凭证的操作

在SQA模块的`pom.xml`中导入`com.DeviceAuthApi`，然后在`Authenticator`的`action()`方法中判断用户意图并执行保存：

```java
import com.DeviceAuthApi.DeviceAuthConstants;
import com.DeviceAuthApi.DeviceAuthCredentialModel;
import com.DeviceAuthApi.DeviceAuthCredentialProvider;
// ...
@Override
public void action(AuthenticationFlowContext authenticationFlowContext) {
    // ...
    // 通过SQA后：
    if (isRegisterDevice(authenticationFlowContext)) {
        String cpuid = authenticationFlowContext.getAuthenticationSession().getClientNote("cpuid");
        String visitorId = authenticationFlowContext.getAuthenticationSession().getClientNote("visitorId");
        DeviceAuthCredentialProvider dacp = (DeviceAuthCredentialProvider) authenticationFlowContext.getSession().getProvider(CredentialProvider.class, DeviceAuthConstants.credentialProviderFactoryID);
        dacp.createCredential(authenticationFlowContext.getRealm(), authenticationFlowContext.getUser(), DeviceAuthCredentialModel.createDeviceAuth("new", cpuid, visitorId));
    }
    authenticationFlowContext.success();
}
```

最后，只需要将打包得到的三个jar包放入`providers/`目录中即可实现预期功能，三个jar包为：

- DeviceAuthApi.jar
- DeviceAuthProviderImpl.jar
- DeviceAuth.jar

{{< admonition important "重要说明" >}}

原理上看，只要将上层业务与操作逻辑**完整打包**，就无需将数据模型jar放入`providers/`目录，但我自己使用Maven打包时，未将二者分别与数据模型jar合并打包，所以目前**需要将数据模型jar也放置到`providers/`中运行**

{{< /admonition >}}

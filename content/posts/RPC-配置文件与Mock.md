+++
date = '2026-03-23T11:12:24+08:00'
draft = false
title = 'RPC - 配置文件与Mock'
tags = ["java","rpc"]
categories = ["RPC框架"]
showToc = true
math = false

+++

由于我设计的是一个 RPC 框架，这个框架的特点就是，同时具备作为一个服务器的功能和作为客户端的功能

- 服务器端：由 Provider 使用，启动一个 RPC 服务器并维护注册中心
- 客户端：由 Consumer 使用，提供动态代理类由 Consumer 调用服务

所以配置文件是必不可少的

另外，为了开发客户端侧的功能方便，可以顺便手动为框架设计一套 Mock，这样就无需每次调试都通过 Provider 启动 RPC 服务器了

## 配置文件

首先在框架内编写 RPC 框架的默认配置，以类的形式给出。这也是 Provider 启动 RPC 服务器或客户端无配置文件时会使用的默认配置：

```java
@Data
public class RpcConfig {

    /**
     * 名称
     */
    private String name = "ficn-rpc";

    /**
     * 版本号
     */
    private String version = "1.0";

    /**
     * 服务器主机名
     */
    private String serverHost = "localhost";
    
    /**
     * 服务器端口号
     */
    private Integer serverPort = 8080;

    /**
     * 是否使用模拟数据
     */
    private boolean mock = false;

}
```

然后编写读取配置文件的工具类，这个工具类是用于服务器侧或客户端侧从 `resources/application.properties` 文件中读取用户配置的：

```java
public class ConfigUtils {

    // 加载配置对象
    public static <T> T loadConfig(Class<T> tClass, String prefix) {
        return loadConfig(tClass, prefix, "");
    }

    // 加载配置对象，支持区分环境
    public static <T> T loadConfig(Class<T> tClass, String prefix, String environment) {
        StringBuilder configFileBuilder = new StringBuilder("application");
        if (StrUtil.isNotBlank(environment)) {
            configFileBuilder.append("-").append(environment);
        }
        configFileBuilder.append(".properties");
        Props props = new Props(configFileBuilder.toString());
        return props.toBean(tClass, prefix);
    }
}
```

有了读取配置文件的工具类，就可以编写一个存放项目全局变量的类，其中都是静态变量和方法，可以用于让 Provider 初始化，或是让 Consumer 获取到本地配置。使用双检锁单例模式实现：

```java
public class RpcApplication {

    private static volatile RpcConfig rpcConfig;

    // 框架初始化，支持传入自定义配置
    public static void init(RpcConfig newRpcConfig) {
        rpcConfig = newRpcConfig;
        log.info("rpc init, config = {}", newRpcConfig.toString());
    }

    // 初始化
    public static void init() {
        RpcConfig newRpcConfig;
        try {
            // 从resources配置文件中读取，通常有配置文件的 Consumer 会执行本行
            newRpcConfig = ConfigUtils.loadConfig(RpcConfig.class, RpcConstant.DEFAULT_CONFIG_PREFIX);
        } catch (Exception e) {
            // 配置加载失败，使用默认值，通常无配置文件的 Provider 会执行本行
            newRpcConfig = new RpcConfig();
        }
        init(newRpcConfig);
    }

    // 获取配置，若从未初始化过配置才读取，否则直接返回已有配置
    public static RpcConfig getRpcConfig() {
        if (rpcConfig == null) {
            synchronized (RpcApplication.class) {
                if (rpcConfig == null) {
                    init();
                }
            }
        }
        return rpcConfig;
    }
}
```

如此一来，Provider 启动 RPC 框架并提供服务的启动类：

```java
public class ProviderExample {
    public static void main(String[] args) {
        // 初始化 RPC 框架（读取框架配置）
        RpcApplication.init();
        LocalRegistry.register(UserService.class.getName(), UserServiceImpl.class);
        HttpServer server = new VertxHttpServer();
        // 服务提供者启动 RPC 服务，使用读取的框架配置
        server.doStart(RpcApplication.getRpcConfig().getServerPort());
    }
}
```

与此类似地，客户端侧（即 Consumer）也能读取到本地配置文件，之后所创建的动态代理即能通过读取静态变量获取配置文件中设置的各项参数，如 RPC 服务器地址等

## Mock

想要做 Mock，一个便捷的实现就是：

1. 先读取客户端侧的配置文件

2. 若配置文件中标明了 `mock=true`，则在用户获取动态代理时返回一个 Mock 版本的动态代理

   这个动态代理的 `invoke()` 方法仅根据调用返回值返回确定的值

3. 用户使用 Mock 版本的动态代理进行各种业务，都会得到返回值类型无误的 Mock 数据

根据这个思路，在 RPC 框架中新增一个 Mock 动态代理类：

```java
public class MockServiceProxy implements InvocationHandler {

    // 不管执行任何方法，根据期待的返回值类型返回默认值
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        Class<?> methodReturnType = method.getReturnType();
        log.info("mock invoke {}", method.getName());
        return getDefaultObject(methodReturnType);
    }

    // 构造默认返回值或对象
    private Object getDefaultObject(Class<?> clazz) {
        if (clazz.equals(short.class)) {
            return (short) 0;
        }
        if (clazz.equals(int.class)) {
            return 0;
        }
        if (clazz.equals(long.class)) {
            return 0L;
        }
        if (clazz.equals(boolean.class)) {
            return false;
        }
        return null;  // 对象类型默认返回null
    }
}
```

接着，既然要根据用户的配置文件决定返回哪种动态代理，就需要修改 Factory：

```java
public class ServiceProxyFactory {
    public static <T> T getProxy(Class<T> serviceClass) {
        // 如果是模拟数据，则返回模拟数据代理对象
        if (RpcApplication.getRpcConfig().isMock()) {
            return getMockProxy(serviceClass);
        }
        return (T) Proxy.newProxyInstance(
                serviceClass.getClassLoader(),
                new Class[]{serviceClass},
                new ServiceProxy());
    }

    public static <T> T getMockProxy(Class<T> serviceClass) {
        return (T) Proxy.newProxyInstance(
                serviceClass.getClassLoader(),
                new Class[]{serviceClass},
                new MockServiceProxy());
    }
}
```

执行 `RpcApplication.getRpcConfig()` 静态方法，即是在单例模式下检查存储配置的静态变量是否已存在，若不存在，则执行 `init()` 方法，读取本地配置文件完成初始化后返回配置；若存在则不必读取，直接返回配置即可

{{< admonition important "关于 isMock()" >}}`isMock()` 是@Data自动生成的针对 `boolean` 类型的Getter，注意如果是包装类如 `Boolean` 则只能生成普通的Getter{{< /admonition >}}

如此一来，Consumer处的代码不变，RPC框架自动根据配置文件决定是否Mock：

```java
public class ConsumerExample {
    public static void main(String[] args) {
        UserService userService = ServiceProxyFactory.getProxy(UserService.class);
        User user = new User();
        user.setName("ficn");
        User newUser = userService.getUser(user);
        if (newUser != null) {
            System.out.println(newUser.getName());
        } else {
            System.out.println("newUser is null");
        }
    }
}
```

+++
date = '2026-03-22T13:05:56+08:00'
draft = false
title = 'RPC框架简单实践'
tags = ["java","rpc"]
categories = ["RPC框架"]
showToc = true
math = false

+++

创建一个简单示例，原理如下：

1. 运行一个RPC服务器，服务器中使用ConcurrentHashMap<String, Class<?>>存储服务实现类的类名和实例
2. 服务提供者Provider将自己的实现类加入该Map中去，实现服务注册
3. 服务消费者Consumer发送HTTP的服务请求，其中包含服务类名、方法名、参数类型、参数列表四个参数
4. RPC服务器接收到服务请求，根据解析的请求内容到Map中取相对应的实例，通过反射执行对应方法
5. RPC服务器将执行方法后的结果封装到响应中返回Consumer

---

关于Consumer发送请求如果每次都手动构造请求体就太麻烦了，有两个实现：

- 编写静态的代理类，也实现了服务接口，实现内部是构造相应的请求体发送给RPC服务器，获取响应后反序列化结果返回

  不过这个静态代理类需要针对每个服务接口方法硬编码请求体，比如.methodName("getUser")这种都要手动设置

- 编写动态代理类，可以基于JDK动态代理实现，这样就不用手动实现每个服务接口，invoke()方法会获取到各种调用参数信息，将这些信息封装好发送就行

## 共享接口

RPC服务器、服务提供者、服务消费者都需要得到服务接口信息，如此才能实例化或实现功能

用户User：

```java
public class User implements Serializable {
    private String name;
    public String getName() {
        return name;
    }
    public void setName(String name) {
        this.name = name;
    }
}
```

用户服务接口UserService：

```java
public interface UserService {
    /**
     * 获取用户
     *
     * @param user
     * @return
     */
    User getUser(User user);
}
```

## RPC服务器

核心Handler中，先反序列化请求对象，从中取出请求的服务信息，从注册中心Map获取实现类实例后，通过反射执行方法，然后将执行结果封装为响应返回：

```java
public class HttpServerHandler implements Handler<HttpServerRequest> {
    @Override
    public void handle(HttpServerRequest request) {
        // 创建序列化器
        final Serializer serializer = new JdkSerializer();
        // 记录日志
        System.out.println("Received request: " + request.method() + " " + request.uri());
        // 异步处理请求
        request.bodyHandler(body -> {
            byte[] bytes = body.getBytes();
            RpcRequest rpcRequest = null;
            try {
                // 反序列化请求参数为RpcRequest对象
                rpcRequest = serializer.deserialize(bytes, RpcRequest.class);
            } catch (Exception e) {
                e.printStackTrace();
            }

            RpcResponse rpcResponse = new RpcResponse();
            // 如果请求为空则返回错误信息
            if (rpcRequest == null) {
                rpcResponse.setMessage("Invalid request, request is null");
                doResponse(request, rpcResponse, serializer);
                return;
            }
            try {
                // 从请求取服务名，然后从注册中心获取服务实现类
                Class<?> implClass = LocalRegistry.get(rpcRequest.getServiceName());
                // 获取服务实现类的方法并执行
                Method method = implClass.getMethod(rpcRequest.getMethodName(), rpcRequest.getParameterTypes());
                Object result = method.invoke(implClass.newInstance(), rpcRequest.getArgs());
                // 封装响应结果
                rpcResponse.setData(result);
                rpcResponse.setDataType(method.getReturnType());
                rpcResponse.setMessage("ok");
            } catch (Exception e) {
                e.printStackTrace();
                rpcResponse.setMessage(e.getMessage());
                rpcResponse.setException(e);
            }
            doResponse(request, rpcResponse, serializer);
        });
    }

    private void doResponse(HttpServerRequest request, RpcResponse rpcResponse, Serializer serializer) {
        HttpServerResponse httpServerResponse = request.response().putHeader("content-type", "application/json");
        try {
            // 序列化响应结果为字节数组
            byte[] bytes = serializer.serialize(rpcResponse);
            // 发送响应
            httpServerResponse.end(Buffer.buffer(bytes));
        } catch (IOException e) {
            e.printStackTrace();
            httpServerResponse.end(Buffer.buffer());
        }
    }
}
```

---

关于注册中心，维护该Map即可：

```java
public class LocalRegistry {
    /**
     * 存放服务接口名与实现类的映射关系
     */
    public static final Map<String, Class<?>> map = new ConcurrentHashMap<String, Class<?>>();

    /**
     * 注册服务
     *
     * @param serviceName 服务接口名
     * @param implClass 服务实现类
     */
    public static void register(String serviceName, Class<?> implClass) {
        map.put(serviceName, implClass);
    }

    /**
     * 获取服务实现类
     *
     * @param serviceName 服务接口名
     * @return 服务实现类
     */
    public static Class<?> get(String serviceName) {
        return map.get(serviceName);
    }

    /**
     * 删除服务
     *
     * @param serviceName 服务接口名
     * @return 是否成功
     */
    public static void remove(String serviceName) {
        map.remove(serviceName);
    }
}
```

---

因为我们打算使用动态代理，以免去为每个实现接口都单独写一套请求构造逻辑，所以需要写一个供Consumer使用的动态代理类，当Consumer使用动态代理类调用任意方法如getUser()时，底层都会调用invoke()方法，传入调用信息

只需要实现InvocationHandler即可通过invoke()拿到调用参数，然后构造请求发送至RPC服务器：

```java
public class ServiceProxy implements InvocationHandler {
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        Serializer serializer = new JdkSerializer();
        // 构造RpcRequest
        RpcRequest rpcRequest = RpcRequest.builder()
                .serviceName(method.getDeclaringClass().getName())
                .methodName(method.getName())
                .parameterTypes(method.getParameterTypes())
                .args(args)
                .build();
        try {
            // 请求序列化
            byte[] bytes = serializer.serialize(rpcRequest);
            byte[] result;
            // 发送请求获取响应
            // todo 使用服务发现解决硬编码问题
            try (HttpResponse response = HttpRequest.post("http://localhost:8080")
                    .body(bytes)
                    .execute()) {
                result = response.bodyBytes();
            }
            // 响应反序列化
            RpcResponse rpcResponse = serializer.deserialize(result, RpcResponse.class);
            // 返回结果对象
            return rpcResponse.getData();
        } catch (Exception e) {
            e.printStackTrace();
        }
        return null;
    }
}
```

这个动态代理类从可用性上来说，既可以放在Consumer包里，也可以放在RPC服务器包里，不过作为框架，这个动态代理类应能给所有引入此框架的程序使用，所以需要放在RPC服务器包里，表示【所有在此注册过的服务都将拥有一个自己的动态代理类】

还需要为这个代理类创建工厂，用于根据不同的服务接口生产不同的动态代理

```java
/**
 * 根据服务类获取对应的代理对象
 */
public class ServiceProxyFactory {
    public static <T> T getProxy(Class<T> serviceClass) {
        return (T) Proxy.newProxyInstance(
                serviceClass.getClassLoader(),
                new Class[]{serviceClass},
                new ServiceProxy());
    }
}
```

## 服务提供者

服务提供者Provider负责提供某个服务接口的实现类，提供方式是运行RPC服务器并将将实现类注册到服务器中（添加到ConcurrentHashMap）

```java
public class EasyProviderExample {
    public static void main(String[] args) {
        // 注册服务
        LocalRegistry.register(UserService.class.getName(), UserServiceImpl.class);
        // 启动HTTP服务器
        new VertxHttpServer().doStart(8080);
    }
}
```

## 服务消费者

服务消费者Consumer通过ProxyFactory获取对应于服务接口的服务实现代理类，通过执行代理类中的invoke()方法向RPC服务器发送HTTP请求，接收服务器中注册的真正的实现类的执行结果

```java
public class EasyConsumerExample {
    public static void main(String[] args) {
		// 获取对应于UserService的动态代理实现类
        UserService userService = ServiceProxyFactory.getProxy(UserService.class);
        User user = new User();
        user.setName("FICN");
		// 相当于调用invoke()方法
        User newUser = userService.getUser(user);
        if (newUser != null) {
            System.out.println(newUser.getName());
        } else {
            System.out.println("用户不存在");
        }
    }
}
```

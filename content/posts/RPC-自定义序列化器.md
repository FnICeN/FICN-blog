+++
date = '2026-03-23T12:42:13+08:00'
draft = false
title = 'RPC - 自定义序列化器'
tags = ["java","rpc"]
categories = ["RPC框架"]
showToc = true
math = false

+++

序列化手段有很多，之前的代码中都是硬编码 `Serializer s = new JdkSerializer()`，其中 `JdkSerializer` 是自定义的基于 JDK 的序列化器

现在可以给用户更多选择，如 JSON、Hessian、Kryo 额外三个内置序列化器，以及基于 SPI 的自定义序列化器

## 内置序列化器

首先分别实现 JSON、Hessian、Kryo 的序列化类，这一步与项目本身无关，这里不放代码了

接着，为了更有效地区分序列化器的名称，可以创建一个枚举类或者接口类存储内置序列化器的名称：

```java
public interface SerializerKeys {
    String JDK = "jdk";
    String JSON = "json";
    String KRYO = "kryo";
    String HESSIAN = "hessian";
}
```

序列化器明显可以复用，所以创建一个单例的序列化器工厂：

```java
public class SerializerFactory {

    // 单例，存储名称到序列化器实例的映射
    private static final Map<String, Serializer> KEY_SERIALIZER_MAP = new HashMap<String, Serializer>() {{
        put(SerializerKeys.JDK, new JdkSerializer());
        put(SerializerKeys.JSON, new JsonSerializer());
        put(SerializerKeys.KRYO, new KryoSerializer());
        put(SerializerKeys.HESSIAN, new HessianSerializer());
    }};

    // 默认序列化器
    private static final Serializer DEFAULT_SERIALIZER = KEY_SERIALIZER_MAP.get("jdk");

    // 获取实例
    public static Serializer getInstance(String key) {
        return KEY_SERIALIZER_MAP.getOrDefault(key, DEFAULT_SERIALIZER);
    }

}
```

最后，不要忘记修改默认 Config 配置：

```java
@Data
public class RpcConfig {
	// ...
    // 默认序列化器
    private String serializer = SerializerKeys.JDK;
}
```

之后只要获取序列化器，就从工厂取即可：

```java
Serializer serializer = SerializerFactory.getInstance(RpcApplication.getRpcConfig().getSerializer());
```

可以得知，对于 Provider 侧，在无配置文件的情况下，取得的应该是默认的 Config 配置中的序列化器；对于 Consumer 侧，取得的应该是配置文件中配置的序列化器

## 自定义序列化器

Java 原生 SPI 机制 `ServiceLoader` 的本质就是扫描 `META-INF/servcies/<接口全限定类名>` 文件，读取其中的实现类全限定名后通过反射加载类

现在我们可以自己构造一个 `SerializerLoader`，专门从 `META-INF/rpc` 下读取配置文件

由于框架存在内置的序列化器，所以可以让这些内置的序列化器也通过 SPI 机制，与自定义的一起被加载。那么最好分开读取，在 `META-INF/rpc/system/` 目录中进行内置序列化器扫描；在 `META-INF/rpc/custom/` 中进行自定义序列化器扫描

{{< admonition note "关于custom目录" >}}`META-INF/rpc/custom/` 保存的是自定义序列化器，所以这个目录一般应由客户端侧或服务器侧新建，框架里无需存在该目录{{< /admonition >}}

编写扫描目录并通过反射获取序列化器实例、保存到自己 Map 的 `Loader` 类：

```java
@Slf4j
public class SpiLoader {

    // 存储已加载的类：接口名 =>（key => 实现类）
    private static Map<String, Map<String, Class<?>>> loaderMap = new ConcurrentHashMap<>();

    // 对象实例缓存（避免重复 new），类路径 => 对象实例，单例模式
    private static Map<String, Object> instanceCache = new ConcurrentHashMap<>();

    // 系统 SPI 目录
    private static final String RPC_SYSTEM_SPI_DIR = "META-INF/rpc/system/";

    // 用户自定义 SPI 目录
    private static final String RPC_CUSTOM_SPI_DIR = "META-INF/rpc/custom/";

    // 扫描路径
    private static final String[] SCAN_DIRS = new String[]{RPC_SYSTEM_SPI_DIR, RPC_CUSTOM_SPI_DIR};

    // 动态加载的类列表
    private static final List<Class<?>> LOAD_CLASS_LIST = Arrays.asList(Serializer.class);

    // 加载所有类型
    public static void loadAll() {
        log.info("加载所有 SPI");
        for (Class<?> aClass : LOAD_CLASS_LIST) {
            load(aClass);
        }
    }

    // 获取实例
    public static <T> T getInstance(Class<?> tClass, String key) {
        String tClassName = tClass.getName();
        Map<String, Class<?>> keyClassMap = loaderMap.get(tClassName);
        if (keyClassMap == null) {
            throw new RuntimeException(String.format("SpiLoader 未加载 %s 类型", tClassName));
        }
        if (!keyClassMap.containsKey(key)) {
            throw new RuntimeException(String.format("SpiLoader 的 %s 不存在 key=%s 的类型", tClassName, key));
        }
        // 获取到要加载的实现类型
        Class<?> implClass = keyClassMap.get(key);
        // 从实例缓存中加载指定类型的实例
        String implClassName = implClass.getName();
        if (!instanceCache.containsKey(implClassName)) {
            try {
                instanceCache.put(implClassName, implClass.newInstance());
            } catch (InstantiationException | IllegalAccessException e) {
                String errorMsg = String.format("%s 类实例化失败", implClassName);
                throw new RuntimeException(errorMsg, e);
            }
        }
        return (T) instanceCache.get(implClassName);
    }

    // 加载某个类型
    public static Map<String, Class<?>> load(Class<?> loadClass) {
        log.info("加载类型为 {} 的 SPI", loadClass.getName());
        // 扫描路径，用户自定义的 SPI 优先级高于系统 SPI
        Map<String, Class<?>> keyClassMap = new HashMap<>();
        for (String scanDir : SCAN_DIRS) {
            List<URL> resources = ResourceUtil.getResources(scanDir + loadClass.getName());
            // 读取每个资源文件
            for (URL resource : resources) {
                try {
                    InputStreamReader inputStreamReader = new InputStreamReader(resource.openStream());
                    BufferedReader bufferedReader = new BufferedReader(inputStreamReader);
                    String line;
                    while ((line = bufferedReader.readLine()) != null) {
                        String[] strArray = line.split("=");
                        if (strArray.length > 1) {
                            String key = strArray[0];
                            String className = strArray[1];
                            keyClassMap.put(key, Class.forName(className));
                        }
                    }
                } catch (Exception e) {
                    log.error("spi resource load error", e);
                }
            }
        }
        loaderMap.put(loadClass.getName(), keyClassMap);
        return keyClassMap;
    }
}
```

有了扫描并创建相应实例的 `Loader` 类，就可以在工厂中直接从中获取并返回了。`Loader` 类自带了 Map，工厂类可以不要 Map 了，从 `Loader` 取就行：

```java
public class SerializerFactory {

    static {
        SpiLoader.load(Serializer.class);
    }

    // 默认序列化器
    private static final Serializer DEFAULT_SERIALIZER = new JdkSerializer();

    // 获取实例
    public static Serializer getInstance(String key) {
        return SpiLoader.getInstance(Serializer.class, key);
    }

}
```

最后也别忘了在框架中确实建立 `META-INF/rpc/system/` 目录，并创建 `com.ficn.rpc.serializer.Serializer`：

```java
jdk=com.ficn.rpc.serializer.JdkSerializer
hessian=com.ficn.rpc.serializer.HessianSerializer
json=com.ficn.rpc.serializer.JsonSerializer
kryo=com.ficn.rpc.serializer.KryoSerializer
```

这样算是注册了内置的四种序列化器

## 测试

在服务器侧与客户端侧：

- 可以不创建配置文件，以默认配置启动，此时使用的是默认的 JDK 序列化器
- 如果想用其他内置序列化器，则在配置文件中设置 `rpc.serializer=<内置序列化器>` 即可
- 如果想用自定义序列化器，则在 `META-INF/rpc/custom/` 注册即可

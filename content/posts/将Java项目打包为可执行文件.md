+++
date = '2025-08-05T16:31:03+08:00'
draft = false
title = '将Java项目打包为可执行文件'
tags = ["java", "WiX", "心得"]
categories = ["Java学习"]
showToc = false
math = false

+++

本实例的Java工程构建了一个简单的服务器，监听本地的12345端口，当接收到GET请求：`/get_cpuid`时，返回当前运行终端的CPUID信息

整个流程分为两部分：

1. 工程打包为jar文件
2. jar文件转换为exe安装程序，安装后得到exe可执行程序

---

在打包为jar之前需要指定主类，Maven设置：

```xml
<build>
    <plugins>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-shade-plugin</artifactId>
            <version>3.2.4</version>
            <executions>
                <execution>
                    <phase>package</phase>
                    <goals>
                        <goal>shade</goal>
                    </goals>
                    <configuration>
                        <transformers>
                            <transformer implementation="org.apache.maven.plugins.shade.resource.ManifestResourceTransformer">
                                <mainClass>org.example.LocalHardwareService</mainClass>
                            </transformer>
                        </transformers>
                    </configuration>
                </execution>
            </executions>
        </plugin>
    </plugins>
</build>
```

执行`mvn package`后会打包为一个fat jar，文件名GetDeviceInfo-1.0-SNAPSHOT-shaded.jar

> 若不使用fat jar，则安装的exe会提示启动JVM失败

执行以下`jpackage`命令：


```bash
jpackage --input target/ --name LocalHWService --main-jar GetDeviceInfo-1.0-SNAPSHOT-shaded.jar --main-class org.example.LocalHardwareService --type exe --vendor "FICN" --description "Local Hardware Info Service"
```

- `input`：输入目录。因为jar文件是被打包存储于项目的`/target`目录中的；
- `main-jar`：jar文件名；
- `main-class`：主类名；
- `vendor`：发行公司名；
- `description`：文件描述，会显示在任务管理器中

> 一般来说，`vendor`和`description`属性是无需特别指定的，但由于执行这`jpackage`指令会使用WiX，而我所安装的WiX（v3.14.1）的这两个属性默认会使用非ASCII字符，这就导致了`jpackage`命令报错，所以需要手动指定这两个属性，保证是纯英文

命令完成后在当前目录生成LocalHWService-1.0.exe文件，这个文件**并不能直接运行服务，而是一个安装程序**

双击打开后自动安装，一般会安装到`C:\Program Files`中，进入子目录`\LocalHWService`后，可以看到文件：

![安装后文件](https://img.fnicen.top/PicGo/安装后文件.png)

LocalHWService.exe就是服务文件了，双击运行，打开任务管理器可以看到其在后台正常运行：

![任务管理器](https://img.fnicen.top/PicGo/任务管理器查看运行.png)

在浏览器中进行测试，此时请求正常得到响应：

![网络请求成功](https://img.fnicen.top/PicGo/网络请求成功.png)


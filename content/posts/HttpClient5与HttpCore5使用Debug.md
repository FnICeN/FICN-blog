+++
date = '2026-04-24T19:29:59+08:00'
draft = false
title = 'HttpClient5与HttpCore5 Debug'
tags = ["debug"]
categories = ["经验"]
showToc = true
math = false

+++

## 依赖

- SpringBoot：3.5.12
- HttpClient5：5.6.1

## 发生场景

执行`restTemplate.exchange(url, HttpMethod.GET, entity, NodeListResponse.class).getBody()`时报错：

```
java.lang.ClassNotFoundException: org.apache.hc.core5.io.IOFunction
```

## 修复

查看HttpCore5的版本：

```
$ mvn dependency:tree

[INFO] ...
[INFO] \- org.apache.httpcomponents.client5:httpclient5:jar:5.6.1:compile
[INFO]    +- org.apache.httpcomponents.core5:httpcore5:jar:5.3.6:compile
[INFO]    +- org.apache.httpcomponents.core5:httpcore5-h2:jar:5.3.6:compile
[INFO]    \- org.slf4j:slf4j-api:jar:2.0.17:compile
[INFO] ------------------------------------------------------------------------
[INFO] BUILD SUCCESS
[INFO] ------------------------------------------------------------------------
[INFO] Total time:  10.139 s
[INFO] Finished at: 2026-04-24T19:20:35+08:00
[INFO] ------------------------------------------------------------------------
```

可以看到HttpCore5是由HttpClient5引入的，版本为5.3.6

查询资料后得知Core的5.3.6版本最好配套Client5的5.5.2版本

最终确定的版本：

- HttpCore5：5.3.6
- HttpClient5：5.5.2

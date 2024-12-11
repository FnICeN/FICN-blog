+++
date = '2022-09-06T20:34:54+08:00'
draft = false
title = 'Stream流遍历处理字符串中各字符'
tags = ["java", "Stream流"]
categories = ["Java学习"]
showToc = true
math = false

+++

# Stream在数组处理上的特点

首先明确一点：

```java
char[] chs = {'h','e','l','l','o'};
int[] ints = {1,2,3,4};
String str = "hello";
String[] strs = {"hello","world"};
//数组的Stream流泛型都是数组，而不是数组中的单个元素
Stream<char[]> chsStream = Stream.of(chs);
Stream<int[]> intsStream = Stream.of(ints);
//String的Stream流泛型都是String
Stream<String> strStream = Stream.of(str);
Stream<String> strsStream = Stream.of(strs);  //在这种情况下，流中的每个元素都是String[]数组中的单个元素
```

如果我们的目的是处理数组中的每一个元素，那么对于Stream<T[]>这种类型的流我们一般是并不想见到的

解决方法就是**使用基本类型流**，即**IntStream、DoubleStream**和**LongStream**，然后再操作（或对基本类型流先进行`boxed()`转为Stream\<T>再操作），而得到基本类型流的方法有两种：

1. `Arrays.stream()`
2. `基本类型流名.of()`

# Stream处理字符串 - 以凯撒密码为例

若要对字符串中的每个字符进行逐个操作，最容易想到，也最快的方法就是先使用`toCharArray()`将字符串转为一个char[]数组，再使用循环进行操作，最后使用String的构造方法将之再转换回字符串：

```java
//正常方法
char[] chars = str.toCharArray();
for(int i=0;i< chars.length;i++) {
    chars[i] = (char)((chars[i]-'a'+k)%26+'a');
}
System.out.println(new String(chars));
```

**这次我舍近求远，想用Stream流来模拟生成凯撒密码密文的操作**

根据Stream处理数组的特点，String转换成char[]之后，要想对数组的每个元素都进行操作，就要使用**基本类型流**，**但并没有char类型的基本类型流**，在这就导致我**只能得到Stream<char[]>，而得不到如CharStream或是Stream\<Character>的流**

所以，不能将String转为char[]数组

那么，借助String[]数组的流中可以遍历到数组中的每个元素的特点，考虑将String转为String[]数组，再使用`map()`将每个元素转换成char，这样才得到一个Stream\<Character>：

```java
Stream<String> t = Stream.of(str.split(""));
//str:{"h","e","l","l","o"}
Stream<Character> chStream = t.map(s -> s.charAt(0));
chStream = t.map(ch -> (char)((ch-'a'+1)%26+'a');
/*
* 也可直接一步完成操作：
* s -> (char)((s.charAt(0)-'a'+1)%26+'a')
*/
```

得到了Stream\<Character>以后，才能正式地开始遍历每个字符并处理。处理结束后，将Stream\<Character>重新拼接成字符串即可

关于将泛型为字符的流拼接成字符串，存在多种方法，我只列出其中两种作为参考：

## 使用collect()收集字符到StringBuilder中

Stream流的`collect()`方法存在三个参数的重载，原型为：

```java
<R> R collect(Supplier<R> supplier,
              BiConsumer<R, ? super T> accumulator,
              BiConsumer<R, R> combiner);
```

- Supplier接口负责提供一个承装的容器，其泛型为提供的R，在此例中就是StringBuilder；

- 第一个BiConsumer接口表示进行的操作，其接口泛型为指定的R、指定的T的任意超类或T本身。所以，在本例中，若使用匿名内部类的方式构建此接口，应该是：

  ```java
  BiConsumer<StringBuilder,Character> bc = new BiConsumer<StringBuilder, Character>() {
      @Override
      public void accept(StringBuilder stringBuilder, Character character) {
          stringBuilder.append(character);
      }
  } ;
  ```

- 第二个BiConsumer接口表示容器之间所进行的操作，这个操作发生在并行流之中，流会被拆分成多个部分并创建多个容器，此时就需要将容器们连接起来。在本例中单纯将StringBuilder组合起来即可，所以使用匿名内部类构建此接口的代码可以是：

  ```java
  BiConsumer<StringBuilder,StringBuilder> bc2 = new BiConsumer<StringBuilder, StringBuilder>() {
      @Override
      public void accept(StringBuilder stringBuilder, StringBuilder stringBuilder2) {
          stringBuilder.append(stringBuilder2);
      }
  };
  ```

又因为这些接口都只有一个抽象方法，因此可以在`collect()`方法中直接使用函数式接口。收集的代码是：

```java
StringBuilder sb = new StringBuilder();
sb = b.collect(StringBuilder::new, StringBuilder::append, StringBuilder::append);
String res = sb.toString();
```

最后得到字符串res就是凯撒密码的密文

## 列表 -> 字符数组 -> 字符串

也可以使用返回一个Collector对象的`Collectors.toList()`方法将流转为List\<Character>，接着对这个列表使用`toArray()`方法将之转化成字符数组Character[]，最后使用`Arrays.toString()`将字符数组转化为字符串

```java
List<Character> collect = chStream.collect(Collectors.toList());
Character[] characters = collect.toArray(new Character[collect.size()]);
String res = Arrays.toString(characters);
```

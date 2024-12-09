+++
date = '2022-09-05T09:49:04+08:00'
draft = false
title = 'Stream流进行数组排序'

+++

考虑一个数组：

```java
int[] nums = {9,6,5,7,4,8,3,1,2};
```

对于数组，列举几个转换Stream流的操作及返回值：

```java
//返回Stream对象，但泛型为int[]数组
Stream<int[]> nums1 = Stream.of(nums);
//返回一个IntStream对象，默认无泛型
IntStream nums2 = IntStream.of(nums);
IntStream nums3 = Arrays.stream(nums);
```

若想要对数组进行排序，则使用sorted()方法，但需要注意的是，IntStream的sorted无入参，即**只能自然排序**，只有Stream中的sorted才能指定比较器，所以将之转化为Stream类型，再进行排序：

```java
//使用boxed()将IntStream转换为Stream类型，即将IntStream中的每个整型都进行装箱
//nums2同理
Stream<Integer> boxedNums = nums3.boxed();
//进行排序
Stream<Integer> sortedNums = boxedNums.sorted((o1,o2) -> o2-o1);
```

排序完成后，仍是一个Stream对象。若想将之转换回数组，则使用toArray()方法

但仍然需要注意，在Stream中，由于Stream的泛用性，toArray()返回的是Object类型的数组，而非int类型，所以，需要首先转化为IntStream，表示其中存储的都是整型数据，然后使用该对象中的toArray()方法：

```java
//使用mapToInt转化为IntStream对象
//此处的intValue是将原本的Integer包装类转换为int基本类
IntStream temp = sortedNums.mapToInt(Integer::intValue);
//最终转换为数组
int[] res = temp.toArray();
```

以下总结前文提到的Stream和IntStream的同名方法及必要说明，方便判断是否需要进行对象类型的转换：

**Stream:**

- Stream<T> of(T t)：返回一个Stream对象，其泛型是参数泛型
- Stream sorted()：可带参可不带参
- Object[] toArray()：返回一个Obj的数组

**IntStream：**

- IntStream of(int... values)：返回一个IntStream对象，直接存有数组每个元素
- IntStream sorted()：只有无参的
- int[] toArray()：返回一个int的数组

此外，Arrays.stream()也能返回一个IntStream对象，效果与IntStream.of()一致，且其针对数据数组有更多重载，泛用性更强

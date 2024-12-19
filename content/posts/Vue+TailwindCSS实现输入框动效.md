+++
date = '2024-12-19T10:18:12+08:00'
draft = false
title = 'Vue+TailwindCSS实现输入框动效'
tags = ["Vue","TailwindCSS"]
categories = ["前端"]
showToc = true
math = false

+++

实现目标：

**静态属性**：输入框位于页面顶端、居中，圆角，框体内部为白色，1/5屏幕宽度，无外边框、框体阴影，闪烁光标为蓝色

**动态属性**：鼠标悬停时框体微微变大；聚焦后出现蓝色外边框，宽度增长且仍保持居中，框体阴影变为蓝色

**其他**：聚焦输入框时，背景逐渐模糊，取消聚焦后恢复

## 静态设计

HTML中的`<input>`标签可以承担基本的输入功能，创建文件SearchItem.vue，接下来使用TailwindCSS对默认输入框标签的样式进行调整

对于输入框位置与默认宽度的要求，可以使用网格布局，每行5列，而输入框位于第三列，这一布局设定应当在上层的文件中，而非SearchItem文件，所以这里先不对其进行设置

圆角、无外边框、框体阴影和蓝色光标可以使用`rounded-xl`、`outline-none`、`shadow-xl`、`caret-blue-500`来实现

**考虑到后续会添加样式切换的动效**，需要再加上`transition-all`以保证样式更改过程是平滑的

## 动态设计

TailwindCSS中，鼠标悬停的样式只需要使用`hover:`即可；获取焦点时的样式只需要使用`focus:`

- 悬停时框体变大：`hover:scale-105`

  为了使悬停 -> 聚焦之后框体大小保持稳定，同时设置`focus:scale-105`

- 聚焦后出现蓝色外边框：`focus:border-2`、`border-blue-500`

- 宽度增长且仍居中，可以将元素左移的同时将宽度增加与之相同的长度：`focus:-translate-x-40`、`focus:w-[40rem]`

- 框体阴影变为蓝色：`focus:shadow-blue-300/50`

另外，可以设置转化的时长，这里设置400ms：`duration-[400ms]`

---

至此，对输入框的样式设计完成：

```vue
<template>
  <input
    placeholder="搜索"
    class="shadow-xl duration-[400ms] hover:scale-105 focus:-translate-x-40 focus:w-[40rem] focus:border-2 focus:shadow-blue-300/50 focus:scale-105 border-blue-500 px-5 py-3 rounded-xl w-full transition-all outline-none caret-blue-500"
    name="search"
    type="search"
  />
</template>
```

## 上层结构

在上层文件中引入SearchItem.vue，然后设置网格布局并使这一模板位于5列中的第三列：

```vue
<script setup lang="ts">
import searchItem from "./components/SearchItem.vue";
</script>
<template>
  <div>
    <div class="grid grid-cols-5 gap-4 mt-2">
      <searchItem class="col-start-3" />
    </div>
  </div>
</template>
```

效果如下：

{{< figure align=center src="../../img/搜索框动效.gif" >}}

为了使输入框能够输入内容，需要将输入的文字绑定至Vue中：

```vue
<script setup lang="ts">
import { ref } from "vue";
defineOptions({
  name: "searchItem",
});
const input = ref("");
</script>
<template>
  <input
    placeholder="搜索"
    class="shadow-xl duration-[400ms] hover:scale-105 focus:-translate-x-40 focus:w-[40rem] focus:border-2 focus:shadow-blue-300/50 focus:scale-105 border-blue-500 px-5 py-3 rounded-xl w-full transition-all outline-none caret-blue-500"
    name="search"
    type="search"
    v-model="input"
  />
</template>
```

## 背景模糊

接下来添加背景模糊

一般实现这种全局效果，例如背景变暗等，都需要使用**全局蒙版**，这里也通过全局蒙版的方式实现

首先在主文件中设置一个`<div>`标签，并设置其`class`：`w-screen h-screen top-0 left-0 fixed`，如此即可实现全局蒙版

接着为了使搜索框不被影响，设置这两个元素在z轴上的位置，即需要在`<SearchItem>`标签中添加`z-10`样式，然后在`<div>`蒙版中添加`z-[5]`样式，这就保证了`<SearchItem>`被叠放在`<div>`蒙版之上，不受蒙版的影响

最后为蒙版添加**背景模糊**样式：`backdrop-blur-sm`

> 注意这里是背景模糊而非普通的模糊`blur`，这是因为`blur`是指对元素内部的子元素进行模糊处理，而`backdrop-blur-sm`才是对元素的背景进行模糊处理

---

因为需要让模糊“逐渐出现”，所以这个蒙版的出现方式不应是“隐藏 -> 出现”，而应该是**一直出现但并不进行背景模糊，当搜索框获得焦点时平滑地将样式修改为背景模糊**

因此这个`<div>`的设置应为：

```vue
<div
  class="w-screen h-screen top-0 left-0 fixed z-[5] transition-all duration-500"
  :class="
    showCover ? 'backdrop-blur-sm' : 'backdrop-blur-none bg-transparent'
  "
></div>
```


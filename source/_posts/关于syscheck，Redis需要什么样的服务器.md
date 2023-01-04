---
title: 关于syscheck，Redis需要什么样的服务器
abbrlink: 37854
date: 2023-01-04 22:56:45
tags:
---
在Redis7中，支持了对系统的check逻辑，其中就包含了4类检查操作：
1. slow-clocksource
2. xen-clocksource
3. overcommit
4. THP

今天，我们来一一介绍一下各个检查的功效，一遍不时之需。

## 如何检查

检查的命令不算太麻烦：

```
./redis-server --check-system
```

这个命令没有更多的参数，它会一一的对所有的check进行遍历处理。

## slow-clocksource

验证clokcsource实现没有经过系统调用（使用vdso）。通过系统调用检查时间会降低Redis的性能。

### 什么是clocksource

clock source用于为linux内核提供一个时间基线，如果你用linux的date命令获取当前时间，内核会读取当前的clock source，转换并返回合适的时间单位给用户空间。在硬件层，它通常实现为一个由固定时钟频率驱动的计数器，计数器只能单调地增加，直到溢出为止。时钟源是内核计时的基础，系统启动时，内核通过硬件RTC获得当前时间，在这以后，在大多数情况下，内核通过选定的时钟源更新实时时间信息（墙上时间），而不再读取RTC的时间。

clock source 本身也自带不同的类型，其中查看方式如下：
```
/sys/devices/system/clocksource/clocksource0/available_clocksource
/sys/devices/system/clocksource/clocksource0/current_clocksource
```

前者代码可用的时钟源，而后者代码当前使用的时钟源。

### 如何检查

在 Redis 层面，RD 更关心的是时钟是否可靠。于是，检查逻辑会统计前后的时钟情况，并通过 busy loop 等待足够长的时间（50ms）

```
if (getrusage(RUSAGE_SELF, &ru_start) != 0)
	return 0;
if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) {
	return 0;
}
start_us = (ts.tv_sec * 1000000 + ts.tv_nsec / 1000);
	
test_time_us = 5 * 1000000 / system_hz;
while (1) {
	unsigned long long d;
	if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
		return 0;
	d = (ts.tv_sec * 1000000 + ts.tv_nsec / 1000) - start_us;
	if (d >= test_time_us) break;
}
if (getrusage(RUSAGE_SELF, &ru_end) != 0)
	return 0;
```


> CLOCK_MONOTONIC 指的是 monotonic time，而 CLOCK_REALTIME 指的是 wall time。
> Monotonic time 的字面意思是单调时间，实际上，指的是系统启动之后所流逝的时间，这是由变量 jiffies 来记录的，当系统每次启动时，jiffies 被初始化为 0，在每一个 timer interrupt 到来时，变量 jiffies 就加上 1，因此这个变量代表着系统启动后的流逝 tick 数。jiffies 一定是单调增加的，因为时间不可逆。

如果超过10%的处理时间是在系统调用中，我们可能有低效的时钟源。故认为是存在移除。

## xen-clocksource

这个就比较简单，由于上述已经介绍过了什么是clocksource，所以，此次的测试就是为了避开xen的时钟源。

主要原因是xen虚拟机监控程序的默认时钟源很慢，会影响Redis的性能。这是在基于ec2-xen的实例上测量的。ec2建议对这些实例使用非默认tsc时钟源。

## overcommit

当禁用过度使用内存时，Linux将杀死后台保存的进程。如果我们没有足够的空闲内存来满足当前内存使用量的两倍，即使子进程使用写时复制来减少其实际内存使用量

### 什么是overcommit

我们知道，由于MMU实现了虚拟地址到物理地址的转换，所以我们在申请虚拟地址时往往可以申请一大块内存，这实际上是对资源的有效利用，毕竟只有内存真正被投入使用时（如memset）才会实际分配物理内存，这种允许内存超额commit的机制就是overcommit_memory。

虚拟内存需要物理内存作为支撑，当分配了太多虚拟内存，导致物理内存不够时，就发生了Out Of Memory。这种允许超额commit的机制就是overcommit。

Linux根据参数vm.overcommit_memory设置overcommit：

- 0 ——默认值，启发式overcommit，它允许overcommit，但太明显的overcommit会被拒绝，比如malloc一次性申请的内存大小就超过了系统总内存。
- 1 ——Always overcommit. 允许overcommit，对内存申请来者不拒。
- 2 ——不允许overcommit，提交给系统的总地址空间大小不允许超过。

### 检查方式

检查手段这是确定overcommit是否打开：
```
/proc/sys/vm/overcommit_memory
```

Redis是一个吃内存大户，故建议服务能打开 overcommit。

## THP

### 关于 THP

在 Linux 中大页分为两种： Huge pages ( 标准大页 ) 和  Transparent Huge pages( 透明大页 ) 。

Huge pages  是从 Linux Kernel 2.6 后被引入的，目的是通过使用大页内存来取代传统的 4kb 内存页面， 以适应越来越大的系统内存，让操作系统可以支持现代硬件架构的大页面容量功能。

Transparent Huge Pages  缩写  THP ，这个是 RHEL 6 开始引入的一个功能，在 Linux6 上透明大页是默认启用的。

由于 Huge pages 很难手动管理，而且通常需要对代码进行重大的更改才能有效的使用，因此 RHEL 6 开始引入了 Transparent Huge Pages （ THP ）， THP 是一个抽象层，能够自动创建、管理和使用传统大页。

这两者最大的区别在于 :  标准大页管理是预分配的方式，而透明大页管理则是动态分配的方式。

### 检查方式

服务需要确保不总是启用透明的大页面。如果是这样，则会导致写时复制逻辑消耗更多的内存，并降低 fork 期间的性能。

```
cat /sys/kernel/mm/transparent_hugepage/enabled
```

其中需要确保配置不为 always。故可以将其修改为 madvise ，表示可以通过madvise 来申请大页面，而非长期打开。

### 关于madvise

madvise() 函数建议内核，在从 addr 指定的地址开始，长度等于 len 参数值的范围内，该区域的用户虚拟内存应遵循特定的使用模式。内核使用这些信息优化与指定范围关联的资源的处理和维护过程。如果使用 madvise() 函数的程序明确了解其内存访问模式，则使用此函数可以提高系统性能。

madvise() 函数提供了以下标志，这些标志影响 lgroup 之间线程内存的分配方式：

- MADV_ACCESS_DEFAULT
此标志将指定范围的内核预期访问模式重置为缺省设置。

- MADV_ACCESS_LWP
此标志通知内核，移近指定地址范围的下一个 LWP 就是将要访问此范围次数最多的 LWP。内核将相应地为此范围和 LWP 分配内存和其他资源。

- MADV_ACCESS_MANY
此标志建议内核，许多进程或 LWP 将在系统内随机访问指定的地址范围。内核将相应地为此范围分配内存和其他资源。

## 相关文献

[Linux时间管理之hardware-Bean\_lee-ChinaUnix博客](http://blog.chinaunix.net/uid-24774106-id-3902906.html)
[Huge pages (标准大页)和 Transparent Huge pages(透明大页)](https://blog.csdn.net/lihuarongaini/article/details/101298358)
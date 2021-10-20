---
title: Redis中的内存管理
date: 2021-09-15 00:54:20
tags: 从0开始的Redis
---

## 零、从问题出发

- 使用的是哪个内存管理器
- 内存是如何淘汰的
- 不同的结构体的内存结构
- 内存如何优化
- 内存的分类

## 一、 内存消耗

理解Redis内存， 首先需要掌握Redis内存消耗在哪些方面。 有些内存消耗是必不可少的， 而有些可以通过参数调整和合理使用来规避内存浪费。 内存消耗可以分为进程自身消耗和子进程消耗。

### 内存使用统计

首先需要了解Redis自身使用内存的统计数据， 可通过执行info memory命令获取内存相关指标。 读懂每个指标有助于分析Redis内存使用情况：

| 属性名                  | 属性说明                                                |
| :---------------------- | :------------------------------------------------------ |
| used_memory             | Redis分配器分配的内存总量，内存存储的所有数据内存占用量 |
| used_memory_human       | 以可读的格式返回used_memory                             |
| used_memory_rss         | 以操作系统的角度显示Redis进程占用的物理内存总量         |
| used_memory_peak        | 内存使用的最大值                                        |
| used_memory_peak_human  | 以可读的格式返回used_memory_peak                        |
| used_memory_lua         | Lua引擎消耗的内存大小                                   |
| mem_fragmentation_ratio | used_memory_rss/used_memory比值，表示内存碎片率         |
| mem_allocator           | Redis所使用的内存分配器，默认为jemalloc                 |

需要重点关注的指标有： used_memory_rss和used_memory以及它们的比值mem_fragmentation_ratio。

当mem_fragmentation_ratio>1时， 说明used_memory_rss - used_memory多出的部分内存并没有用于数据存储， 而是被内存碎片所消耗， 如果两者相差很大， 说明碎片率严重。

当mem_fragmentation_ratio<1时， 这种情况一般出现在操作系统把Redis内存交换（Swap）到硬盘导致， 出现这种情况时要格外关注， 由于硬盘速度远远慢于内存， Redis性能会变得很差， 甚至僵死。

### 内存消耗划分

Redis进程内消耗主要包括： 自身内存+对象内存+缓冲内存+内存碎片，其中Redis空进程自身内存消耗非常少， 通常used_memory_rss在3MB左右，used_memory在800KB左右， 一个空的Redis进程消耗内存可以忽略不计。Redis主要内存消耗如图所示。

1. 对象内存 对象内存是Redis内存占用最大的一块， 存储着用户所有的数据。Redis所有的数据都采用key-value数据类型， 每次创建键值对时， 至少创建两个类型对象： key对象和value对象。 对象内存消耗可以简单理解为sizeof（keys）+sizeof（values） 。 键对象都是字符串， 在使用Redis时很容易忽略键对内存消耗的影响， 应当避免使用过长的键。 value对象更复杂些， 主要包含5种基本数据类型： 字符串、 列表、 哈希、 集合、 有序集合。 其他数据类型都是建立在这5种数据结构之上实现的， 如： Bitmaps和HyperLogLog使用字符串实现， GEO使用有序集合实现等。每种value对象类型根据使用规模不同， 占用内存不同。 在使用时一定要合理预估并监控value对象占用情况， 避免内存溢出。
2. 缓冲内存 缓冲内存主要包括： 客户端缓冲、 复制积压缓冲区、 AOF缓冲区。

客户端缓冲指的是所有接入到Redis服务器TCP连接的输入输出缓冲。输入缓冲无法控制， 最大空间为1G， 如果超过将断开连接。 输出缓冲通过参数client-output-buffer-limit控制， 如下所示：

- 普通客户端 除了复制和订阅的客户端之外的所有连接， Redis的默认配置是： client-output-buffer-limit normal000， Redis并没有对普通客户端的输出缓冲区做限制， 一般普通客户端的内存消耗可以忽略不计， 但是当有大量慢连接客户端接入时这部分内存消耗就不能忽略了， 可以设置maxclients做限制。 特别是当使用大量数据输出的命令且数据无法及时推送给客户端时，如monitor命令， 容易造成Redis服务器内存突然飙升。
- 从客户端 主节点会为每个从节点单独建立一条连接用于命令复制，默认配置是： client-output-buffer-limit slave256mb64mb60。 当主从节点之间网络延迟较高或主节点挂载大量从节点时这部分内存消耗将占用很大一部分， 建议主节点挂载的从节点不要多于2个， 主从节点不要部署在较差的网络环境下， 如异地跨机房环境， 防止复制客户端连接缓慢造成溢出。
- 订阅客户端 当使用发布订阅功能时， 连接客户端使用单独的输出缓冲区， 默认配置为： client-output-buffer-limit pubsub32mb8mb60， 当订阅服务的消息生产快于消费速度时， 输出缓冲区会产生积压造成输出缓冲区空间溢出。

输入输出缓冲区在大流量的场景中容易失控， 造成Redis内存的不稳定， 需要重点监控。

复制积压缓冲区：Redis在2.8版本之后提供了一个可重用的固定大小缓冲区用于实现部分复制功能， 根据repl-backlog-size参数控制， 默认1MB。对于复制积压缓冲区整个主节点只有一个， 所有的从节点共享此缓冲区， 因此可以设置较大的缓冲区空间， 如100MB， 这部分内存投入是有价值的， 可以有效避免全量复制。

AOF缓冲区： 这部分空间用于在Redis重写期间保存最近的写入命令，AOF缓冲区空间消耗用户无法控制， 消耗的内存取决于AOF重写时间和写入命令量， 这部分空间占用通常很小。

1. 内存碎片 Redis默认的内存分配器采用jemalloc， 可选的分配器还有： glibc、tcmalloc。 内存分配器为了更好地管理和重复利用内存， 分配内存策略一般采用固定范围的内存块进行分配。 例如jemalloc在64位系统中将内存空间划分为： 小、 大、 巨大三个范围。 每个范围内又划分为多个小的内存块单位，如下所示：

- 小： [8byte]， [16byte， 32byte， 48byte， ...， 128byte]， [192byte，256byte， ...， 512byte]， [768byte， 1024byte， ...， 3840byte]
- 大： [4KB， 8KB， 12KB， ...， 4072KB]
- 巨大： [4MB， 8MB， 12MB， ...]

比如当保存5KB对象时jemalloc可能会采用8KB的块存储， 而剩下的3KB空间变为了内存碎片不能再分配给其他[对象存储](https://cloud.tencent.com/product/cos?from=10680)。 内存碎片问题虽然是所有内存服务的通病， 但是jemalloc针对碎片化问题专门做了优化， 一般不会存在过度碎片化的问题， 正常的碎片率（mem_fragmentation_ratio） 在1.03左右。 但是当存储的数据长短差异较大时， 以下场景容易出现高内存碎片问题：

- 频繁做更新操作， 例如频繁对已存在的键执行append、 setrange等更新操作。
- 大量过期键删除， 键对象过期删除后， 释放的空间无法得到充分利用， 导致碎片率上升。

出现高内存碎片问题时常见的解决方式如下：

- 数据对齐： 在条件允许的情况下尽量做数据对齐， 比如数据尽量采用数字类型或者固定长度字符串等， 但是这要视具体的业务而定， 有些场景无法做到。
- 安全重启： 重启节点可以做到内存碎片重新整理， 因此可以利用高可用架构， 如Sentinel或Cluster， 将碎片率过高的主节点转换为从节点， 进行安全重启。

### 子进程内存消耗

子进程内存消耗主要指执行AOF/RDB重写时Redis创建的子进程内存消耗。 Redis执行fork操作产生的子进程内存占用量对外表现为与父进程相同，理论上需要一倍的物理内存来完成重写操作。 但Linux具有写时复制技术（copy-on-write） ， 父子进程会共享相同的物理内存页， 当父进程处理写请求时会对需要修改的页复制出一份副本完成写操作， 而子进程依然读取fork时整个父进程的内存快照。

Linux Kernel在2.6.38内核增加了Transparent Huge Pages（THP） 机制， 而有些Linux发行版即使内核达不到2.6.38也会默认加入并开启这个功能， 如Redhat Enterprise Linux在6.0以上版本默认会引入THP。 虽然开启THP可以降低fork子进程的速度， 但之后copy-on-write期间复制内存页的单位从4KB变为2MB， 如果父进程有大量写命令， 会加重内存拷贝量， 从而造成过度内存 消耗。 例如， 以下两个执行AOF重写时的内存消耗日志：

```javascript
// 开启THP:
C * AOF rewrite: 1039 MB of memory used by copy-on-write
// 关闭THP:
C * AOF rewrite: 9 MB of memory used by copy-on-write
```

这两个日志出自同一Redis进程， used_memory总量为1.5GB， 子进程执行期间每秒写命令量都在200左右。 当分别开启和关闭THP时， 子进程内存消耗有天壤之别。 如果在高并发写的场景下开启THP， 子进程内存消耗可能是父进程的数倍， 极易造成机器物理内存溢出， 从而触发SWAP或OOM killer。

子进程内存消耗总结如下：

- Redis产生的子进程并不需要消耗1倍的父进程内存， 实际消耗根据期间写入命令量决定， 但是依然要预留出一些内存防止溢出。
- 需要设置sysctl vm.overcommit_memory=1允许内核可以分配所有的物理内存， 防止Redis进程执行fork时因系统剩余内存不足而失败。
- 排查当前系统是否支持并开启THP， 如果开启建议关闭， 防止copy-onwrite期间内存过度消耗。


## 二、


## 相关链接
- https://www.cnblogs.com/wangiqngpei557/p/8323680.html
- https://blog.csdn.net/yahuuqq1314/article/details/100566688
- https://cloud.tencent.com/developer/article/1692195
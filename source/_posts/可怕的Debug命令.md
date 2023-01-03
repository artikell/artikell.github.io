---
title: 可怕的Debug命令
abbrlink: 20649
date: 2023-01-04 00:02:08
tags:
---

debug命令在在UT还是日常都是尖端科技。通过该命令可以对整个Redis实例进行特殊的处理，包括但不限于coredump、sleep、rdb、propagate等操作。本文单独针对不同的操作来记录debug命令的功能。

当然，在Redis7 中，支持了 enable_debug_cmd 配置，保证 debug 操作只在本机的客户端中才可执行。

### 无风险操作

```
debug help
```

help命令主要用于介绍debug的功能，但是并不齐全，这或许是避免胆大的用户的误操作吧。

```
debug log
```

打印一个DEBUG LOG 日志。

```
debug object <key>
```

打印一个数据的详细信息，包括相关的地址、引用次数、lru信息，以及encode信息，若是list，则会打印 list 的节点信息。

```
debug sdslen <key>
```

打印一个字符串数据的信息，主要是相关的空间信息

```
debug listpack <key>
```

打印一个 listpack 数据的信息

```
debug quicklist <key>
```

打印一个 quicklist 数据的信息

```
debug htstats-key <key>
```

打印一个 hash 数据的信息

```
debug htstats <dbid>
```

打印当前 db 的信息，包括 ht 和 expire ht 的大小信息

```
debug error
```

返回一个错误的响应

```
debug structsize
```

打印当前系统个类型的大小信息

```
debug client-eviction
```

显示低级客户端逐出池信息，主要确定 client 的状态信息

### 高风险操作

```
debug segfault
```

触发段错误，实现的方式就是mmap申请一个只读的空间，然后再去对其进行赋值。

```
debug panic
```

触发panic错误，这个操作会触发正常的日志打印。主要用于ut层面模拟服务异常

```
debug restart
debug crash-and-recover
```

触发重启，如果是 restart 模式，或进行config rewrite 以及 bgsave 操作，否则会直接进行 crash 操作，默认服务故障。

```
debug oom
```

触发oom，这样主要是通过 zmalloc 申请一个 ULONG_MAX 大小的空间。

```
debug assert
```

触发 assert 失败操作，在整个 Redis 逻辑里面，会有各种的 assert 判断，当前操作主要是尝试触发一个 1 == 2 的失败判断，以确定 assert 是否有效。

```
debug leak
```

触发内存泄露，通过 sdsdup 申请一个泄露的内存空间


```
debug reload [MERGE|NOFLUSH|NOSAVE]
```

触发数据重载，其中 NOFLUSH 表示不清空原有数据，NOSAVE 表示不保存原有数据到 rdb 文件中，而 MERGE 表示尝试把数据进行加载合并


```
debug loadaof
```

触发 aof 加载，其中会进行数据清空，并重新从 aof 文件中加载数据。

```
debug drop-cluster-packet-filter
```

设置 cluster 模式下的包过滤类型。模拟丢包的情况。

```
debug sleep <sec>
```

休眠 sec 秒，支持double类型。

```
debug replicate <argv...>
```

人工触发一次命令传播，容易导致主从同步异常。

```
debug change-repl-id
```

重置 replid 信息，主要用于触发全量同步。

```
debug pause-cron <enable>
```

暂停 cron 操作，模拟 cron 时间过长

### 测试操作

```
debug populate <keys> <tag> <num>
```

模拟生成数据操作，其中会生成 keys 个带有 tag 的数据，每个的长度为 num。

```
debug digest
```

计算db中的快照信息，输出一个32位的字符串，当前方法是一个扫描全表的操作，风险极高。

```
debug digest-value <key...>
```

计算相关 key 的快照信息，每个 key 都输出一个32位的字符串

```
debug protocol [string|integer|double|bignum|null|array|set|map| attrib|push|verbatim|true|false]
```

测试当前的协议情况

```
debug stringmatch-test
```

进行字符串的模糊测试操作：`stringmatchlen_fuzz_test`


### 后台操作

```
debug set-active-expire <enable>
```

设置当前 expire 操作是否打开，用于避免触发过期操作引起的数据变化

```
debug quicklist-packed-threshold <threshold>
```

设置 quicklist 的打包阈值

```
debug set-skip-checksum-validation <enable>
```

设置是否需要跳过 rdb 的 sum 检查操作。

```
debug aof-flush-sleep <num>
```

设置 aof flush 的等待时间


```
debug config-rewrite-force-all
```

强制 rewrite 所有配置信息


```
debug set-disable-deny-scripts <enable>
```

禁止脚本中嵌套脚本操作


```
debug mallctl <argv>
debug mallctl-str <argv>
```

读取当前 jemalloc 的信息，用于定位内存问题

```
debug replybuffer <peak-reset-time <never|reset|<time> | resizing >
```

是否打开 客户端 buffer 的内存清理能力。
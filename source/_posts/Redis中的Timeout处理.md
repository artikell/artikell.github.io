---
title: Redis中的Timeout处理
abbrlink: 11484
date: 2023-01-10 23:07:22
tags:
---

今天简单的学习一下timeout的底层逻辑，本模块的逻辑是blocked以及client的底层支持。当然，这个抽象也是在Redis 6中进行了代码抽象。

在整个文件中包含三块逻辑：
1. 解析命令中的timeout的逻辑抽象
2. 处理阻塞client的超时逻辑
3. 阻塞client的操作管理

## client的超时管理

超时管理主要是基于rax树来管理，以timeout为key，client为value。同时支持了增删改查的逻辑操作：

- addClientToTimeoutTable
- removeClientFromTimeoutTable
- checkBlockedClientTimeout

而每个client都会记录自身的timeout，并对timeout进行编码。同时，client 会增加 CLIENT_IN_TO_TABLE 标记，表示自身已经写入 timeout 的 rax 树中。

## client超时处理

当 client 已经超时，则需要有地方去触发超时逻辑。其中包括三处逻辑：
- beforeSleep -> handleBlockedClientsTimeout
- unblockClient -> removeClientFromTimeoutTable
- clientsCron -> clientsCronHandleTimeout

前俩者主要是针对阻塞 client 的处理，其中会在解除阻塞、超时逻辑中删除在rax中的client信息并同时 unblock 当前的 client。而后者主要是检查 client 是否空闲过久，若是则直接关闭 client。

## 解析timeout逻辑

这个逻辑相对简单，就是针对不同单位的值读取 robj 信息，并对 timeout 的范围进行检查。


> 特殊逻辑：mustObeyClient 有趣的判断，不对aof和master的client进行处理。
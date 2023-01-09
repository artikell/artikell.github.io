---
title: 1月2日~1月8日-Redis周报
abbrlink: 65487
date: 2023-01-10 00:30:28
tags:
---

## CommitLog 分析

- [Fix issues with listpack encoded set (#11685)](https://github.com/redis/redis/commit/d0cc3de73f91ca79b2343e73e640b40709cfcaf5)

> 修复了OBJ_ENCODING_LISTPACK的内存统计方法
> 优化了ZRANDMEMBER可能出现的OOM操作，增加了每次申请空间的限制。

- [In cluster-mode enabled, override the databases config at startup to 1 (](https://github.com/redis/redis/commit/cb1fff3cb6a944d1f9cc67f8aa8b1d92648bbade)

> 在config中，对cluster-mode下的dbnum做处理，替换原有的exit操作

- [Include peer-addr:port and local-addr:port when logging accept errors (…](https://github.com/redis/redis/commit/a2e75a78b424a6faca4bba4b1bf8270b98407284)

> 日志中增加本地和对端的addr信息

- [Make redis-cli support PSYNC command (#11647)](https://github.com/redis/redis/commit/4ef4c4a686b6edaf825635d942b698349f67bcc6)

> 在redis-cli中支持PSYNC命令。【TODO】

- [Fix potential issue with Lua argv caching, module command filter and …](https://github.com/redis/redis/commit/c8052122a2af9b85124a8697488a0c44d66777b8)

> 在lua中，经过module的RM_CommandFilterArgInsert操作，可能导致原有的argv对象大小发生变化，但由于使用的zrealloc，地址并未变化，最终导致内存损坏，故增加了对argv_len的判断。

- [fix handshake timeout replication test race (#11640)](https://github.com/redis/redis/commit/0ecf6cdc0a81f79e6875191ef9aa4f16c9110223)

> 优化了主从同步时的超时时间设置，避免ci错误

- [Introduce .is\_local method for connection layer](https://github.com/redis/redis/commit/dec529f4be3e3314300bb513e7a9f3af636e13b0)

> 抽象了对本地client的判断逻辑，从原有的islocalClient抽象出了对各类连接的方法connIsLocal

- [Optimize the performance of msetnx command by call lookupkey only once (](https://github.com/redis/redis/commit/884ca601b21ec6ef4d216ae850c0cf503f762623)

> 优化mset的多次lookup操作

- [Add cluster info and cluster nodes to bug report (#11656)](https://github.com/redis/redis/commit/d2d6bc18ebc63265c2ee55ed79ab6ad2044b3bc3)

> 增加了cluster info命令以及在core后打印cluster的信息

- [reprocess command when client is unblocked on keys (#11012) · redis/redis@383d902](https://github.com/redis/redis/commit/383d902ce68131cf40d6122ce09e305e672e8555)

> 对blocked client做了很大量的重构，【TODO】
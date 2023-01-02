---
title: Redis中的Failover机制
abbrlink: 59749
date: 2023-01-02 22:37:08
tags:
---

在Redis7中，实现了主动的Failover机制，以支持用户能主动的进行主从切换。PR参考：[implement FAILOVER command by allenfarris · Pull Request #8315 · redis/redis](https://github.com/redis/redis/pull/8315)

### Failover命令

```
FAILOVER [ABORT] [TO <HOST> <IP>] [FORCE] [TIMEOUT <timeout>] 
```

命令包括几种操作：
- ABORT：直接中断failover操作
- TO：明确failover的实例
- FORCE：强制failover操作
- TIMEOUT：制定failover的超时时间，避免长时间的等待。

从最简单的failover操作来看，当前的操作必须在Master实例上运行，同时可以指定或者随机一个replica进行failover操作。

在设置完failover后，整个Master实例会进入一个 FAILOVER_WAIT_FOR_SYNC 的状态，同时暂停整个实例的变更，操作等同于`CLIENT PAUSE`

而在整个failover中，存在3类状态：
- NO_FAILOVER：无状态
- FAILOVER_WAIT_FOR_SYNC：等待同步
- FAILOVER_IN_PROGRESS：进行中

进入 FAILOVER_WAIT_FOR_SYNC 状态后，实例会定期检查当前的failover情况。若超时，则确定是否存在force标识，存在则强制进行切主操作。否则则中断 failover 进度。

正常流程，则会选择一个 replica 作为目标实例进行 failover。 目标实例的标准若非自行选择，则要求 offset 必须拉齐，保证数据完整性。

等待 replica 数据同步完成后，便进入 FAILOVER_IN_PROGRESS 进行实例切换。

### 实例切换

在 FAILOVER_IN_PROGRESS 过程中，需要关注什么下会转换为 NO_FAILOVER 状态。在建立关系后，旧 Master 收到新 Master 的 `+CONTINUE` 或 `+FULLRESYNC` 信息，则认为关系已经建立，可以清理掉 failover 状态。

而在建立连接时，旧 Master 会发送 `PSYNC <replid> <reploff> FAILOVER` 命令给新 Master。此操作主要是告知新 Master 需要从原有的 Replica 状态转换为 Master。

### 数据保证

在整个 Failover 过程中，旧 Master 会进行停写，同时，不再对所有 Replica 进行数据传输（包括PING操作），以此，实际的数据不会变化，这样对整个复制链的数据迁移是友好的。故，理论上在 主从切换时，大概率是增量同步，且数据不会丢失。
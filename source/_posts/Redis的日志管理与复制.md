---
title: Redis的日志管理与复制
abbrlink: 48988
date: 2023-01-02 19:53:33
tags:
---

## 日志复制队列

日志复制过程中，需要一个单独的队列来存储实际的日志信息。Redis中单独声明了replBacklog对象来保存：

```
typedef struct replBacklog {
    listNode *ref_repl_buf_node; /* Referenced node of replication buffer blocks,
                                  * see the definition of replBufBlock. */
    size_t unindexed_count;      /* The count from last creating index block. */
    rax *blocks_index;           /* The index of recorded blocks of replication
                                  * buffer for quickly searching replication
                                  * offset on partial resynchronization. */
    long long histlen;           /* Backlog actual data length */
    long long offset;            /* Replication "master offset" of first
                                  * byte in the replication backlog buffer.*/
} replBacklog;
```

histlen和offset分别代表当前的backlog长度以及相关的偏移量信息。

ref_repl_buf_node和blocks_index则专门指向backlog的数据。

整个backLog对象是通过独立的Block来存储日志信息，其实的管理通过单独的list字段 *repl_buffer_blocks* 来管理，同时通过rax树来记录offset和block的关系，以提高遍历速度：

```
typedef struct replBufBlock {
    int refcount;           /* Number of replicas or repl backlog using. */
    long long id;           /* The unique incremental number. */
    long long repl_offset;  /* Start replication offset of the block. */
    size_t size, used;
    char buf[];
} replBufBlock;
```

### 日志复制流程

Redis中的日志是通过command来传播。最终会形成字节流并通过feedReplicationBuffer方法写入给各个replica的缓冲区。

整个缓冲区是由多个black构成，整个block的大小取决于PROTO_REPLY_CHUNK_BYTES（16K）和实际写入的长度len：

```
size_t size = (len < PROTO_REPLY_CHUNK_BYTES) ? PROTO_REPLY_CHUNK_BYTES : len;
tail = zmalloc_usable(size + sizeof(replBufBlock), &usable_size);
```

若最后节点中的空闲空间足够，则不会单独申请空间。

新block加入后，会写入到各个slave的ref_repl_buf_node字段中，以表示当前需要复制的日志节点，同时会自增refcount，表示有节点在使用当前的block，不可被清理。

同时为了提高整个缓冲区的遍历速度，每64个block对象时，会写入一个index给replBacklog.blocks_index对象。同时，每次写入后，也会对整个backLog缓冲区进行清理，避免实际占有的空间过大。而一般的缓冲区大小限制值为1MB空间。

### 日志定位流程

在进行增量同步时，master会检查当前的offset是否满足增量同步。假定在满足条件的情况下，master就需要通过rax来快速定位实际的block对象，并写入给replica的缓冲区中。

```
	raxStart(&ri, server.repl_backlog->blocks_index);
	raxSeek(&ri, ">", (unsigned char*)&encoded_offset, sizeof(uint64_t));
```

主要是定位到大于offset的block node，并找到前置的node信息。而后，会从此node开始遍历，定位到实际的offset所在的node，设置为需要复制的数据。
```
	/* Install a writer handler first.*/
	prepareClientToWrite(c);
	/* Setting output buffer of the replica. */
	replBufBlock *o = listNodeValue(node);
	o->refcount++;
	c->ref_repl_buf_node = node;
	c->ref_block_pos = offset - o->repl_offset;
```

完成实际node的设置后，eventLoop将会调用writeToClient方法进行写入操作。

1. 针对未写完的block对象 (o->used > c->ref_block_pos)，则会继续写入。
2. 针对已写完的block对象就会直接找到下一个node，并重置写入的偏移量，以及尝试清理backLog空间。

## 日志复制链

说完单个节点上的缓冲区管理，整个副本维持的复制链模式还需要单独描述。由于主从关系存在级联的情况，在一整个复制链上，server需要拉齐整个offset的信息，以支持后续的HA操作。

### Replica的偏移信息

对于Master来说，在整个复制过程中，需要记录当前的Replica的复制情况。此时则需要多个字段来管理：

```
    long long read_reploff; /* Read replication offset if this is a master. */
    long long reploff;      /* Applied replication offset if this is a master. */
    long long repl_applied; /* Applied replication data count in querybuf, if this is a replica. */
    long long repl_ack_off; /* Replication ack offset, if this is a slave. */
    long long repl_ack_time;/* Replication ack time, if this is a slave. */
    long long psync_initial_offset; /* FULLRESYNC reply offset other slaves
                                       copying this slave output buffer
                                       should use. */
```

字段解释如下：

- read_reploff：当前已读的偏移量
- reploff：当前已执行的偏移量
- repl_applied：当前已写入的偏移量
- repl_ack_off：slave同步过来的offset
- repl_ack_time：slave同步的时间
- psync_initial_offset：当前slave使用的offset，在全量同步时用于定位缓冲区

前三者共同构建了replica在接收到master数据后的处理流程，以及决定当前的buffer是否已经失效。repl_applied是在Redis7后加入，具体原因参考：[optimize(remove) usage of client's pending\_querybuf by soloestoy · Pull Request #10413 · redis/redis](https://github.com/redis/redis/pull/10413)

而后三者主要是master中用于判断replica的信息，包括是否在线、数据是否同步成功、当前同步的数据信息等。

### Master的偏移信息

介绍完replica的偏移信息，还需要从master视角来确定偏移信息的表示。整个master侧的信息主要集中在 master_repl_offset 变量。

在全量同步完成后，master会发送offset给replica：
```
+FULLRESYNC <replid> <offset>
```

此时，replica会将其写入master_initial_offset变量中，当前变量则会赋予 master->reploff 和 master->read_reploff，这样也保证了reploff、read_reploff、master_repl_offset三者长时间的一致性。

同时，在数据加载阶段，master_repl_offset将从rdb文件中读取出来原有的repl_offset信息，并同时设置给backlog->offset。

在日志复制过程中，会对master_repl_offset进行累加。所以，在master和replica之间，也是通过rdb+log的方式来保证offset的正确性。
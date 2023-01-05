---
title: Redis中的内存统计
abbrlink: 39146
date: 2023-01-05 23:56:45
tags:
---

Redis中的内存计算，由于最初未使用很好的分类，导致最初的内存统计只能通过反推。通过各项指标的计算，并进行扣除已知的项目，剩余的内存被就认为是业务所需的空间。此文单独将相关的内存项目进行归纳，确定有多少空间是被认为是Redis自身所需的空间。

### 计算逻辑

由于整个计算逻辑相对比较简单，那当前就直接贴出代码：

```
int getMaxmemoryState(size_t *total, size_t *logical, size_t *tofree, float *level) {
    size_t mem_reported, mem_used, mem_tofree;

    /* Check if we are over the memory usage limit. If we are not, no need
     * to subtract the slaves output buffers. We can just return ASAP. */
    mem_reported = zmalloc_used_memory();
    if (total) *total = mem_reported;

    /* We may return ASAP if there is no need to compute the level. */
    if (!server.maxmemory) {
        if (level) *level = 0;
        return C_OK;
    }
    if (mem_reported <= server.maxmemory && !level) return C_OK;

    /* Remove the size of slaves output buffers and AOF buffer from the
     * count of used memory. */
    mem_used = mem_reported;
    size_t overhead = freeMemoryGetNotCountedMemory();
    mem_used = (mem_used > overhead) ? mem_used-overhead : 0;

    /* Compute the ratio of memory usage. */
    if (level) *level = (float)mem_used / (float)server.maxmemory;

    if (mem_reported <= server.maxmemory) return C_OK;

    /* Check if we are still over the memory limit. */
    if (mem_used <= server.maxmemory) return C_OK;

    /* Compute how much memory we need to free. */
    mem_tofree = mem_used - server.maxmemory;

    if (logical) *logical = mem_used;
    if (tofree) *tofree = mem_tofree;

    return C_ERR;
}
```

当前方法主要用于在内存淘汰的计算，故，优先判断 maxmemory 和 malloc 的空间，确定是否需要淘汰。

剩余的空间，主要是用于判断 无需处理的空间：overhead。这时候，整个逻辑可以得到3块数据：

1. logical - 实际业务使用的空间
2. tofree - 实际需要释放的空间
3. total - 总共申请的空间

同时，level 是为了给 Module 模式下用于判断空间情况。故本期不做详解。

### 非业务的空间

针对非业务空间，其实存在很多可以考虑的。但是，在整个社区版本中，主要针对俩块空间进行豁免：aof_buf、repl_buffer_mem。

```
    if ((long long)server.repl_buffer_mem > server.repl_backlog_size) {
        /* We use list structure to manage replication buffer blocks, so backlog
         * also occupies some extra memory, we can't know exact blocks numbers,
         * we only get approximate size according to per block size. */
        size_t extra_approx_size =
            (server.repl_backlog_size/PROTO_REPLY_CHUNK_BYTES + 1) *
            (sizeof(replBufBlock)+sizeof(listNode));
        size_t counted_mem = server.repl_backlog_size + extra_approx_size;
        if (server.repl_buffer_mem > counted_mem) {
            overhead += (server.repl_buffer_mem - counted_mem);
        }
    }

    if (server.aof_state != AOF_OFF) {
        overhead += sdsAllocSize(server.aof_buf);
    }
    return overhead;
```

其中，repl_buffer_mem 的空间，由于会被定期清理，故，主要会豁免掉超出的部分。

### 可观测的空间

既然整个的内存空间，并不能豁免太多空间，那么，我们还需要确定一下，哪些空间属于业务可观测。

此时，可观测的空间可以通过命令查看：
```
MEMORY DOCTOR
```

普通的字段信息：

|字段                   |描述   |来源|
|--|--|--|
|peak_allocated         |最大的内存空间|server.stat_peak_memory|
|peak_perc              |当前使用的空间占有的比例||
|total_allocated        |实际分配的全部|zmalloc_used|
|startup_allocated      |启动时的初始化空间|initial_memory_usage|
|repl_backlog           |实际的backlog空间||
|clients_slaves         |backlog超出的空间，Redis7独有||
|clients_normal         |普通客户端实际限制的空间|stat_clients_type_memory|
|cluster_links          |cluster模式下的连接空间|stat_cluster_links_memory|
|aof_buffer             |aof的buffer空间|aof_buf|
|lua_caches             |统计整个lua中使用的空间，包括script空间||
|functions_caches       |统计整个function中使用的空间||
|overhead_total         |包括所有的空间||
|dataset                |除去上述的空间后，剩下的数据空间||
|total_keys             |所有db的key个数|dictSize(db->dict)|
|bytes_per_key          |每个key平均占有的空间||
|dataset_perc           |数据空间的占比||

碎片空间的字段信息：

|字段                   |描述   |来源|
|--|--|--|
|total_frag             |实际使用空间较分配空间的比例|rss / used|
|total_frag_bytes       |实际使用空间超出分配空间的大小|rss - used|
|rss_extra              |实际使用空间较常驻空间的比例|rss / resident|
|rss_extra_bytes        |实际使用空间超出常驻空间的大小|rss - resident|
|allocator_frag         |活跃的空间较分配空间的比例|active / allocated|
|allocator_frag_bytes   |活跃的空间超出分配空间的大小|active - allocated|
|allocator_rss          |分配空间较活跃的空间的比例|resident / active|
|allocator_rss_bytes    |分配空间超出活跃的空间的大小|resident - active|


其中 resident, active, allocated 三个变量的意义至关重要：

- resident：实际使用的物理内存数，但是与OS的RSS不同，这里不包含共享库和other non heap mappings（这里的我的理解是一般的page分为Anonymous page和File-backed Pages，前者映射我们熟悉的堆栈，后者一般用于文件缓存，所以这里拿到的其实是进程实际的RSS减去共享库和File-backed Pages[1]）。
- active：与 resident 不同，这不包括 jemalloc 保留以供重用的页面(purge will clean that)。
- allocated：与 zmalloc_used_memory 不同，它通过考虑此进程完成的所有分配（不仅是 zmalloc）来匹配 stats.resident。zmalloc的内存计算中 AOF buffers 以及 slaves output buffers 不被计算在内。

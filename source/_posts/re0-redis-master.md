---
title: 主从复制数据同步
date: 2021-09-16 01:45:15
tags: 从0开始的Redis
---

## 零、从问题出发

## 一、前言

这篇开始要进入Redis集群的技术研究了，我们按照顺序会至少分四部分来介绍：**主从复制、哨兵模式、Gossip协议和一致性哈希以及Redis集群**。**主从复制**是高可用的基石，**哨兵模式**提供了主从架构中的自动故障恢复能力， **Gossip协议和一致性哈希**提供了集群中新加入节点和退出节点的发现以及节点加入或退出引起的数据重分配，最后基于上述的几个核心技术实现了高可用的**Redis集群**。

Redis作为一个内存数据库，使用主从架构的最核心的目的便是提供数据冗余备份，以防止一个Redis节点Down掉之后其中的数据也被丢失，而作为冗余备份，主从节点最重要的工作便是数据同步。那么本篇着重介绍的便是Redis的数据同步策略，包括主从节点首次建立连接后的**全量复制**以及从节点短暂断连后的数据**部分复制。**主要内容分为

1. **Redis主从复制概述**
2. **Redis主从数据同步**
3. **Redis读写分离实现以及过期数据处理**
4. **结语**

## 二、Redis主从复制概述

主从复制，是指将一台Redis服务器的数据复制到其他的Redis服务器，前者称为主节点(master/leader)，后者称为从节点(slave/follower)。一个主节点可以有多个从节点(或没有从节点)，但一个从节点只能有一个主节点，同时每个从节点也可以是别的从节点的父节点，即主从节点连接形成树结构。

![主从复制过程](https://p.pstatp.com/origin/pgc-image/4ae244e1829440078351db7231a1a9d6)

主从复制的发起都是在子节点发起，当节点127.0.0.1:6380中使用salveof 127.0.0.1 6379后，6380节点与6379节点的数据复制过程如下图所示。

**主从结构中数据的复制是单向的，只能由主节点到从节点**，所有的内存变更，即数据的增删改都只能在主节点上进行，从节点通过同步的方式完成修改。默认情况下，从节点对非Master节点客户端是只读的。Redis使用主从复制的作用有：

1. **数据冗余**：实现数据冗余备份，这样一台节点挂了之后，其上的数据不至于丢失。
2. **故障恢复**：当主节点出现问题时，其从节点可以被提升为主节点继续提供服务，实现快速的故障恢复；
3. **负载均衡**：在主从复制的基础上，配合读写分离，可以由主节点提供写服务，由从节点提供读服务（即写Redis数据时应用连接主节点，读Redis数据时应用连接从节点），分担服务器负载；尤其是在写少读多的场景下，通过多个从节点分担读负载，可以大大提高Redis服务器的并发量。

## 三、数据同步

接下来进入本文的重点——Redis主从节点的数据同步。作为内存数据库，Redis主从结构的核心目的在于数据备份。当节点A对节点B发起复制时，最直接的做法就是把节点B的内存数据生成快照文件（RDB）然后发送给节点A，节点A接收到RDB文件后将文件中的数据恢复到内存中，这就是**全量复制**。


![img](https://pic1.zhimg.com/80/v2-12a31457508682daabc7ea4f1c2e455c_720w.jpg)

## 四、全量复制

在Redis(1)中我们介绍过为了保障进程挂掉之后数据不至于丢失，Redis采用了RDB持久化和AOF持久化两种策略，这样当Redis重启后便可以从RDB文件或者AOF文件中恢复出数据。**而全量复制的核心就是把Master节点当前的数据全部发送给子节点**，那么显然，只要我们把Master节点的RDB文件或者AOF文件发给Slave节点就可以。这样Slave节点接收到文件之后就可以从文件中恢复出Master节点的数据。当然，为了保证主从节点一致，Slave节点从持久化文件中恢复数据之前首先应该清空自己内存中的所有数据。Redis提供了两种数据同步方式:RDB_CHILD_TYPE_DISK和RDB_CHILD_TYPE_SOCKET。所谓RDB_CHILD_TYPE_DISK就是将内存数据写入磁盘文件中，然后将磁盘文件发送给Slave节点, RDB_CHILD_TYPE_SOCKET即直接把内存数据写入Slave节点的socket文件进行发送而不需要先写入磁盘。由于不需要落盘，RDB_CHILD_TYPE_DISK的方式速度会更快，但是如果Master节点采用RDB_CHILD_TYPE_SOCKET向Slave节点发送数据时有新的节点发起数据同步请求，那么Master节点就需要重新再为新的Slave节点重新同步，而采用RDB_CHILD_TYPE_DISK生成RDB文件时如果有新的Slave节点加入数据复制，并不会引发新的RDB文件生成过程。二者各有利弊，但一般情况下我们会采用基于RDB_CHILD_TYPE_DISK的方式进行数据同步，同时也是限于篇幅，接下来的介绍中以RDB_CHILD_TYPE_DISK为主。

[大龙：Redis详解（1）——为什么我们都需要了解Redis47 赞同 · 2 评论文章![img](https://pic3.zhimg.com/v2-d7454c387a1257b6f819bb251b0a121e_180x120.jpg)](https://zhuanlan.zhihu.com/p/94680529)

在Redis的源码实现中。***replicationCron***函数被每秒调用一次。函数中会每次都会去判断是否有Slave节点处于等待数据同步的状态。如果有，则开始进行全量复制。 全量复制首先fork一个子进程调用***rdbSave***函数生成RDB文件，生成结束后调用回调函数***updateSlavesWaitingBgsave***将RDB文件发送给所有的Slave节点完成了同步过程。由于这部分实现代码非常的多，我就在下面把路径中的每个函数进行了大幅删减，主要展示整个过程中的函数调用关系，方便大家对着源代码阅读，大家从上往下读即可。

```c
// replication.c
// replicationCron函数每秒调用一次，代码被删减
void replicationCron(void) {
    /* Redis至多只允许一个子进程运行，而Master节点进行全量复制时需要fork一个子进程来进行RDB文件的生成*/
    if (!hasActiveChildProcess()) {
        time_t idle, max_idle = 0;
        int slaves_waiting = 0;
        int mincapa = -1;
        listNode *ln;
        listIter li;
        // 统计子节点中有多少个节点正在等待全量数据复制
        listRewind(server.slaves,&li);
        while((ln = listNext(&li))) {
            client *slave = ln->value;
            if (slave->replstate == SLAVE_STATE_WAIT_BGSAVE_START) {
                idle = server.unixtime - slave->lastinteraction;
                if (idle > max_idle) max_idle = idle;
                slaves_waiting++;
                mincapa = (mincapa == -1) ? slave->slave_capa :
                                            (mincapa & slave->slave_capa);
            }
        }
        // 如果有子节点在等待，则开始进行全量复制
        if (slaves_waiting )
        {
            startBgsaveForReplication(mincapa);
        }
    }
}

int startBgsaveForReplication(int mincapa) {
  
   int reval = rdbSaveBackground(server.rdb_filename,rsiptr);

}

int rdbSaveBackground(char *filename, rdbSaveInfo *rsi) {
    pid_t childpid;
    // fork一个子进程用于生成RDB文件
    if ((childpid = redisFork()) == 0) {
        int retval = rdbSave(filename,rsi);
    } 
}

/* 生成RDB文件*/
int rdbSave(char *filename, rdbSaveInfo *rsi) {
    // 省略代码...
}

/* 当RDB文件生成结束后，根据同步的方式来调用对应的回调函数 */
void backgroundSaveDoneHandler(int exitcode, int bysignal) {
    switch(server.rdb_child_type) {
    case RDB_CHILD_TYPE_DISK:
        backgroundSaveDoneHandlerDisk(exitcode,bysignal);
        break;
    case RDB_CHILD_TYPE_SOCKET:
        backgroundSaveDoneHandlerSocket(exitcode,bysignal);
        break;
    default:
        serverPanic("Unknown RDB child type.");
        break;
    }
}

// 基于RDB_CHILD_TYPE_DISK的回调函数中向所有 Slave节点发送RDB文件。
void backgroundSaveDoneHandlerDisk(int exitcode, int bysignal) {
   updateSlavesWaitingBgsave((!bysignal && exitcode == 0) ? C_OK : C_ERR, RDB_CHILD_TYPE_DISK);
}
```

全量复制的介绍就到这里，那么这里有一个问题是：全量复制只是复制了T1时刻Master节点的数据快照，那么之后客户端向Master节点的写入数据该如何同步给Slave节点？第一种显然的做法就是开启定时任务，每隔T时间就进行一次全量复制，完成一上面的所有操作即可。但是全量复制实际上是个成本很高的操作，大致分为如下几步：

1. Master节点开启子进程进行RDB文件生成
2. Master节点将RDB文件发送给Slave节点
3. Slave节点清空内存中的所有数据并删除之前的RDB文件
4. Slave节点使用从Master接收的RDB文件恢复数据到内存中

整个过程每一步都是耗时间的IO操作，比如Master节点在T1时刻开始RDB文件的生成，一直到T2时刻Slave节点才能完成数据载入。在网络环境较差或者IO能力较弱的情况下，上述的操作不仅耗时久，而且会因此导致主从节点数据延迟比较大（因为耗时，所以T会设置的比较大）。那么Redis为了解决这个问题，提出的解决方案是**命令传播+增量复制。**

## 五、命令传播

所谓命令传播当Master节点每处理完一个命令都会把命令广播给所有的子节点，而每个子节点接收到Master的广播过来的命令后，会在处理完之后继续广播给自己的子节点。需要注意的是，Redis的命令广播是异步的操作。即Master节点处理完客户端的命令之后会立马向客户端返回结果，而不会一直等待所有的子节点都确认完成操作后再返回以保证Redis高效的性能。

```c
void processInputBufferAndReplicate(client *c) {
    // 处理命令然后广播命令
    // if this is a slave, we just process the commands
    if (!(c->flags & CLIENT_MASTER)) {
        processInputBuffer(c);
    } else {
        /* If the client is a master we need to compute the difference
         * between the applied offset before and after processing the buffer,
         * to understand how much of the replication stream was actually
         * applied to the master state: this quantity, and its corresponding
         * part of the replication stream, will be propagated to the
         * sub-replicas and to the replication backlog. */
        size_t prev_offset = c->reploff;
        processInputBuffer(c);
        // applied is how much of the replication stream was actually applied to the master state
        size_t applied = c->reploff - prev_offset;
        if (applied) {

            replicationFeedSlavesFromMasterStream(server.slaves,
                    c->pending_querybuf, applied);
            sdsrange(c->pending_querybuf,applied,-1);
        }
    }
}
```

那么紧接着的另一个问题是，**如果某一个子节点A短暂的断连了T秒，那么A再次恢复连接之后该如何同步数据呢？**Redis选择的做法是开辟一个缓冲区（默认大小是1M)，每次处理完命令之后，先写入缓冲区repl_backlog, 然后再发送给子节点。这就是增量复制（也叫部分复制）。但是缓冲区能保存的命令有限，只能至多保存的命令长度为repl_backlog_length，如果某个子节点落后当前最新命令的长度大于了repl_backlog_length，那么就会触发全量复制。

## 六、读写分离和过期数据

主从复制的一大用处就是可以拓展单节点的读写性能，但是由于Redis中主从节点的数据复制时单向的，所以从节点对外是只读状态，而主节点是可读可写的状态。在读请求占比比较大的时候，让从节点参与响应读请求可以有效的分摊Master节点的压力。但是需要注意的是，由于主从节点之间可能存在数据的延迟，导致从子节点读到的数据可能是过期数据。其中一个典型的场景就是过期数据未能及时清理。由于数据的单向复制，子节点在Master节点不告知的情况下不会主动进行任何内存变更的操作，涉及到数据过期时，Redis采用的做法是当Master节点判断某个key过期了之后会向子节点发送DEL命令删除掉数据。但是如果期间由于网络环境或其他问题导致DEL命令未及时到达子节点，那么用户此时从子节点读到的数据就是本应已过期被删除的数据。为了解决这个问题，Redis从3.2版本之后，子节点也可以主动判断用户请求的键是否已经过期。如果过期，则就不向用户返回结果，但是并不会直接删除数据。删除数据的操作仍然是只会由Master节点的同步引起。这实际上是对主从的时钟同步是有要求的，绝大部分情况下这个先决条件还是能够被满足的。

## 七、结语

本文介绍了着重介绍了Redis主从复制的全量复制和部分复制，并简单的介绍了Redis主从分离对单点读写性能的扩展以及面临的数据延迟中的典型代表：数据过期问题。希望能对大家有所帮助。

## 八、后记

这篇文章写的真的是一坨翔，回到家专心工作比较艰难，都是零敲碎打的写东西。但是为了能不断更，所以也就硬着头皮往下写了。写之前看了很多资料，都是介绍了原理性的内容，自己不是很满意，于是就想读源码，从实现的角度来更详细的介绍主从复制。读完后才发现，从代码实现上讲并不会增加更多的细节，反而容易让读者抓不住重点。下次写就只写一个聚焦的话题，回北京之前不会再写这种涉及话题比较多的内容了。

## 相关链接
- [Redis集群——主从复制数据同步 - 知乎](https://zhuanlan.zhihu.com/p/102859170)
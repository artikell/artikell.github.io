---
title: 浅析levelDB流程（读写流程）
---

## 前言

打开流程完成了整个db的初始化，而后就是整个level对比的存储流程，如何读写db是核心业务。当然读写自然会触发压缩流程，但本文单纯只会串联整个的读写过程，保证内容的简洁，至于压缩则另开一篇详解。


## 写流程

### 命令封装

之前文章中，我们有提过更新的2个操作，在最后底层其实是一个操作：

```
func (db *DB) Put(key, value []byte, wo *opt.WriteOptions) error {
	return db.putRec(keyTypeVal, key, value, wo)
}

func (db *DB) Delete(key []byte, wo *opt.WriteOptions) error {
	return db.putRec(keyTypeDel, key, nil, wo)
}
```

可以看出，在`Put`和`Delete`命令中，最终会直接调用`putRec`方法，而在此方法中，做的核心逻辑就是，抢锁，并等待信息，其中抢锁的逻辑还是由`channel`实现，逻辑后续再理，先了解一下写入流程`writeLocked`方法：
```
batch := db.batchPool.Get().(*Batch)
batch.Reset()
batch.appendRec(kt, key, value)
return db.writeLocked(batch, batch, merge, sync)
```
调用该方法后，则就是AOF写入以及落入`memdb`跳表数据库中：
```
	// Seq number.
	seq := db.seq + 1

	// Write journal.
	if err := db.writeJournal(batches, seq, sync); err != nil {
		db.unlockWrite(overflow, merged, err)
		return err
	}

	// Put batches.
	for _, batch := range batches {
		if err := batch.putMem(seq, mdb.DB); err != nil {
			panic(err)
		}
		seq += uint64(batch.Len())
	}
```
至此，数据已经落入存储中，并返回告知请求处理正常。那么，这一套流程，中间还存在哪些问题呢？
其中提高吞吐、提高内存空间利用率则是中间的优化点。

### 合并写

关于吞吐量的计算逻辑可以参考：https://zhuanlan.zhihu.com/p/337708438

由于本身leveldb会写入内存，所以中间存在锁的抢占，而在golang中，leveldb使用的是channel进行锁争抢，当你能写入writeLockC管道时，便可以继续写入操作。然而，锁的争抢必定会导致性能下降，那么，合并写就成为了提供性能的一个解决方案。

合并锁的逻辑就是，优先尝试写入writeMergeC管道中，如果写入成功，则等待合并写的结果返回
```
case db.writeMergeC <- writeMerge{sync: sync, keyType: kt, key: key, value: value}:
    if <-db.writeMergedC {
        // Write is merged.
        return <-db.writeAckC
    }
    // Write is not merged, the write lock is handed to us. Continue.
case db.writeLockC <- struct{}{}:
    // Write lock acquired.
case err := <-db.compPerErrC:
    // Compaction error.
    return err
case <-db.closeC:
    // Closed
    return ErrClosed
}
```
而如果合并锁写入不成功，则尝试去抢写入锁，如果当前写入锁还是没有释放，那其中有可能导致异常出现（猜测）。
而在抢到写入锁的协程中，则会不断的等待合并写的请求达到上限
```
merge: 

for mergeLimit > 0 {
    select {
    case incoming := <-db.writeMergeC:
        ... ...
    default:
        break merge
    }
}
```
由此可见，当一次写入异常时，常常会阻塞所有的合并写异常，所有，合并写其实是针对大数据量的变更。

当然，如果处理完成后，则会写入writeAckC管道告知等待的写入，但是如果此次合并写并没有写入完成写入，则会使其抢锁成功，并自身去进行写入，这块逻辑便是之前的writeMergeC和writeLockC逻辑。
```
func (db *DB) unlockWrite(overflow bool, merged int, err error) {
	for i := 0; i < merged; i++ {
		db.writeAckC <- err
	}
	if overflow {
		// Pass lock to the next write (that failed to merge).
		db.writeMergedC <- false
	} else {
		// Release lock.
		<-db.writeLockC
	}
}
```


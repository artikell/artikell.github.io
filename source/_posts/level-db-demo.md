---
title: LevelDB实践
---

关于LevelDB，众所周知就是google基于lsm不断演化出来的一种kv存储库。而中间有各种语言的不同版本，今天则直接介绍一下golang版本中的一下实例。

### 基本功能
作为kv存储库，本身leveldb并不是和redis以及mysql一样拥有自己的独立服务，它本身是作为一个三方库，支持各个服务直接使用，这更像sqllite的能力，这中间就需要指定一个路径作为数据库的基本空间。

```
db, err := leveldb.OpenFile("path/to/db", nil)
...
defer db.Close()
```
通过OpenFile方法，便可以指定对应的数据库路径，第二个参数则是当前数据库的相关属性，例如过滤器类型、缓存大小、压缩属性相关，这块就放在后面细说

当打开数据库后，kv存储基本上就是3类操作：插入和查询、删除，只不过删除在最底层实现也还是插入逻辑。具体使用也是如下：
```
err = db.Put([]byte("key"), []byte("value"), nil)

if err != nil {
	panic(err)
}

data, err := db.Get([]byte("key"), nil)

if err != nil {
	panic(err)
}

fmt.Println(data)

err = db.Delete([]byte("key"), nil)

if err != nil {
	panic(err)
}  
```
方法基本上没有什么特殊之处，而第二个参数都是操作中基本上需要的一下配置化信息：插入和更新操作关心**是否强制落库**以及**是否支持合并写入**、而查询所关心的则是**是否不走缓存**。

当然，为了高性能，leveldb本身也支持批量插入
```
batch := new(leveldb.Batch)
batch.Put([]byte("foo"), []byte("value"))
batch.Put([]byte("bar"), []byte("another value"))
batch.Delete([]byte("baz"))
err = db.Write(batch, nil)
```
批量插入的核心优点就是会打开一个事务保证此次的插入原子性。关于本身事务的实现，这也是后续的一个课题。

### 遍历

当数据的存储已经给出实例，那这块还需要有检索能力，才能支持更丰富的应用场景。
而关于遍历。由于本身是一个高性能的并发数据库，当并行时出现变更，则会导致遍历异常，而若直接加锁，则会导致性能的大规模损坏。这也映射了mysql中的mvcc实现。
在leveldb中，直接使用的是迭代器+快照的方法来实现遍历能力。而遍历本身也就分为全局遍历、部分遍历、范围遍历、匹配遍历。这块也暂时举几个🌰，让人有直观的印象。
```
	for i := 0; i < 5; i++ {
		db.Put([]byte(gofakeit.Name()), []byte(gofakeit.Address().Address), nil)
	}

	iter := db.NewIterator(nil, nil)
	for iter.Next() {
		// Remember that the contents of the returned slice should not be modified, and
		// only valid until the next call to Next.
		key := iter.Key()
		value := iter.Value()
		fmt.Println("all date: ", string(key), " -> ", string(value))
	}
	iter.Release()
```
> 生成数据本身使用的是`github.com/brianvoe/gofakeit`
而针对范围遍历。我们只需要更改一下迭代器的生成即可：
```
iter = db.NewIterator(&util.Range{Start: []byte("Trinity Runte"), Limit: []byte("Vito Gulgowski")}, nil)
```
部分遍历。则是通过迭代器本身的seek方法来找到偏移量：
```
iter.Seek([]byte("Trinity Runte"))
```
还有一个有趣的点是，遍历能支持前缀匹配：
```
iter := db.NewIterator(util.BytesPrefix([]byte("foo-")), nil)
```
关于遍历本身，其实么有特别多好讲的，更多的是遍历对性能上是一个较大的损失，因为本身leveldb是分层文件，遍历则表示需要将所有数据全部查询，其中也就包括热点和非热点数据，这样会变现导致io的压力增加。

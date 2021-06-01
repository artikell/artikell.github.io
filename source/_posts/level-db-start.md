---
title: 浅析levelDB流程（打开流程）
---

## 前言
核心是逐步学习leveldb的实现，而其中一步步从读写开始学习相关实现

## 打开的方法
从上文的demo，我们可以看出常见的打开方式是传入一个文件夹目录，方法是`OpenFile`，而针对各种常见，leveldb也提供了多种方法，例如可以自身传入一个存储方式的`Open(stor storage.Storage, o *opt.Options)`、直接从目录中恢复数据的`RecoverFile(path string, o *opt.Options)`等。而此次，我们核心从基础的OpenFile方法中入手，看看在打开leveldb时，是如何进行初始化操作。

## 数据的获取
```
stor, err := storage.OpenFile(path, o.GetReadOnly())
```
最初引入眼帘的便是通过`storage.OpenFile`去持有一个存储对象。这其中可以使用内存作为存储，当然大部分情况还是使用文件存储。
在打开文件后，需要开始检查路径是否存在、检查文件锁是否存在。检查完这2项后，还有就是确定当前是否只读，如果只读，则不需要新建Log文件，因为Log文件是用于支持AOF能力，否则则需要重建。
当检查完成后，便会得到以下的结构体：
```
	fs := &fileStorage{
		path:     path,
		readOnly: readOnly,
		flock:    flock,
		logw:     logw,
		logSize:  logSize,
	}
```
结构体中核心包含路径、是否只读、是否锁，以及log文件相关数据
当然，还有有趣的一行代码是：
```
runtime.SetFinalizer(fs, (*fileStorage).Close)
```
这行代码的目的和析构函数类似，当对象销毁时，进行善后处理。

## 会话的构建
当已经持有存储对象时，第一步就开始针对存储对象构建会话session信息。
```
s, err := newSession(stor, o)
	s = &session{
		stor:      newIStorage(stor),
		storLock:  storLock,
		refCh:     make(chan *vTask),
		relCh:     make(chan *vTask),
		deltaCh:   make(chan *vDelta),
		abandon:   make(chan int64),
		fileRefCh: make(chan chan map[int64]int),
		closeC:    make(chan struct{}),
	}
```
会话中一个大的属性便是管道信息，可以见得session持有了多类管道，中间的能力简单来说就是，当leveldb中文件存在变更，都是通过session来进行异步操作。例如文件的删除和添加。而后会启动一个协程来辅助处理：
```
go s.refLoop()
```
得到session对象后，则需要用version对象来管理各个版本的文件信息，这也是保证leveldb中并发安全的基础
```
s.setVersion(nil, newVersion(s))
--- 

func newVersion(s *session) *version {
	id := atomic.AddInt64(&s.ntVersionId, 1)
	nv := &version{s: s, id: id - 1}
	return nv
}
```
当在初始化时，仅仅只是将version和session进行绑定。


## 奔溃恢复
初始化完基本信息，leveldb就进入了奔溃恢复流程，这也是所有存储不可避免的一个机制，包括mysql。而崩溃恢复也是针对session而已，最终核心也是恢复出上一次存储的version信息。
```
err = s.recover()
```
首先第一步恢复就是恢复当前的存储基本信息，这也映射到了leveldb中的current文件中对应的Manifest文件
```
	fd, err := s.stor.GetMeta()
	if err != nil {
		return
	}

	reader, err := s.stor.Open(fd)
	if err != nil {
		return
	}
	defer reader.Close()
```
得到Current文件后，就会生成一个记事本journal对象，这个对象管理着Log文件内容，而Manifest文件本书也是Log文件格式存储，所以，直接复用即可。
文件格式本文暂时不仔细描述，而从Manifest文件中，可以解析出，当前数据库使用的对比方法、压缩格式、各层级的文件信息，至此，我们就可以产生出一个新的version对象。

## 数据库对象构建
session本身是管理此次底层version的变更，而再上一层则需要一个db层来管理对外接口以及内存和文件的事件管理。所以，这一层更多的是压缩、和写入的管理：
```
db := &DB{
		s: s,
		// Initial sequence
		seq: s.stSeqNum,
		// MemDB
		memPool: make(chan *memdb.DB, 1),
		// Snapshot
		snapsList: list.New(),
		// Write
		batchPool:    sync.Pool{New: newBatch},
		writeMergeC:  make(chan writeMerge),
		writeMergedC: make(chan bool),
		writeLockC:   make(chan struct{}, 1),
		writeAckC:    make(chan error),
		// Compaction
		tcompCmdC:   make(chan cCmd),
		tcompPauseC: make(chan chan<- struct{}),
		mcompCmdC:   make(chan cCmd),
		compErrC:    make(chan error),
		compPerErrC: make(chan error),
		compErrSetC: make(chan error),
		// Close
		closeC: make(chan struct{}),
	}
```
由结构体可见大部分是针对压缩和写入合并使用的管道对象。
而生成完session后，仅仅只是吧以及落磁盘的level文件加载，而在崩溃前的内存数据还在丢失的，这些数据则需要从Log文件中恢复，这些则是在DB生成后恢复，当然恢复也是直接入memDB中，当做写入执行。中间必然也就触发了压缩和version的变更。

当Log文件恢复后，最终就是启动各类的管道来执行相关的异步操作：
```
	go db.compactionError()
	go db.mpoolDrain()

	if readOnly {
		db.SetReadOnly()
	} else {
		db.closeW.Add(2)
		go db.tCompaction()
		go db.mCompaction()
		// go db.jWriter()
	}
```
## 总结
由此可见，leveldb中，使用了大量的异步逻辑来保证存储的高性能。同时也是利用了AOF原理来提高高可用性。
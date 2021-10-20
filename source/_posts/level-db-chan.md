---
title: 关于LevelDB中的管道
---

在开源项目https://github.com/syndtr/goleveldb中，存在大量的管道通信，而没有使用类似于锁之类的操作，在写法上是一件特别麻烦的事情。不过这也是项目高性能的一大原因。

## 管道汇总

#### 写相关管道

writeMergeC/writeMergedC

这是一对通信方式，当写入时，判断writeMergeC是能够写入，能写入表示抢到了锁操作，并继续往下执行，等待拿到writeMergedC消息，说明自己的写入已经被人合并，并不需要处理。

当然如果当前处理未成功，则会继续往下处理，由另外一个协程进行合并操作。

writeLockC

这个管道和上述的writeMerge是并集操作，当写入成功该管道，则认为抢锁成功，继续往下执行写入操作。当写入完成后，则会释放锁资源。

writeAckC

ack的管道则是表示当前的操作结果，前2者表示的当前处理流程是否成功。

三者使用了管道来完成了一个队列的功能

### 压缩相关管道

tcompCmdC

该管道表示写入一个cCmd，用于触发压缩操作，这个是由于压缩是一个单独的协程来循环处理，所以需要管道通信

tcompPauseC

这个则是为了快速暂停table的压缩流程，通过管道传入一个管道来让压缩流程停止。当然，如果已经开始进行实际的压缩操作，这个流程是无法终止的。

mcompCmdC

这个管道和tcompCmdC同理，也是用于触发压缩操作，只不过，这个操作是用于mem落入table文件时触发。

## 错误相关管道

compErrC\compPerErrC\compErrSetC

这三者构成了一个错误升级的结构，在压缩时，如果出现异常，则会写入compErrSetC，

而如果当前compErrSetC管道堵住，且已经有compPerErrC产生，那直接panic，主要是因为compPerErrC是由于多次的compErrSetC错误导致写入。

当然，如果compErrSetC成功过一次，则会降级等待，否则连续失败，且compErrC一直没人处理，则表示错误无法处理，并需要终止服务。

closeC

这个管道则是在db调用关闭操作时触发，在等待操作中都有监听。

## 总结

可以看出，Golang管道不仅仅是一个通信工具，还能实现各类的加锁操作，包括锁升级。
---
title: Redis通信协议
date: 2021-09-13 22:28:51
tags: 从0开始的Redis
---

## 零、带着问题出发

- 如何表示基本的类型：数字还是字符串
- 数组和对象有该如何表示
- 如何判断请求是否正常
- 数据不存在如何表示
- pipeline中的命令如何发布
- 内联命令是如何支持的
- 发布和订阅在命令中是如何实现的

## 一、简介

redis 客户端和服务端之间通信的协议是RESP（REdis Serialization Protocol）。传输层使用TCP。RESP的特点是：

- 实现容易
- 解析快
- 人类可读

##  二、数据类型 和协议格式

RESP实际上是一个支持以下数据类型的序列化协议：简单字符串（Simple Strings），错误(Errors)，整数(Integers)，批量字符串（Bulk String）和数组（Arrays）。

RESP在Redis中用作请求 - 响应协议的方式如下：

- 客户端将命令作为Bulk Strings的RESP数组发送到Redis服务器。
- 服务器根据命令实现回复一种RESP类型。

在RESP中，某些数据的类型取决于第一个字节：

- 对于简单字符串，回复的第一个字节是“+”
- 对于错误，回复的第一个字节是“ - ”
- 对于整数，回复的第一个字节是“：”
- 对于批量字符串，回复的第一个字节是“$”
- 对于数组，回复的第一个字节是“\*”

在RESP中，协议的不同部分始终以“\ r \ n”（CRLF）结束。

## 三、请求、回复格式

#### 1、简单字符串（Simple Strings）
```
+OK\r\n
```
+ 固定开始，\r\n固定结束， 中间即为回复的内容。

#### 2、错误(Errors)
```
-Error message\r\n
```
类似简单字符串，但是开头用‘-’表示是错误信息。

Error 称为错误类型，“ - ”之后的第一个单词，直到第一个空格或换行符 ,常见的有ERR、WRONGTYPE、NOSCRIPT等。

message 表示错误信息。

以下是一些redis返回的错误：
```
-ERR unknown command 'foobar'
-WRONGTYPE Operation against a key holding the wrong kind of value
-NOSCRIPT No matching script. Please use EVAL.
-READONLY You can't write against a read only slave.
-OOM command not allowed when used memory > 'maxmemory'.
-EXECABORT Transaction discarded because of previous errors.
-BUSYKEY Target key name already exists.
```
#### 3、整数（Integers）
```
:1000\r\n
```
像INCR、LLEN、LASTSAVE等命令返回的都是整数表示增量编号、长度、时间。

像EXISTS或SISMEMBER之类类的命令将返回1表示true，0表示false

返回的整数保证在有符号的64位整数范围内。

#### 4、批量字符串（Bulk strings）
```
$6\r\nfoobar\r\n
```
Bulk Strings用于表示长度最大为512 MB的单个二进制安全字符串。

批量字符串按以下方式编码：

一个“$”字节后跟组成字符串的字节数（一个前缀长度），由CRLF终止。
实际的字符串数据。
最终的CRLF。 
```
$0\r\n\r\n
```
表示空字符串
```
$-1\r\n
```
表示NULL

#### 5、数组（Arrays）

RESP数组使用以下格式发送：

一个*字符作为第一个字节，后跟数组中的元素数作为十进制数，后跟CRLF。
Array的每个元素的附加RESP类型。
```
*0\r\n
```
表示空数组
```
*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n
```
表示"foo"和"bar" 两个批量字符串数组
```
*-1\r\n
```
表示NULL数组
```
*2\r\n
*3\r\n
:1\r\n
:2\r\n
:3\r\n
*2\r\n
+Foo\r\n
-Bar\r\n
```

表示一个由两个元素组成的数组，该数组包含三个整数1,2,3以及一个简单字符串和一个错误的数组。


## 四、内联命令

当你需要和 Redis 服务器进行沟通， 但又找不到 redis-cli ， 而手上只有 telnet 的时候， 你可以通过 Redis 特别为这种情形而设的内联命令格式来发送命令。

以下是一个客户端和服务器使用内联命令来进行交互的例子：

```
客户端： PING
服务器： +PONG
```
以下另一个返回整数值的内联命令的例子：
```
客户端： EXISTS somekey
服务器： :0
```
因为没有了统一请求协议中的 "*" 项来声明参数的数量， 所以在 telnet 会话输入命令的时候， 必须使用空格来分割各个参数， 服务器在接收到数据之后， 会按空格对用户的输入进行分析（parse）， 并获取其中的命令参数。

## 五、多命令和流水线

客户端可以通过流水线， 在一次写入操作中发送多个命令：

- 在发送新命令之前， 无须阅读前一个命令的回复。
- 多个命令的回复会在最后一并返回。

## 六、订阅和发布

SUBSCRIBE、UNSUBSCRIBE  和 PUBLISH三个命令实现了发布与订阅信息泛型（Publish/Subscribe messaging paradigm）， 在这个实现中， 发送者（发送信息的客户端）不是将信息直接发送给特定的接收者（接收信息的客户端）， 而是将信息发送给频道（channel）， 然后由频道将信息转发给所有对这个频道感兴趣的订阅者。

发送者无须知道任何关于订阅者的信息， 而订阅者也无须知道是那个客户端给它发送信息， 它只要关注自己感兴趣的频道即可。

对发布者和订阅者进行解构（decoupling）， 可以极大地提高系统的扩展性（scalability）， 并得到一个更动态的网络拓扑（network topology）。

比如说， 要订阅频道 foo 和 bar ， 客户端可以使用频道名字作为参数来调用 SUBSCRIBE 命令：
```
redis> SUBSCRIBE foo bar
```
当有客户端发送信息到这些频道时， Redis 会将传入的信息推送到所有订阅这些频道的客户端里面。

正在订阅频道的客户端不应该发送除 SUBSCRIBE 和 UNSUBSCRIBE 之外的其他命令。 其中， SUBSCRIBE 可以用于订阅更多频道， 而 UNSUBSCRIBE 则可以用于退订已订阅的一个或多个频道。

SUBSCRIBE 和 UNSUBSCRIBE 的执行结果会以信息的形式返回， 客户端可以通过分析所接收信息的第一个元素， 从而判断所收到的内容是一条真正的信息， 还是 SUBSCRIBE 或 UNSUBSCRIBE 命令的操作结果。

频道转发的每条信息都是一条带有三个元素的多条批量回复（multi-bulk reply）。

信息的第一个元素标识了信息的类型：

- subscribe ： 表示当前客户端成功地订阅了信息第二个元素所指示的频道。 而信息的第三个元素则记录了目前客户端已订阅频道的总数。
- unsubscribe ： 表示当前客户端成功地退订了信息第二个元素所指示的频道。 信息的第三个元素记录了客户端目前仍在订阅的频道数量。 当客户端订阅的频道数量降为 0 时， 客户端不再订阅任何频道， 它可以像往常一样， 执行任何 Redis 命令。
- message ： 表示这条信息是由某个客户端执行 PUBLISH 命令所发送的， 真正的信息。 信息的第二个元素是信息来源的频道， 而第三个元素则是信息的内容。

举个例子， 如果客户端执行以下命令：
```
redis> SUBSCRIBE first second
```
那么它将收到以下回复：
```
1) "subscribe"
2) "first"
3) (integer) 1
 
1) "subscribe"
2) "second"
3) (integer) 2
```
如果在这时， 另一个客户端执行以下 PUBLISH 命令：
```
redis> PUBLISH second Hello
```
那么之前订阅了 second 频道的客户端将收到以下信息：
```
1) "message"
2) "second"
3) "hello"
```
当订阅者决定退订所有频道时， 它可以执行一个无参数的 UNSUBSCRIBE 命令：
```
redis> UNSUBSCRIBE
```
这个命令将接到以下回复：
```
1) "unsubscribe"
2) "second"
3) (integer) 1
 
1) "unsubscribe"
2) "first"
3) (integer) 0
```

## 参考链接
- https://blog.csdn.net/u014608280/article/details/84586042
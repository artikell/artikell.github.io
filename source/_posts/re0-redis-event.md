---
title: Redis事件模型
date: 2021-09-13 23:21:01
tags: 从0开始的Redis
---
## 零、带着问题出发

- 带着问题出发

## 一、关于Reactor

网络编程模型通常有如下几种：Reactor, Proactor, Asynchronous, Completion Token, and Acceptor-Connector. 本文主要对最主流的Reactor模型进行介绍。通常网络编程模型处理的主要流程如下

```
initiate => receive => demultiplex => dispatch => process events
```

I/O多路复用可以用作并发事件驱动(event-driven)程序的基础，即整个事件驱动模型是一个状态机，包含了状态(state), 输入事件(input-event), 状态转移(transition), 状态转移即状态到输入事件的一组映射。通过I/O多路复用的技术检测事件的发生，并根据具体的事件(通常为读写)，进行不同的操作，即状态转移。

Reactor模式是一种典型的事件驱动的编程模型，Reactor逆置了程序处理的流程，其基本的思想即为
> Hollywood Principle — 'Don't call us, we'll call you'.

普通的函数处理机制为：`调用某函数 -> 函数执行， 主程序等待阻塞 -> 函数将结果返回给主程序 -> 主程序继续执行`

Reactor事件处理机制为：主程序将事件以及对应事件处理的方法在Reactor上进行注册, 如果相应的事件发生，Reactor将会主动调用事件注册的接口，即 回调函数. libevent即为封装了epoll并注册相应的事件(I/O读写，时间事件，信号事件)以及回调函数，实现的事件驱动的框架。

redis是一个事件驱动的服务程序，在redis的服务程序中存在两种类型的事件，分别是文件事件和时间事件。文件事件是对网络通信操作的统称，时间事件是redis中定时运行的任务或者是周期性的任务（目前redis中只有serverCron这一个周期性时间事件，并没有定时时间事件）。对于事件驱动类的程序，非常适合使用Reactor模式进行设计。redis也不例外，在文件事件处理的设计中采用了Reactor设计模式。

Reactor模式包含四部分，分别是

- Handle(对于系统资源的一种抽象，在redis中就是监听描述符或者是连接描述符）
- Synchronous Event Demultiplexer(同步事件分离器，在redis中对应于IO多路复用程序）
- Event Handler(事件处理器，在redis中对应于连接应答处理器、命令请求处理器以及命令回复处理器、事件处理器等）
- Initiation Dispatcher(事件分派器，在redis中对应于ae.c/aeProcessEvents函数）

## 二、redis事件模型概览

对应的流程如下：

- 在redis中将感兴趣的事件及类型(读、写）通过IO多路复用程序注册到内核中并监听每个事件是否发生。
- 当IO多路复用程序返回的时候，如果有事件发生，redis在封装IO多路复用程序时，将所有已经发生的事件及该事件的类型封装为aeFiredEvent类型，放到aeEventLoop的fired成员中，形成一个队列。
- 通过这个队列，redis以有序、同步、每次一个套接字事件的方式向文件事件分派器传送套接字，并处理发生的文件事件。
- redis处理事件（无论是文件事件还是时间事件）都是以原子的方式进行的，中间不存在事件之间的抢占。这很容易理解，redis是单线程模型，不存在处理上的并发操作。

最后需要说明的是redis首先处理发生的文件事件，然后才会处理时间事件，这点我们在介绍redis源码aeProcessEvents的时候会详细注释和介绍。

redis表示事件模型的数据结构是对该事件标识、事件类型和事件处理函数的一种抽象，就是Reactor模式中的`Handle和Event Handle`的集合。redis使用了四种数据结构描述redis中的事件，前三种数据结构是对redis中某种特定类型事件的一种抽象，最后一种数据结构aeEventLoop是redis管理所有事件的一种抽象。


## 三、redis事件模型数据结构


aeTimeEvent中的id成员、aeFiredEvent中的fd成员都是Reactor模式中所说的Handle的具体表现，但是好像aeFileEvents并没有对应的handle。其实，redis在aeEventLoop的events成员中使用每一个描述符fd作为下标，该下标的对应值为aeFileEvent成员，由此将描述符fd与对该fd感兴趣的事件类型以及处理函数相关联，对应于Reactor中Handle与Event Handler的关联。当通过aeEventLoop中的fired获取到已经发生的事件fd及其类型mask的时候，由fd和mask在aeEventLoop的events成员中获取对应的事件处理器，处理已经发生的事件。也就是说，文件事件的处理是联合使用了fired和events两个成员变量；时间事件的处理使用aeTimeEvent变量。

#### 文件事件数据结构。
```
/* 文件事件 */
  typedef struct aeFileEvent {
      /* 套接字发生的事件，读事件或者写事件其中的一种 */
      int mask; /* one of AE_(READABLE|WRITABLE) */
      /* 读事件处理器，回调函数 */
      aeFileProc *rfileProc;
      /* 写事件处理器，回调函数 */
      aeFileProc *wfileProc;
      /* 客户端数据 */
      void *clientData;
  } aeFileEvent;
```
#### 时间事件数据结构。
```
  typedef struct aeTimeEvent {
      /* 时间事件，每个时间事件通过id唯一标识 */
      long long id;
      /* 时间事件应该触发的时间，单位:s */
      long when_sec;
      /* 时间事件被触发的时间,单位:ms */
      long when_ms;
      /* 时间事件处理函数 */
      aeTimeProc *timeProc;
      aeEventFinalizerProc *finalizerProc;
      /* 客户端数据 */
      void *clientData;
      /* 时间事件形成的链条 */
      struct aeTimeEvent *next;
  } aeTimeEvent;
```
#### 已经发生的文件事件数据结构。
```
  /* 已经发生的文件事件 */
  typedef struct aeFiredEvent {
      int fd;
      int mask;
  } aeFiredEvent;
```
#### redis中时间管理结构体，包含了文件事件、时间事件、已发生的文件事件等相关信息。
```
  /* redis中的事件管理结构体 */
  typedef struct aeEventLoop {
      /* 当前IO程序追踪的最大的文件描述符，大于此值的setsize范围内的值，没有意义*/
      int maxfd;
      /* 当前感兴趣集合的大小, setsize > maxfd */
      int setsize;
      /* 下一个时间事件的id */
      long long timeEventNextId;
      /* 用于修正系统时钟的偏移，具体参考aeProcessTimeEvents */
      time_t lastTime;
      /* 注册的感兴趣的文件事件 */
      aeFileEvent *events; 
      /* 被触发的文件事件指针，也就是上文所说的已经发生的文件事件形成的队列 */
      aeFiredEvent *fired;
      /* 时间事件形成的链表(无序链表) */
      aeTimeEvent *timeEventHead;
      /* 事件停止标志 */
      int stop;
      /* 针对特定API需要的数据结构, 通过该数据结构屏蔽掉IO多路复用
       * 不同底层实现的需要的不同数据结构
       */
      void *apidata;
      aeBeforeSleepProc *beforesleep;
      aeBeforeSleepProc *aftersleep;
  } aeEventLoop;
```
## 三、redis中的IO多路复用机制

redis中的IO多路复用机制对应于Reactor模式中的同步事件分离器。redis考虑到不同系统可能支持不同的的IO多路复用机制，因此实现了select、epoll、kqueue和evport四种不同的IO多路复用，并且每种IO多路复用机制都提供了完全相同的外部接口，根据ae.c中的条件编译语句选择的顺序依次是evport、epoll、kequeue和select，隔离了系统对IO多路复用机制支持的差异。

## redis的事件分派器

在redis中，ae.c文件提供的对外API屏蔽掉了操作系统底层实现的不同，将对文件事件和时间事件的处理通过统一的接口操作。下面我们详细说明一下redis中作为事件分派器的aeProcessEvents函数和时间事件处理函数processTimeEvents。

redis在aeProcessEvents函数中处理文件事件和时间事件，且先处理文件事件再处理时间事件。flags指定redis是处理时间事件还是文件事件又或者是两种事件的并集，这点很容易理解，我们只是想说明一下flags中的另一个标志位---就是获取就绪文件事件的时候是否阻塞的标志位，AE_DONT_WAIT标志。

按照Reactor设计模式，在文件事件分派器上调用同步事件分离器，获取已经就绪的文件事件。调用同步事件分离器就是要调用IO多路复用函数，而IO多路复用函数有可能阻塞（依据传入的时间参数，决定不阻塞、永久阻塞还是阻塞特定的时间段）。

为了防止redis线程长时间阻塞在文件事件等待就绪上而耽误了及时处理到时的时间事件，并且防止redis过多重复性的遍历时间事件形成的无序链表，redis在aeProcessEvents的实现中通过设置flags中的AE_DONT_WAIT标志位达到以上目的。具体参考aeProcessEvents中的注释。

```
  int aeProcessEvents(aeEventLoop *eventLoop, int flags)
  {
      int processed = 0, numevents;
  
      /* 所有的事件都不进行处理 */
      if (!(flags & AE_TIME_EVENTS) && !(flags & AE_FILE_EVENTS)) return 0;
  
      /* 首先判断是否存在需要监听的文件事件，如果存在需要监听的文件事件，那么通过IO多路复用程序获取
       * 准备就绪的文件事件，至于IO多路复用程序是否等待以及等待多久的时间，依发生时间距离现在最近的时间事件确定;
       * 如果eventLoop->maxfd == -1表示没有需要监听的文件事件，但是时间事件肯定是存在的(serverCron())，
       * 如果此时没有设置AE_DONT_WAIT标志位，此时调用IO多路复用，其目的就不是为了监听文件事件准备就绪了，
       * 而是为了使线程休眠到发生时间距离现在最近的时间事件的发生时间(作用类似于unix中的sleep函数),
       * 这种休眠操作的目的是为了避免线程一直不停的遍历时间事件形成的无序链表，造成不必要的资源浪费
       */
      if (eventLoop->maxfd != -1 ||
          ((flags & AE_TIME_EVENTS) && !(flags & AE_DONT_WAIT))) {
          int j;
          aeTimeEvent *shortest = NULL;
          struct timeval tv, *tvp;
  
          /* 寻找发生时间距离现在最近的时间事件,该时间事件的发生时间与当前时间之差就是IO多路复用程序应该等待的时间 */
          if (flags & AE_TIME_EVENTS && !(flags & AE_DONT_WAIT))
              shortest = aeSearchNearestTimer(eventLoop);
          if (shortest) {
              long now_sec, now_ms;
  
              aeGetTime(&now_sec, &now_ms);
              tvp = &tv;
  
              long long ms =
                  (shortest->when_sec - now_sec)*1000 +
                  shortest->when_ms - now_ms;
  
              /* 如果时间之差大于0，说明时间事件到时时间未到,则等待对应的时间;
               * 如果时间间隔小于0，说明时间事件已经到时，此时如果没有
               * 文件事件准备就绪，那么IO多路复用程序应该立即返回，以免
               * 耽误处理时间事件
               */
              if (ms > 0) {
                  tvp->tv_sec = ms/1000;
                  tvp->tv_usec = (ms % 1000)*1000;
              } else {
                  tvp->tv_sec = 0;
                  tvp->tv_usec = 0;
              }   
          } else {
              /* 没有找到距离现在最近的时间事件，且设置了AE_DONT_WAIT标志位，
               * 立即从IO多路复用程序返回
               */
              if (flags & AE_DONT_WAIT) {
                  tv.tv_sec = tv.tv_usec = 0;
                  tvp = &tv;
              } else {
                  /* 没有设置AE_DONT_WAIT标志位，且没有找到发生时间距离现在最近的时间事件，
                   * IO多路复用程序可以无限等待
                   */
                  tvp = NULL;
              }
          }
  
          /* 典型的reator设计模式。作为事件分派器，
           * 将已经发生的文件事件交给对应的eventHandle处理
           */
          numevents = aeApiPoll(eventLoop, tvp);
  
          /* After sleep callback. */
          if (eventLoop->aftersleep != NULL && flags & AE_CALL_AFTER_SLEEP)
              eventLoop->aftersleep(eventLoop);
  
          for (j = 0; j < numevents; j++) {
              aeFileEvent *fe = &eventLoop->events[eventLoop->fired[j].fd];
              /* 按照队列的顺序处理就绪的文件事件 */
              int mask = eventLoop->fired[j].mask;
              int fd = eventLoop->fired[j].fd;
              int rfired = 0;
  
              /* 如果IO多路复用程序同时监听fd的读事件和写事件，
               * 则当该fd对应的读、写事件都返回可用的时候，
               * 服务器首先处理读套接字、后处理写套接字
               */
              if (fe->mask & mask & AE_READABLE) {
                  rfired = 1;
                  fe->rfileProc(eventLoop,fd,fe->clientData,mask);
              }
              if (fe->mask & mask & AE_WRITABLE) {
                  if (!rfired || fe->wfileProc != fe->rfileProc)
                      fe->wfileProc(eventLoop,fd,fe->clientData,mask);
              }
              processed++;
          }
      }
      /* 处理时间事件 */
      if (flags & AE_TIME_EVENTS)
          processed += processTimeEvents(eventLoop);
  
      return processed; /* return the number of processed file/time events */
  }    
```

在redis中将对文件事件的处理直接放到了aeProcessEvents中，但是对于时间事件的处理却是存在单独的函数，aeProcessTimeEvents。                

```
  static int processTimeEvents(aeEventLoop *eventLoop) {
      int processed = 0;
      aeTimeEvent *te, *prev;
      long long maxId;
      time_t now = time(NULL);
  
      /* 系统的始终如果发生了漂移，那么所有的时间事件应该立即被处理;
       * 将te->when_sec设置为0，表示所有的时间事件都能够被处理。如果时间事件没有到时，
       * 那么当前立即处理也不存在什么问题;如果时间事件确实已经到时，那确实应该被处理
       */
      if (now < eventLoop->lastTime) {
          te = eventLoop->timeEventHead;
          while(te) {
              te->when_sec = 0;
              te = te->next;
          }
      }
      /* 纠正系统时钟 */
      eventLoop->lastTime = now;
  
      prev = NULL;
      te = eventLoop->timeEventHead;
      maxId = eventLoop->timeEventNextId-1;
      while(te) {
          long now_sec, now_ms;
          long long id;
  
          /* 在aeDeleteTimeEvent函数中删除掉时间事件只是将时间事件的id置为无效的id值，
           * 真正的内存释放工作在这里进行
           */
          if (te->id == AE_DELETED_EVENT_ID) {
              aeTimeEvent *next = te->next;
              if (prev == NULL)
                  eventLoop->timeEventHead = te->next;
              else
                  prev->next = te->next;
              if (te->finalizerProc)
                  te->finalizerProc(eventLoop, te->clientData);
              /* 释放时间事件 */
              zfree(te);
              te = next;
              continue;
          }
  
          /* Make sure we don't process time events created by time events in
           * this iteration. Note that this check is currently useless: we always
           * add new timers on the head, however if we change the implementation
           * detail, this check may be useful again: we keep it here for future
           * defense. */
          if (te->id > maxId) {
              te = te->next;
              continue;
          }
          aeGetTime(&now_sec, &now_ms);
          if (now_sec > te->when_sec ||
              (now_sec == te->when_sec && now_ms >= te->when_ms))
          {
              int retval;
  
              id = te->id;
              retval = te->timeProc(eventLoop, id, te->clientData);
              processed++;
              /* 要求timeProc返回该时间事件是否需要继续，如果不需要再继续那么返回AE_NOMOER;
               * 如果是周期性的事件，那么需要需要继续，则返回下一次发生的时间距离现在的毫秒数。
               * 如果是定时事件，则该事件不需要再次执行，返回AE_NOMORE
               */
              /* 周期性时间，在处理完这次事件之后，重新设定下一次该事件应该执行的时间，以便周期性进行调度 */
              if (retval != AE_NOMORE) {
                  aeAddMillisecondsToNow(retval,&te->when_sec,&te->when_ms);
              } else {
                  /* 重新留下了无效的时间事件id，等待下一次调用处理时间事件的函数的时候，删除掉该事件 */
                  te->id = AE_DELETED_EVENT_ID;
              }
          }
          prev = te;
          te = te->next;
      }
      return processed;
  }
```

redis所有的事件都是在aeProcessEvents中处理的，aeProcessEvents被aeMain调用。

```
  void aeMain(aeEventLoop *eventLoop) {
      eventLoop->stop = 0;
      /* 在整个循环中不断地处理时间事件和文件事件，构成了redis运行的主体 */
      while (!eventLoop->stop) {
          if (eventLoop->beforesleep != NULL)
              eventLoop->beforesleep(eventLoop);
          aeProcessEvents(eventLoop, AE_ALL_EVENTS|AE_CALL_AFTER_SLEEP);
      }
  }
```
        

## 相关链接
- https://blog.csdn.net/GDJ0001/article/details/80268836
- https://zhuanlan.zhihu.com/p/93612337
---
title: netflix-concurrency-limits
date: 2022-04-28 23:44:05
tags:
---

# Overview

Java Library that implements and integrates concepts from TCP congestion control to auto-detect concurrency limits for services in order to achieve optimal throughput with optimal latency.
Java库，它实现并集成了TCP拥塞控制、自动检测服务并发限制等概念，以实现最佳吞吐量和最佳延迟。

# Background

When thinking of service availability operators traditionally think in terms of RPS (requests per second). Stress tests are normally performed to determine the RPS at which point the service tips over. RPS limits are then set somewhere below this tipping point (say 75% of this value) and enforced via a token bucket. However, in large distributed systems that auto-scale this value quickly goes out of date and the service falls over by becoming non-responsive as it is unable to gracefully shed excess load. Instead of thinking in terms of RPS, we should be thinking in terms of concurrent request where we apply queuing theory to determine the number of concurrent requests a service can handle before a queue starts to build up, latencies increase and the service eventually exhausts a hard limit such as CPU, memory, disk or network. This relationship is covered very nicely with Little's Law where `Limit = Average RPS * Average Latency`.

在考虑服务可用性时，运营商通常会考虑RPS（每秒请求数）。压力测试通常是为了确定服务结束时的RPS。然后将RPS限制设置在该临界点以下的某个位置（比如该值的75%），并通过令牌桶强制执行。然而，在自动扩展的大型分布式系统中，这个值很快就过时了，服务变得不响应，因为它无法正常地释放多余的负载。我们不应该从RPS的角度来考虑，而应该从并发请求的角度来考虑，在队列开始建立、延迟增加以及服务最终耗尽CPU、内存、磁盘或网络等硬限制之前，我们应用排队论来确定服务可以处理的并发请求数。利特尔定律很好地描述了这种关系，其中“极限=平均RPS*平均延迟”。

Concurrency limits are very easy to enforce but difficult to determine as they would require operators to fully understand the hardware services run on and coordinate how they scale. Instead we'd prefer to measure or estimate the concurrency limits at each point in the network.  As systems scale and hit limits each node will adjust and enforce its local view of the limit. To estimate the limit we borrow from common TCP congestion control algorithms by equating a system's concurrency limit to a TCP congestion window.

并发限制很容易实施，但很难确定，因为它们要求运营商充分了解硬件服务的运行情况，并协调它们的扩展方式。相反，我们更愿意测量或估计网络中每个点的并发限制。随着系统的扩展和命中极限，每个节点都将调整并强制执行其极限的局部视图。为了估计限制，我们借用了常用的TCP拥塞控制算法，将系统的并发限制等同于TCP拥塞窗口。

Before applying the algorithm we need to set some ground rules.
在应用算法之前，我们需要设定一些基本规则。
* We accept that every system has an inherent concurrency limit that is determined by a hard resources, such as number of CPU cores.
*我们承认每个系统都有一个固有的并发限制，这是由硬资源决定的，比如CPU核的数量。
* We accept that this limit can change as a system auto-scales.
*我们承认，随着系统自动缩放，该限制可能会发生变化。
* For large and complex distributed systems it's impossible to know all the hard resources.
*对于大型复杂的分布式系统，不可能知道所有的硬资源。
* We can use latency measurements to determine when queuing happens.
*我们可以使用延迟测量来确定何时发生排队。
* We can use timeouts and rejected requests to aggressively back off.
*我们可以利用超时和被拒绝的请求来积极回退。

# Limit algorithms

## Vegas

Delay based algorithm where the bottleneck queue is estimated as
基于延迟的算法，其中瓶颈队列估计为

    L * (1 - minRTT/sampleRtt)
    
At the end of each sampling window the limit is increased by 1 if the queue is less than alpha (typically a value between 2-3) or decreased by 1 if the queue is greater than beta (typically a value between 4-6 requests)
在每个采样窗口结束时，如果队列小于alpha（通常为2-3之间的值），则限制增加1；如果队列大于beta（通常为4-6个请求之间的值），则限制减少1

## Gradient2

This algorithm attempts to address bias and drift when using minimum latency measurements. To do this the algorithm tracks uses the measure of divergence between two exponential averages over a long and short time time window. Using averages the algorithm can smooth out the impact of outliers for bursty traffic. Divergence duration is used as a proxy to identify a queueing trend at which point the algorithm aggresively reduces the limit.
该算法试图解决使用最小延迟测量时的偏差和漂移问题。为了做到这一点，算法跟踪使用了长时间和短时间窗口内两个指数平均值之间的差异度量。使用平均值，该算法可以消除异常值对突发流量的影响。发散持续时间被用作一个代理来识别排队趋势，在这一点上，算法积极地降低了限制。

# Enforcement Strategies

## Simple

In the simplest use case we don't want to differentiate between requests and so enforce a single gauge of the number of inflight requests.  Requests are rejected immediately once the gauge value equals the limit.
在最简单的用例中，我们不想区分不同的请求，因此只需对机上请求的数量进行一次测量。一旦仪表值等于极限值，请求将立即被拒绝。

## Percentage

For more complex systems it's desirable to provide certain quality of service guarantees while still making efficient use of resources.  Here we guarantee specific types of requests get a certain percentage of the concurrency limit.  For example, a system that takes both live and batch traffic may want to give live traffic 100% of the limit during heavy load and is OK with starving batch traffic. Or, a system may want to guarantee that 50% of the limit is given to write traffic so writes are never starved.
对于更复杂的系统，在有效利用资源的同时，最好提供一定的服务质量保证。在这里，我们保证特定类型的请求获得一定百分比的并发限制。例如，一个同时接受实时流量和批处理流量的系统可能希望在重负载期间为实时流量提供100%的限制，并且可以处理饥饿的批处理流量。或者，系统可能希望保证50%的限制用于写入流量，这样就永远不会缺少写入。
# Integrations

## GRPC

A concurrency limiter may be installed either on the server or client. The choice of limiter depends on your use case. For the most part it is recommended to use a dynamic delay based limiter such as the VegasLimit on the server and either a pure loss based (AIMDLimit) or combined loss and delay based limiter on the client.
并发限制器可以安装在服务器或客户端上。限制器的选择取决于您的用例。在大多数情况下，建议在服务器上使用基于动态延迟的限制器，如VegasLimit，在客户端使用基于纯损耗的限制器（AIMDLimit）或基于损耗和延迟的组合限制器。
### Server limiter

The purpose of the server limiter is to protect the server from either increased client traffic (batch apps or retry storms) or latency spikes from a dependent service.  With the limiter installed the server can ensure that latencies remain low by rejecting excess traffic with `Status.UNAVAILABLE` errors.
服务器限制器的目的是保护服务器不受客户端流量增加（批处理应用或重试风暴）或从属服务延迟峰值的影响。安装了限制器后，服务器可以通过拒绝带有`状态的多余流量来确保延迟保持较低。不可用的错误。

In this example a GRPC server is configured with a single adaptive limiter that is shared among batch and live traffic with live traffic guaranteed 90% of throughput and 10% guaranteed to batch.  For simplicity we just expect the client to send a "group" header identifying it as 'live' or 'batch'.  Ideally this should be done using TLS certificates and a server side lookup of identity to grouping.  Any requests not identified as either live or batch may only use excess capacity.
在本例中，GRPC服务器配置了一个自适应限制器，该限制器在批处理和实时流量之间共享，实时流量保证90%的吞吐量，并保证10%的批处理。为了简单起见，我们只希望客户端发送一个“组”头，将其标识为“活动”或“批处理”。理想情况下，这应该使用TLS证书和服务器端的身份查找来完成。任何未确定为实时或批处理的请求只能使用多余的容量。

```java
// Create and configure a server builder
ServerBuilder builder = ...;

builder.addService(ServerInterceptor.intercept(service,
    ConcurrencyLimitServerInterceptor.newBuilder(
        new GrpcServerLimiterBuilder()
            .partitionByHeader(GROUP_HEADER)
            .partition("live", 0.9)
            .partition("batch", 0.1)
            .limit(WindowedLimit.newBuilder()
                    .build(Gradient2Limit.newBuilder()
                            .build()))
            .build();

    ));
```

### Client limiter

There are two main use cases for client side limiters. A client side limiter can protect the client service from its dependent services by failing fast and serving a degraded experience to its client instead of having its latency go up and its resources eventually exhausted. For batch applications that call other services a client side limiter acts as a backpressure mechanism ensuring that the batch application does not put unnecessary load on dependent services.
客户端限制器有两个主要用例。客户端限制器可以保护客户端服务不受其依赖服务的影响，方法是快速故障并向其客户端提供降级的体验，而不是让其延迟增加，最终耗尽其资源。对于调用其他服务的批处理应用程序，客户端限制器充当背压机制，确保批处理应用程序不会对依赖的服务施加不必要的负载。

In this example a GRPC client will use a blocking version of the VegasLimit to block the caller when the limit has been reached.
在本例中，GRPC客户端将使用VegasLimit的阻塞版本在达到限制时阻塞调用者。

```java
// Create and configure a channel builder
ChannelBuilder builder = ...;

// Add the concurrency limit interceptor
builder.intercept(
    new ConcurrencyLimitClientInterceptor(
        new GrpcClientLimiterBuilder()
            .blockOnLimit(true)
            .build()
        )
    );
```

## Servlet Filter

The purpose of the servlet filter limiter is to protect the servlet from either increased client traffic (batch apps or retry storms) or latency spikes from a dependent service.  With the limiter installed the server can ensure that latencies remain low by rejecting excess traffic with HTTP 429 Too Many Requests errors.
servlet筛选器限制器的目的是保护servlet不受客户端流量增加（批处理应用程序或重试风暴）或依赖服务延迟峰值的影响。安装了限制器后，服务器可以通过拒绝HTTP 429过多请求错误的多余流量来确保延迟保持较低。

In this example a servlet is configured with a single adaptive limiter that is shared among batch and live traffic with live traffic guaranteed 90% of throughput and 10% guaranteed to batch.  The limiter is given a lookup function that translates the request's Principal to one of the two groups (live vs batch).
在本例中，servlet配置了一个自适应限制器，该限制器在批处理和实时流量之间共享，实时流量保证90%的吞吐量，10%保证批处理。限制器有一个查找函数，可以将请求的主体转换为两个组中的一个（live vs batch）。

```java
Map<String, String> principalToGroup = ...;
Filter filter = new ConcurrencyLimitServletFilter(new ServletLimiterBuilder()
    .partitionByUserPrincipal(principal -> principalToGroup.get(principal.getName())
    .partition("live", 0.9)
    .partition("batch", 0.1))
    .build());
```

## Executor

The BlockingAdaptiveExecutor adapts the size of an internal thread pool to match the concurrency limit based on measured latencies of Runnable commands and will block when the limit has been reached.
BlockingAdaptiveExecutor根据可运行命令的测量延迟调整内部线程池的大小以匹配并发限制，并在达到限制时进行阻塞。
 
```java
public void drainQueue(Queue<Runnable> tasks) {
    Executor executor = new BlockingAdaptiveExecutor(
        SimpleLimiter.newBuilder()
            .build());
    
    while (true) {
        executor.execute(tasks.take());
    }
}

```

## Reference

- [自适应限流 netflix-concurrency-limits | 人淡如菊](https://www.panaihua.com/concurrency-limits/)
- [#68 网络知识十全大补丸 【 Go 夜读 】_哔哩哔哩_bilibili](https://www.bilibili.com/video/BV1vJ41127p2)
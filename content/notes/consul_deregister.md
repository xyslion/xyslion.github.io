---
title: "consul服务下线的巨坑"
date: 2019-07-27T21:03:26+08:00
catagories: ["registry"]
tags: ["consul"]
---

## consul服务下线的巨坑

当在开发环境时, 只部署一个consul, 既当妈又当爸(既当server又当agent)时, 

```shell
$ curl consul.address:8500/v1/agent/service/deregister/:service_id
```

使用如上api可以很方便的将服务从consul上下线, 如果问题就这么解决了, 
那就不叫巨坑了, 在生产环境时, 按照官方推荐, 要3个server, 
agent client端按照集群容量自行定义, 通过client进行注册, 如果是部署在k8s里,
agent client端推荐使用DaemonSet方式部署, 既一个k8s节点一个agent client, 
如此的问题就来了, 因为agent client是多台, 所以需要dns等对client进行负载, 
保证高可用, 避免单点, 这时`consul.address`为域名, 再使用上面的api去下线服务
发现结果虽然返回成功, 但是服务其实并没有下线.

就此展开调查, 发现网上很多人也遇到了此问题, 有的使用`/v1/catalog/deregister`,
有的先使用`/v1/health/service/:service`先取得该服务的所有后端ip再比对`service_id`
进行删除, 试了两种方法都不行, 在一次偶然的机会, 发现可以用consul自带的`command`进行
相应的操作, 一开始以为是api有问题, 因此随便进入了一台client使用一下命令进行删除

```shell
/ # consul services deregister -id="echo-1"
Deregistered service: echo-1
```

虽然提示成功, 但是通过ui来看, 并没有删除成功, 在看ui时,发现上面有注册的节点信息,
进入该节点, 继续使用以上命令执行下线操作, 同样提示下线成功了, 并且ui上该服务也真实
下线了, 因此consul的服务下线是要在哪个节点上注册, 就要在哪个节点上反注册才能下线成功

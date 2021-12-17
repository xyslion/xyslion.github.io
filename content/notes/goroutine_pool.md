---
title: "Golang里定义goroutine池控制最大goroutine数量"
date: 2019-10-11T10:17:58+08:00
categories: ["golang"]
tags: ["golang", "gorutine"]
---

在golang里时常使用goroutine来进行异步任务， 但是goroutine虽然使用的资源比线程少多了，单个goroutine大约消耗4KB的内存。  
因此goroutine最好不要毫无节制的开启使用， 可以使用goroutine池来限制开启的最大数量。

以下是几种实现goroutine池的骚操作。

```go
package gpool1

import (
    "fmt"
)

type task func()

type workPool struct {
    tasks chan task
    lock chan struct{}   
}

func initPool(num int) *workPool {
    wp := &workPool{
        tasks: make(chan task, num),
        lock: make(chan struct{}, num)
    }
    return wp   
}

func (wp *workPool) start() {
    for f := range wp.tasks {
        go func() {
            defer func() {
                // 解锁操作
                <- wp.lock
            }()
            // 真正执行部分
            f()
        }()
    }    
}

func (wp *workPool) submit(t task) error {
    select {
        case wp.lock <- struct{}{}:
        default :
            return fmt.Errorf("workPool is busy.")
    }

    wp.tasks <- t
    return nil
}

func (wp *workPool) close() {
    close(wp.tasks)
    close(wp.lock)
}

```

以上的实现， 虽然可以限制goroutine的数量([0, maxtasknum])， 但是goroutine会不停的创建销毁，在任务满的情况下会阻塞任务的提交。

那就来一个goroutine不变版

```go
package gpool2

import (
    "sync"
)

type task func() 

type workPool struct {
    tasks chan task
    wg sync.WaitGroup
    closed bool
    co sync.Once
}

func initPool(num int) *workPool {
    wp := &workPool {
        tasks: make(chan task),
        wg: sync.WaitGroup{},
        closed: false,
        co: sync.Once{},
    }
    go wp.start()
    return wp
}

func (wp *workPool) start(num int) {
    for i := 0; i < num; i++ {
        wp.wg.Add(1)
        go func() {
            defer wp.wg.Done()

            for f := range wp.tasks {
                f()
            }
        }()
    }
    wp.wg.Wait()
}

func (wp *workPool) submit(t task) error {
    if wp.closed {
        return fmt.Errorf("workPool is closed")        
    }
    wp.tasks <- t
}

func (wp *workPool) close() {
    wp.co.Do(func(){
        wp.closed = true
    })
    close(wp.tasks)
}
```

如上实现，则从程序开始到结束都保持在num个goroutine。
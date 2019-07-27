---
layout: post
title: "Implement semaphore with mutex"
---

According to [POSIX's definition of semaphores][semaphore]:

> A semaphore is an integer whose value is never allowed to fall below
zero.  Two operations can be performed on semaphores: increment the
semaphore value by one (sem_post(3)); and decrement the semaphore
value by one (sem_wait(3)).  If the value of a semaphore is currently
zero, then a sem_wait(3) operation will block until the value becomes
greater than zero.

A mutex has two main differences than semaphore. First it's binary, meaning
either 1 or 0 threads can hold the mutex. Second, mutex's `unlock()` operation
doesn't accumulate like semaphore's `post()` operation does. To elaborate,
consider the following code:

```cpp
#include <mutex>
#include <stdio.h>
#include <semaphore.h>

#define LOG(tag, block) \
    printf(tag": start\n"); block; printf(tag": done\n")

int main() {
    sem_t sem;
    sem_init(&sem, 0, 0);

    LOG("post 1", sem_post(&sem));
    LOG("post 2", sem_post(&sem));

    LOG("wait 1", sem_wait(&sem));
    LOG("wait 2", sem_wait(&sem));

    printf("semaphore's post() can accumulate\n");
    printf("but mutex's unlock() can't\n");
    printf("press ctrl-c to exit\n");

    std::mutex m;

    LOG("unlock 1", m.unlock());
    LOG("unlock 2", m.unlock());

    LOG("lock 1", m.lock());
    LOG("lock 2", m.lock());

    printf("this will never print\n");

    return 0;
}

/* Output:
post 1: start
post 1: done
post 2: start
post 2: done
wait 1: start
wait 1: done
wait 2: start
wait 2: done
semaphore's post() can accumulate
but mutex's unlock() can't
press ctrl-c to exit
unlock 1: start
unlock 1: done
unlock 2: start
unlock 2: done
lock 1: start
lock 1: done
lock 2: start
*/
```

As we can see two `post()` operations on the semaphore can allow two `wait()`
operations to follow; while two `unlock()` operations on the mutex doesn't
enable us to call `lock()` twice.

Note that both `wait()` and `lock()` operations are accumulative, means that if
the resource is busy, pending waiting threads will be released in FIFO order
one at a time by each `post()` and `unlock()` operation respectively.

We want to explore different approach to implement semaphore with mutex. We will
investigate Anthony Howe's solutions in [his note][gensem]. The first solution
is incorrect on purpose, we will explain why it might fail, and how the other
correct solutions address the issue.

## Solution #1 (Incorrect)

```cpp
#include <mutex>
#include <thread>
#include <stdio.h>

class Semaphore
{
public:
    Semaphore(int c) : c(c)
    {
        d.lock();
    }

    void wait()
    {
        m.lock();
        c--;
        if (c < 0)
        {
            m.unlock();
            d.lock();
        }
        else
        {
            m.unlock();
        }
    }

    void post()
    {
        m.lock();
        c++;
        if (c <= 0)
        {
            d.unlock();
        }
        m.unlock();
    }

private:
    int c;
    std::mutex m;
    std::mutex d;
};

Semaphore sem(0);

void foo(const char *name)
{
    sem.wait();
    printf("%s: done\n", name);
}

int main()
{
    std::thread t1(foo, "thread 1");
    std::thread t2(foo, "thread 2");
    sem.post();
    sem.post();
    t1.join();
    t2.join();
    printf("main: done\n");
    return 0;
}
```

This solution seems intuitive. If you look closely, you will see that mutex `m`
protects access to `c`, and there's no race condition at all. `d` mutex acts as
a signaling mechanism that wakes up the waiting threads in FIFO order one at a
time at each `d.unlock()` operation.

However, if you compile and run this program for some times, you may end up with
a situation that one thread is finished and the other hang forever. Which means
we have a deadlock somewhere.

```
 +============+ +============+ +============+ +=======+ +========+ +========+
 |     t1     | |     t2     | |    main    | |   c   | |   m    | |   d    |
 +============+ +============+ +============+ +=======+ +========+ +========+
 |            | |            | | c = 0      | |   0   | |        | |        |
 |            | |            | | d.lock()   | |   0   | |        | |  main  |
 |            | |            | |            | |   0   | |        | |  main  |
 |    vvv============================^^^    | |   0   | |        | |  main  |
 |            | |            | |            | |   0   | |        | |  main  |
 | m.lock()   | |            | |            | |   0   | |   t1   | |  main  |
 | c--        | |            | |            | |  -1   | |   t1   | |  main  |
 | m.unlock() | |            | |            | |  -1   | |        | |  main  |
 |            | |            | |            | |  -1   | |        | |  main  |
 |    ^^^=============vvv    | |            | |  -1   | |        | |  main  |
 |            | |            | |            | |  -1   | |        | |  main  |
 |            | | m.lock()   | |            | |  -1   | |   t2   | |  main  |
 |            | | c--        | |            | |  -2   | |   t2   | |  main  |
 |            | | m.unlock() | |            | |  -2   | |        | |  main  |
 |            | |            | |            | |  -2   | |        | |  main  |
 |            | |    ^^^=============vvv    | |  -2   | |        | |  main  |
 |            | |            | |            | |  -2   | |        | |  main  |
 |            | |            | | m.lock()   | |  -2   | |  main  | |  main  |
 |            | |            | | c++        | |  -1   | |  main  | |  main  |
 |            | |            | | d.unlock() | |  -1   | |  main  | |        |
 |            | |            | | m.unlock() | |  -1   | |        | |        |
 |            | |            | |            | |  -1   | |        | |        |
 |            | |            | |            | |  -1   | |        | |        |
 |            | |            | | m.lock()   | |  -1   | |  main  | |        |
 |            | |            | | c++        | |   0   | |  main  | |        |
 |            | |            | | d.unlock() | |   0   | |  main  | |        |
 |            | |            | | m.unlock() | |   0   | |        | |        |
 |            | |            | |            | |   0   | |        | |        |
 |            | |    vvv=============^^^    | |   0   | |        | |        |
 |            | |            | |            | |   0   | |        | |        |
 |            | | d.lock()   | |            | |   0   | |        | |   t2   |
 |            | |            | |            | |   0   | |        | |   t2   |
 |    vvv=============^^^    | |            | |   0   | |        | |   t2   |
 |            | |            | |            | |   0   | |        | |   t2   |
 | d.lock()   | |            | |            | |   0   | |        | | t1, t2 |
 +------------+ +------------+ +------------+ +-------+ +--------+ +--------+
```

From the above diagram we can see that we may unlock `d` twice and then lock `d`
twice in a row, where the last lock operation would result in a deadlock.

This is essentially because mutex doesn't accumulate its unlock operations.
Thus, we have to make sure a mutex is in locked state before we unlock it again.
However, as shown above, after `post()` returns, both `m` and `d` are unlocked,
which means we can immediately run `post()` again, without waiting for `d` mutex
becomes locked again. In `post()`, mutex `d` will be unlocked again, thus
violates the rule.

To fix the problem, we have to make sure either:

* After `d.unlock()`, `d.lock()` must be executed before the next `d.unlock()`.
* Before `d.unlock()`, mutex `d` must be in locked state.

Both rules are equivalent. We will see how Anthony Howe addressed this issue
using different approach.

## Solution #2

In this solution, Anthony Howe addressed the issue by securing the transition
from the signaling thread to the awaking thread by reusing mutex `m`.

```cpp
#include <mutex>
#include <thread>
#include <stdio.h>

class Semaphore
{
public:
    Semaphore(int c) : c(c)
    {
        d.lock();
    }

    void wait()
    {
        m.lock();
        c--;
        if (c < 0)
        {
            m.unlock();
            d.lock();
        }
        m.unlock();
    }

    void post()
    {
        m.lock();
        c++;
        if (c <= 0)
        {
            d.unlock();
        } else
        {
            m.unlock();
        }
    }

private:
    int c;
    std::mutex m;
    std::mutex d;
};

Semaphore sem(0);

void foo(const char *name)
{
    sem.wait();
    printf("%s: done\n", name);
}

int main()
{
    std::thread t1(foo, "thread 1");
    std::thread t2(foo, "thread 2");
    sem.post();
    sem.post();
    t1.join();
    t2.join();
    printf("main: done\n");
    return 0;
}
```

In this solution, after `d.unlock()`, `m` remains locked, which means subsequent
`post()`operations will be blocked until `m` is unlocked. Then `d.lock()` is
called following `m.unlock()`, making sure `d` is in locked state before
allowing subsequent `post()` operations to run. Thus, it satisfies with our
rules.

```
 +============+ +============+ +============+ +=======+ +========+ +========+
 |     t1     | |     t2     | |    main    | |   c   | |   m    | |   d    |
 +============+ +============+ +============+ +=======+ +========+ +========+
 |            | |            | | c = 0      | |   0   | |        | |        |
 |            | |            | | d.lock()   | |   0   | |        | |  main  |
 |            | |            | |            | |   0   | |        | |  main  |
 |    vvv============================^^^    | |   0   | |        | |  main  |
 |            | |            | |            | |   0   | |        | |  main  |
 | m.lock()   | |            | |            | |   0   | |   t1   | |  main  |
 | c--        | |            | |            | |  -1   | |   t1   | |  main  |
 | m.unlock() | |            | |            | |  -1   | |        | |  main  |
 |            | |            | |            | |  -1   | |        | |  main  |
 |    ^^^=============vvv    | |            | |  -1   | |        | |  main  |
 |            | |            | |            | |  -1   | |        | |  main  |
 |            | | m.lock()   | |            | |  -1   | |   t2   | |  main  |
 |            | | c--        | |            | |  -2   | |   t2   | |  main  |
 |            | | m.unlock() | |            | |  -2   | |        | |  main  |
 |            | |            | |            | |  -2   | |        | |  main  |
 |            | |    ^^^=============vvv    | |  -2   | |        | |  main  |
 |            | |            | |            | |  -2   | |        | |  main  |
 |            | |            | | m.lock()   | |  -2   | |  main  | |  main  |
 |            | |            | | c++        | |  -1   | |  main  | |  main  |
 |            | |            | | d.unlock() | |  -1   | |  main  | |        |
 |            | |            | |            | |  -1   | |  main  | |        |
 |            | |    vvv=============^^^    | |  -1   | |  main  | |        |
 |            | |            | |            | |  -1   | |  main  | |        |
 |            | | d.lock()   | |            | |  -1   | |  main  | |   t2   |
 |            | | m.unlock() | |            | |  -1   | |        | |   t2   |
 |            | |            | |            | |  -1   | |        | |   t2   |
 |            | |    ^^^=============vvv    | |  -1   | |        | |   t2   |
 |            | |            | |            | |  -1   | |        | |   t2   |
 |            | |            | | m.lock()   | |  -1   | |  main  | |   t2   |
 |            | |            | | c++        | |   0   | |  main  | |   t2   |
 |            | |            | | d.unlock() | |   0   | |  main  | |        |
 |            | |            | |            | |   0   | |  main  | |        |
 |    vvv============================^^^    | |   0   | |  main  | |        |
 |            | |            | |            | |   0   | |  main  | |        |
 | d.lock()   | |            | |            | |   0   | |  main  | |   t1   |
 | m.unlock() | |            | |            | |   0   | |        | |   t1   |
 +------------+ +------------+ +------------+ +-------+ +--------+ +--------+
```

Notice that at any moment, at least one mutex is locked.

## Solution #3

This solution introduces a new mutex `b` to prevent two threads waiting on mutex
`d` at the same time.

```cpp
#include <mutex>
#include <thread>
#include <stdio.h>

class Semaphore
{
public:
    Semaphore(int c) : c(c)
    {
        d.lock();
    }

    void wait()
    {
        b.lock();
        m.lock();
        c--;
        if (c < 0)
        {
            m.unlock();
            d.lock();
        } else {
            m.unlock();
        }
        b.unlock();
    }

    void post()
    {
        m.lock();
        c++;
        if (c <= 0)
        {
            d.unlock();
        }
        m.unlock();
    }

private:
    int c;
    std::mutex m;
    std::mutex d;
    std::mutex b;
};

Semaphore sem(0);

void foo(const char *name)
{
    sem.wait();
    printf("%s: done\n", name);
}

int main()
{
    std::thread t1(foo, "thread 1");
    std::thread t2(foo, "thread 2");
    sem.post();
    sem.post();
    t1.join();
    t2.join();
    printf("main: done\n");
    return 0;
}
```

```
 +============+ +============+ +============+ +=======+ +========+ +========+ +========+
 |     t1     | |     t2     | |    main    | |   c   | |   m    | |   d    | |   b    |
 +============+ +============+ +============+ +=======+ +========+ +========+ +========+
 |            | |            | | c = 0      | |   0   | |        | |        | |        |
 |            | |            | | d.lock()   | |   0   | |        | |  main  | |        |
 |            | |            | |            | |   0   | |        | |  main  | |        |
 |    vvv============================^^^    | |   0   | |        | |  main  | |        |
 |            | |            | |            | |   0   | |        | |  main  | |        |
 | b.lock()   | |            | |            | |   0   | |        | |  main  | |   t1   |
 | m.lock()   | |            | |            | |   0   | |   t1   | |  main  | |   t1   |
 | c--        | |            | |            | |  -1   | |   t1   | |  main  | |   t1   |
 | m.unlock() | |            | |            | |  -1   | |        | |  main  | |   t1   |
 |            | |            | |            | |  -1   | |        | |  main  | |   t1   |
 |    ^^^============================vvv    | |  -1   | |        | |  main  | |   t1   |
 |            | |            | |            | |  -1   | |        | |  main  | |   t1   |
 |            | |            | | m.lock()   | |  -1   | |  main  | |  main  | |   t1   |
 |            | |            | | c++        | |   0   | |  main  | |  main  | |   t1   |
 |            | |            | | d.unlock() | |   0   | |  main  | |        | |   t1   |
 |            | |            | | m.unlock() | |   0   | |        | |        | |   t1   |
 |            | |            | |            | |   0   | |        | |        | |   t1   |
 |    vvv============================^^^    | |   0   | |        | |        | |   t1   |
 |            | |            | |            | |   0   | |        | |        | |   t1   |
 | d.lock()   | |            | |            | |   0   | |        | |   t1   | |   t1   |
 | b.unlock() | |            | |            | |   0   | |        | |   t1   | |        |
 |            | |            | |            | |   0   | |        | |   t1   | |        |
 |    ^^^=============vvv    | |            | |   0   | |        | |   t1   | |        |
 |            | |            | |            | |   0   | |        | |   t1   | |        |
 |            | | b.lock()   | |            | |   0   | |        | |   t1   | |   t2   |
 |            | |            | |            | |   0   | |        | |   t1   | |   t2   |
 |            | |    ^^^=============vvv    | |   0   | |        | |   t1   | |   t2   |
 |            | |            | |            | |   0   | |        | |   t1   | |   t2   |
 |            | |            | | m.lock()   | |   0   | |  main  | |   t1   | |   t2   |
 |            | |            | | c++        | |   1   | |  main  | |   t1   | |   t2   |
 |            | |            | | m.unlock() | |   1   | |        | |   t1   | |   t2   |
 |            | |            | |            | |   1   | |        | |   t1   | |   t2   |
 |            | |    vvv=============^^^    | |   1   | |        | |   t1   | |   t2   |
 |            | |            | |            | |   1   | |        | |   t1   | |   t2   |
 |            | | m.lock()   | |            | |   1   | |   t2   | |   t1   | |   t2   |
 |            | | c--        | |            | |   0   | |   t2   | |   t1   | |   t2   |
 |            | | m.unlock() | |            | |   0   | |        | |   t1   | |   t2   |
 |            | | b.unlock() | |            | |   0   | |        | |   t1   | |        |
 +------------+ +------------+ +------------+ +-------+ +--------+ +--------+ +--------+
```

## Solution #4

```cpp
#include <mutex>
#include <thread>
#include <stdio.h>

class Semaphore
{
public:
    Semaphore(int c) : c(c)
    {
        if (c <= 0) d.lock();
    }

    void wait()
    {
        d.lock();
        m.lock();
        c--;
        if (c > 0)
        {
            d.unlock();
        }
        m.unlock();
    }

    void post()
    {
        m.lock();
        c++;
        if (c == 1)
        {
            d.unlock();
        }
        m.unlock();
    }

private:
    int c;
    std::mutex m;
    std::mutex d;
};

Semaphore sem(0);

void foo(const char *name)
{
    sem.wait();
    printf("%s: done\n", name);
}

int main()
{
    std::thread t1(foo, "thread 1");
    std::thread t2(foo, "thread 2");
    sem.post();
    sem.post();
    t1.join();
    t2.join();
    printf("main: done\n");
    return 0;
}
```

[semaphore]: <http://man7.org/linux/man-pages/man7/sem_overview.7.html>
[gensem]: <http://webhome.csc.uvic.ca/~mcheng/460/notes/gensem.pdf>

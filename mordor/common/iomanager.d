module mordor.common.iomanager;

import tango.io.Stdout;

import mordor.common.exception;
public import mordor.common.scheduler;

version(linux) {
    version = epoll;
}
version(darwin) {
    version = kqueue;
}

version(Windows)
{
    import win32.winbase;
    import win32.windef;

    class IOManager : Scheduler
    {
    public:
        this(int threads = 1, bool useCaller = true)
        {
            m_hCompletionPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
            super("IOManager", threads, useCaller);
        }

        void registerFile(HANDLE handle)
        {
            HANDLE hRet = CreateIoCompletionPort(handle, m_hCompletionPort, 0, 0);
            if (hRet != m_hCompletionPort) {
                throw exceptionFromLastError();
            }
        }

        void registerEvent(AsyncEvent* e)
        in
        {
            assert(e);
            assert(Scheduler.getThis);
            assert(Fiber.getThis);
        }
        body
        {
            e._scheduler = Scheduler.getThis;
            e._fiber = Fiber.getThis;
            synchronized (this) {
                assert(!(&e.overlapped in m_pendingEvents));
                m_pendingEvents[&e.overlapped] = e;
            }
        }

    protected:
        void idle()
        {
            DWORD numberOfBytes;
            ULONG_PTR completionKey;
            OVERLAPPED* overlapped;
            while (true) {
                if (stopping) {
                    synchronized (this) {
                        if (m_pendingEvents.length == 0) {
                            return;
                        }
                    }
                }
                //Stdout.formatln("in idle");
                BOOL ret = GetQueuedCompletionStatus(m_hCompletionPort,
                    &numberOfBytes, &completionKey, &overlapped, INFINITE);
                //Stdout.formatln("Got IO status: {} {} {} {} {}", ret, GetLastError(), completionKey, numberOfBytes, overlapped);

                if (ret && completionKey == ~0) {
                    Fiber.yield();
                    continue;
                }
                if (!ret && overlapped == NULL) {
                    throw exceptionFromLastError();
                }
                AsyncEvent* e;
                
                synchronized (this) {
                    e = m_pendingEvents[overlapped];
                    m_pendingEvents.remove(overlapped);
                }

                e.ret = ret;
                e.numberOfBytes = numberOfBytes;
                e.completionKey = completionKey;
                e.lastError = GetLastError();
                e._scheduler.schedule(e._fiber);
                Fiber.yield();
            }
        }

        void tickle()
        {
            PostQueuedCompletionStatus(m_hCompletionPort, 0, ~0, NULL);
        }

    private:
        HANDLE m_hCompletionPort;
        AsyncEvent*[OVERLAPPED*] m_pendingEvents;
    }

    struct AsyncEvent
    {
    public:
        BOOL ret;
        OVERLAPPED overlapped;
        DWORD numberOfBytes;
        ULONG_PTR completionKey;
        DWORD lastError;

    private:
        Scheduler _scheduler;
        Fiber _fiber;
    };
} else version(epoll) {
    import tango.stdc.errno;
    import tango.stdc.posix.unistd;
    import tango.sys.linux.epoll;

    class IOManager : Scheduler
    {
    public:
        this(int threads = 1, bool useCaller = true)
        {
            m_epfd = epoll_create(5000);
            pipe(m_tickleFds);
            epoll_event event;
            event.events = EPOLLIN;
            event.data.fd = m_tickleFds[0];
            epoll_ctl(m_epfd, EPOLL_CTL_ADD, m_tickleFds[0], &event);
            super("IOManager", threads, useCaller);
        }

        void registerEvent(AsyncEvent* e)
        in
        {
            assert(e);
            assert(Scheduler.getThis);
            assert(Fiber.getThis);
        }
        body
        {
            e.event.events &= (EPOLLIN | EPOLLOUT);
            assert(e.event.events != 0);
            synchronized (this) {
                int op;
                AsyncEvent** current = e.event.data.fd in m_pendingEvents;
                if (current is null) {
                    op = EPOLL_CTL_ADD;
                    m_pendingEvents[e.event.data.fd] = new AsyncEvent();
                    current = e.event.data.fd in m_pendingEvents;
                    **current = *e;
                } else {
                    op = EPOLL_CTL_MOD;
                    // OR == XOR means that none of the same bits were set
                    assert(((*current).event.events | e.event.events)
                        == ((*current).event.events ^ e.event.events));
                    (*current).event.events |= e.event.events;
                }
                if (e.event.events & EPOLLIN) {
                    (*current)._schedulerIn = Scheduler.getThis;
                    (*current)._fiberIn = Fiber.getThis;
                }
                if (e.event.events & EPOLLOUT) {
                    (*current)._schedulerOut = Scheduler.getThis;
                    (*current)._fiberOut = Fiber.getThis;
                }
                //Stdout.formatln("Registering events {} for fd {}", (*current).event.events,
                //    (*current).event.data.fd);
                int rc = epoll_ctl(m_epfd, op, (*current).event.data.fd,
                    &(*current).event);
                if (rc != 0) {
                    throw exceptionFromLastError();
                }
            }
        }

    protected:
        void idle()
        {
            epoll_event[] events = new epoll_event[64];
            while (true) {
                if (stopping) {
                    synchronized (this) {
                        if (m_pendingEvents.length == 0) {
                            return;
                        }
                    }
                }
                int rc = -1;
                errno = EINTR;
                while (rc < 0 && errno == EINTR)
                    rc = epoll_wait(m_epfd, events.ptr, events.length, -1);
                if (rc <= 0) {
                    throw exceptionFromLastError();
                }
                
                foreach (event; events[0..rc]) {
                    //Stdout.formatln("Got events {} for fd {}", event.events, event.data.fd);
                    if (event.data.fd == m_tickleFds[0]) {
                        ubyte dummy;
                        read(m_tickleFds[0], &dummy, 1);
                        continue;
                    }
                    bool err = event.events & EPOLLERR
                        || event.events & EPOLLHUP;
                    synchronized (this) {
                        AsyncEvent* e = m_pendingEvents[event.data.fd];
                        if (event.events & EPOLLIN ||
                            err && e.event.events & EPOLLIN) {
                            e._schedulerIn.schedule(e._fiberIn);
                        }
                        if (event.events & EPOLLOUT ||
                            err && e.event.events & EPOLLOUT) {
                            e._schedulerOut.schedule(e._fiberOut);
                        }
                        e.event.events &= ~event.events;
                        if (err || e.event.events == 0) {
                            rc = epoll_ctl(m_epfd, EPOLL_CTL_DEL,
                                e.event.data.fd, &e.event);
                            if (rc != 0) {
                            }
                            m_pendingEvents.remove(event.data.fd);
                        }
                    }
                }

                Fiber.yield();
            }
        }

        void tickle()
        {
            write(m_tickleFds[1], "T".ptr, 1);
        }

    private:
        int m_epfd;
        int[2] m_tickleFds;
        AsyncEvent*[int] m_pendingEvents;
    }

    struct AsyncEvent
    {
    public:
        epoll_event event;
    private:
        Scheduler _schedulerIn, _schedulerOut;
        Fiber _fiberIn, _fiberOut;
    };
} else version(kqueue) {
    import tango.stdc.posix.unistd;
    import tango.stdc.errno;
    
    struct timespec {
        time_t tv_sec;
        int    tv_nsec;
    };


    const short EVFILT_READ     = -1;
    const short EVFILT_WRITE    = -2;
    const short EVFILT_AIO      = -3;
    const short EVFILT_VNODE    = -4;
    const short EVFILT_PROC     = -5;
    const short EVFILT_SIGNAL   = -6;
    const short EVFILT_TIMER    = -7;
    const short EVFILT_MACHPORT = -8;
    const short EVFILT_FS       = -9;

    align(4) struct struct_kevent {
        size_t    ident;
        short     filter;
        ushort    flags;
        uint      fflags;
        ptrdiff_t data;
        void*     udata;
    }

    void EV_SET(ref struct_kevent event, int ident, short filter, ushort flags, uint fflags, ptrdiff_t data, void* udata)
    {
        event.ident = ident;
        event.filter = filter;
        event.flags = flags;
        event.fflags = fflags;
        event.data = data;
        event.udata = udata;
    }

    const ushort EV_ADD     = 0x0001;
    const ushort EV_DELETE  = 0x0002;
    const ushort EV_ENABLE  = 0x0004;
    const ushort EV_DISABLE = 0x0008;
    const ushort EV_RECEIPT = 0x0040;

    const ushort EV_ONESHOT = 0x0010;
    const ushort EV_CLEAR   = 0x0020;

    const ushort EV_EOF     = 0x8000;
    const ushort EV_ERROR   = 0x4000;

    extern (C) {
        int kqueue();
        int kevent(int kq, struct_kevent* changelist, int nchanges, struct_kevent* eventlist, int nevents, timespec* timeout);
    }

    class IOManager : Scheduler
    {
    public:
        this(int threads = 1, bool useCaller = true)
        {
            m_kqfd = kqueue();
            assert(m_kqfd > 0);
            pipe(m_tickleFds);
            struct_kevent event;
            EV_SET(event, m_tickleFds[0], EVFILT_READ, EV_ADD, 0, 0, null);
            int rc = kevent(m_kqfd, &event, 1, null, 0, null);
            assert(rc == 0);
            super("IOManager", threads, useCaller);
        }

        void registerEvent(AsyncEvent* e)
        in
        {
            assert(e);
            assert(Scheduler.getThis);
            assert(Fiber.getThis);
        }
        body
        {
            e._scheduler = Scheduler.getThis;
            e._fiber = Fiber.getThis;
            e.event.flags = EV_ADD;
            e.event.udata = cast(void*)e;
            int rc = kevent(m_kqfd, &e.event, 1, null, 0, null);
            if (rc != 0) {
                throw exceptionFromLastError();
            }
        }

    protected:
        void idle()
        {
            struct_kevent[] events = new struct_kevent[64];
            while (true) {
                if (stopping) {
                    // TODO: dunno if we have pending events
                    return;
                }
                int rc = -1;
                errno = EINTR;
                while (rc < 0 && errno == EINTR)
                    rc = kevent(m_kqfd, null, 0, events.ptr, events.length, null);
                if (rc <= 0) {
                    exceptionFromLastError();
                }
                
                foreach (event; events[0..rc]) {
                    //Stdout.formatln("Got events {} for fd {}", event.filter, event.ident);
                    if (event.ident == m_tickleFds[0]) {
                        ubyte dummy;
                        read(m_tickleFds[0], &dummy, 1);
                        continue;
                    }

                    event.flags = EV_DELETE;
                    rc = kevent(m_kqfd, &event, 1, null, 0, null);
                    if (rc != 0) {
                    }

                    auto e = cast(AsyncEvent*)event.udata;
                    assert(e);
                    e._scheduler.schedule(e._fiber);
                }

                Fiber.yield();
            }
        }

        void tickle()
        {
            write(m_tickleFds[1], "T".ptr, 1);
        }

    private:
        int m_kqfd;
        int[2] m_tickleFds;
    }

    struct AsyncEvent
    {
    public:
        Scheduler _scheduler;
        Fiber _fiber;
        struct_kevent event;
    };
}

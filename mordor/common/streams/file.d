module mordor.common.streams.file;

import tango.stdc.stringz;

import mordor.common.exception;
public import mordor.common.streams.stream;
import mordor.common.stringutils;

version (Windows) {
    import win32.winbase;
    import win32.winnt;
    
    import mordor.common.streams.handle;
    
    private alias HandleStream NativeStream;
    private alias HANDLE NativeHandle;
} else version (Posix) {
    import tango.stdc.posix.fcntl;
    
    import mordor.common.streams.fd;

    private alias FDStream NativeStream;
    private alias int NativeHandle;
}

class FileStream : NativeStream
{
public:
    version (Windows) {
        enum Flags {
            READ      = 0x01,
            WRITE     = 0x02,
            READWRITE = 0x03
        }
    } else version (Posix) {
        enum Flags {
            READ = O_RDONLY,
            WRITE = O_WRONLY,
            READWRITE = O_RDWR
        }
    }
    enum CreateFlags {
        CREATE_NEW = 1,
        CREATE_ALWAYS,
        OPEN_EXISTING,
        OPEN_ALWAYS,
        TRUNCATE_EXISTING        
    }
    
    version (Windows) {
        this(wstring filename, Flags flags = Flags.READWRITE, CreateFlags createFlags = CreateFlags.OPEN_EXISTING)
        {
            _fileW = filename;
            NativeHandle handle;
            DWORD access;
            if (flags & flags.READ)
                access |= GENERIC_READ;
            if (flags & flags.WRITE)
                access |= GENERIC_WRITE;
            handle = CreateFileW(toString16z(filename),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                NULL,
                cast(DWORD)createFlags,
                0,
                NULL);
            if (handle == cast(NativeHandle)-1) {
                throw exceptionFromLastError();
            }
            super(handle);
            _supportsRead = flags == Flags.READ || flags == Flags.READWRITE;
            _supportsWrite = flags == Flags.WRITE || flags == Flags.READWRITE;
        }
    }
    
    this(string filename, Flags flags = Flags.READWRITE, CreateFlags createFlags = CreateFlags.OPEN_EXISTING)
    {
        _file = filename;
        NativeHandle handle;
        version (Windows) {
            DWORD access;
            if (flags & flags.READ)
                access |= GENERIC_READ;
            if (flags & flags.WRITE)
                access |= GENERIC_WRITE;
            handle = CreateFileA(toStringz(filename),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                NULL,
                cast(DWORD)createFlags,
                0,
                NULL);
        } else version (Posix) {
            int oflags = cast(int)flags;
            switch (createFlags) {
                case CreateFlags.CREATE_NEW:
                    oflags |= O_CREAT | O_EXCL;
                    break;
                case CreateFlags.CREATE_ALWAYS:
                    oflags |= O_CREAT | O_TRUNC;
                    break;
                case CreateFlags.OPEN_EXISTING:
                    break;
                case CreateFlags.OPEN_ALWAYS:
                    oflags |= O_CREAT;
                    break;
                case CreateFlags.TRUNCATE_EXISTING:
                    oflags |= O_TRUNC;
                    break;
            }
            handle = open(toStringz(filename), oflags, 0777);            
        }
        if (handle == cast(NativeHandle)-1) {
            throw exceptionFromLastError();
        }
        super(handle);
        _supportsRead = flags == Flags.READ || flags == Flags.READWRITE;
        _supportsWrite = flags == Flags.WRITE || flags == Flags.READWRITE;
    }
    
    bool supportsRead() { return _supportsRead && super.supportsRead; }
    bool supportsWrite() { return _supportsWrite && super.supportsWrite; }
    
    string toString() { return _file; }
    
private:
    bool _supportsRead;
    bool _supportsWrite;
    
    string _file;
    version (Windows) wstring _fileW;
}

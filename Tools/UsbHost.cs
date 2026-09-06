// Native claims only. Package, layout and workflow policy belong to PowerShell.
// Linux open(2) O_EXCL for block devices; Windows FSCTL_LOCK_VOLUME plus
// exclusive PhysicalDrive handle. See USB-Erstellung.txt for API sources.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public sealed class R4UsbClaim : IDisposable {
    // Disable managed read-ahead on target handles. A buffered FileStream can
    // request 1 MB when the caller only reads the final 64 KB (or GPT sector),
    // crossing the physical device end. Windows rejects that raw request.
    // Copy/Verify already provide their own sector-aligned 1-MB transfer buffers.
    // Virtual targets use the identical stream policy.
    const int TargetStreamBufferSize=1;
    [DllImport("libc", SetLastError=true)] static extern int open(string path,int flags);
    [DllImport("libc", SetLastError=true)] static extern int flock(int fd,int operation);
    [DllImport("libc", EntryPoint="ioctl", SetLastError=true)] static extern int IoLong(int fd,ulong request,ref long value);
    [DllImport("libc", EntryPoint="ioctl", SetLastError=true)] static extern int IoInt(int fd,ulong request,ref int value);
    [DllImport("libc")] static extern IntPtr realpath(string path,IntPtr result);
    [DllImport("libc")] static extern void free(IntPtr memory);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle handle,uint code,IntPtr input,uint inputBytes,byte[] output,uint outputBytes,out uint returned,IntPtr overlapped);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder path,uint length,uint flags);
    readonly List<SafeFileHandle> volumes=new List<SafeFileHandle>();
    public FileStream Stream {get;private set;}
    public long Bytes {get;private set;}
    public int SectorBytes {get;private set;}
    static IOException Native(string operation) {return new IOException(operation+": "+new Win32Exception(Marshal.GetLastWin32Error()).Message);}
    static void Control(SafeFileHandle h,uint code,byte[] output) {
        if(!DeviceIoControl(h,code,IntPtr.Zero,0,output,(uint)(output?.Length??0),out var n,IntPtr.Zero))throw Native("Device control "+code.ToString("x"));
        if(output!=null && n<output.Length)throw new IOException("Incomplete device geometry.");
    }
    public static string Canonical(string path) {
        if(OperatingSystem.IsWindows()) {
            using(var h=CreateFileW(Path.GetFullPath(path),0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
                if(h.IsInvalid)throw Native("Resolve path");
                var b=new StringBuilder(32768);var count=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0);
                if(count==0 || count>=b.Capacity)throw Native("Resolve final path");
                var value=b.ToString();return value.StartsWith(@"\\?\UNC\") ? @"\\"+value.Substring(8) : value.StartsWith(@"\\?\") ? value.Substring(4) : value;
            }
        }
        var p=realpath(path,IntPtr.Zero);if(p==IntPtr.Zero)throw Native("Resolve path");
        try{return Marshal.PtrToStringUTF8(p);}finally{free(p);}
    }
    public R4UsbClaim(string path,long expectedBytes,int expectedSectorBytes,bool regularFile,string[] volumePaths) {
        SafeFileHandle handle=null;
        try {
            if(regularFile) {
                Stream=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None,TargetStreamBufferSize);
                if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new IOException("Virtual target must be a regular file.");
                Bytes=Stream.Length;SectorBytes=512;
                if(!OperatingSystem.IsWindows() && flock(Stream.SafeFileHandle.DangerousGetHandle().ToInt32(),6)!=0)throw Native("Virtual image claim");
            } else if(OperatingSystem.IsWindows()) {
                foreach(var volume in volumePaths) {
                    var h=CreateFileW(volume.TrimEnd('\\'),0xc0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
                    if(h.IsInvalid){h.Dispose();throw Native("Open volume");}
                    volumes.Add(h);Control(h,0x90018,null);Control(h,0x90020,null);
                }
                handle=CreateFileW(path,0xc0000000,0,IntPtr.Zero,3,0x80000000,IntPtr.Zero);
                if(handle.IsInvalid)throw Native("Exclusive physical drive claim");
                var length=new byte[8];Control(handle,0x7405c,length);Bytes=BitConverter.ToInt64(length,0);
                var geometry=new byte[24];Control(handle,0x70000,geometry);SectorBytes=BitConverter.ToInt32(geometry,20);
                Stream=new FileStream(handle,FileAccess.ReadWrite,TargetStreamBufferSize,false);handle=null;
            } else {
                // No create/truncate: a mounted/in-use block device fails EBUSY.
                int fd=open(path,2|128|0x80000|0x20000);if(fd<0)throw Native("Exclusive USB claim");
                handle=new SafeFileHandle((IntPtr)fd,true);
                if(flock(fd,6)!=0)throw Native("USB file lock");
                long bytes=0;int logical=0;
                if(IoLong(fd,0x80081272,ref bytes)!=0 || IoInt(fd,0x1268,ref logical)!=0)throw Native("USB geometry");
                Bytes=bytes;SectorBytes=logical;Stream=new FileStream(handle,FileAccess.ReadWrite,TargetStreamBufferSize,false);handle=null;
            }
            if(Bytes!=expectedBytes || SectorBytes!=expectedSectorBytes || SectorBytes!=512 || Bytes%512!=0)throw new IOException("Target geometry changed or is unsupported.");
        } catch {handle?.Dispose();Dispose();throw;}
    }
    public static string Fingerprint(Stream source,long bytes) {
        if(bytes<131072)throw new IOException("Target too small.");
        var buffer=new byte[131072];source.Position=0;source.ReadExactly(buffer,0,65536);
        source.Position=bytes-65536;source.ReadExactly(buffer,65536,65536);
        return Convert.ToHexString(SHA256.HashData(buffer)).ToLowerInvariant();
    }
    public void Copy(Stream source,long first,long count) {
        long at=checked(first*512),bytes=checked(count*512);
        if(count<=0 || first<0 || at>Bytes-bytes)throw new IOException("USB write outside target.");
        var buffer=new byte[1024*1024];source.Position=at;Stream.Position=at;
        while(bytes>0){int n=(int)Math.Min(bytes,buffer.Length);source.ReadExactly(buffer,0,n);Stream.Write(buffer,0,n);bytes-=n;}
    }
    public void Verify(Stream source,long first,long count) {
        long at=checked(first*512),bytes=checked(count*512);
        if(count<=0 || first<0 || at>Bytes-bytes)throw new IOException("USB verify outside target.");
        var expected=new byte[1024*1024];var actual=new byte[expected.Length];source.Position=at;Stream.Position=at;
        while(bytes>0){int n=(int)Math.Min(bytes,expected.Length);source.ReadExactly(expected,0,n);Stream.ReadExactly(actual,0,n);
            if(!expected.AsSpan(0,n).SequenceEqual(actual.AsSpan(0,n)))throw new IOException("USB readback mismatch at byte "+Stream.Position);bytes-=n;}
    }
    public void Flush(){Stream.Flush(true);}
    public void Dispose(){Stream?.Dispose();Stream=null;foreach(var h in volumes)h.Dispose();volumes.Clear();}
}

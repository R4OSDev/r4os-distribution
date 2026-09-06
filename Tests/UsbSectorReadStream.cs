// A read-only raw-device surrogate for the existing USB acceptance. Ordinary
// files accept short, unaligned reads that a Windows PhysicalDrive rejects.
using System;
using System.IO;

public sealed class UsbSectorReadStream : Stream {
    readonly FileStream file;
    public long ReadCalls { get; private set; }
    public long ReadBytes { get; private set; }
    public long FinalSectorReads { get; private set; }
    public UsbSectorReadStream(string path) {
        file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,1);
        if(file.Length%512!=0){file.Dispose();throw new IOException("Unaligned device length.");}
    }
    public override bool CanRead => true;
    public override bool CanSeek => true;
    public override bool CanWrite => false;
    public override long Length => file.Length;
    public override long Position { get => file.Position; set => file.Position=value; }
    void Check(int count) {
        long at=Position;
        if(at<0 || count<0 || at>Length-count || at%512!=0 || count%512!=0)
            throw new IOException("Raw-device read contract: offset="+at+", count="+count+", bytes="+Length);
        ReadCalls++;ReadBytes+=count;
        if(count!=0 && at+count==Length)FinalSectorReads++;
    }
    public override int Read(byte[] buffer,int offset,int count) {
        Check(count);file.ReadExactly(buffer,offset,count);return count;
    }
    public override int Read(Span<byte> buffer) {
        Check(buffer.Length);file.ReadExactly(buffer);return buffer.Length;
    }
    public override long Seek(long offset,SeekOrigin origin) => file.Seek(offset,origin);
    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer,int offset,int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if(disposing)file.Dispose();base.Dispose(disposing); }
}

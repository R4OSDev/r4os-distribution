using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

// Bounded, read-only extraction from the project's NTFS test images.
// No mount, platform driver, write handle or whole-image buffer is required.
public sealed class R4GuestNtfs : IDisposable {
    readonly FileStream file;
    readonly long first;
    readonly int sector, cluster, recordSize;
    readonly Data mft;
    sealed class Extent { public long Lcn, Count; public bool Hole; }
    sealed class Data { public byte[] Resident; public long Length, Initialized; public List<Extent> Runs = new List<Extent>(); }
    R4GuestNtfs(string path,long offset) {
        file=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.Read);
        try {
            first=offset; var boot=Raw(0,512);
            Need(Encoding.ASCII.GetString(boot,3,8)=="NTFS    ","NTFS boot");
            sector=U16(boot,11); cluster=checked(sector*boot[13]);
            Need(sector==512 && cluster>=512 && cluster<=65536 && (cluster&(cluster-1))==0,"cluster geometry");
            int code=(sbyte)boot[64]; Need(code>=-16 && code!=0,"record exponent"); recordSize=code<0?1<<-code:checked(code*cluster);
            Need(recordSize>=512 && recordSize<=65536 && recordSize%sector==0,"record size");
            var zero=Fix(Raw(checked((long)U64(boot,48)*cluster),recordSize));
            mft=Stream(zero); Need(mft.Initialized/recordSize<=131072,"MFT limit");
        } catch {file.Dispose();throw;}
    }
    public static byte[] ReadFile(string image,long partitionOffset,string path) {
        using(var reader=new R4GuestNtfs(image,partitionOffset)) return reader.ReadPath(path);
    }
    static void Need(bool value,string why) {if(!value)throw new InvalidDataException(why);}
    static ushort U16(byte[] b,int p) {Need(p>=0 && p<=b.Length-2,"u16 range");return BitConverter.ToUInt16(b,p);}
    static uint U32(byte[] b,int p) {Need(p>=0 && p<=b.Length-4,"u32 range");return BitConverter.ToUInt32(b,p);}
    static ulong U64(byte[] b,int p) {Need(p>=0 && p<=b.Length-8,"u64 range");return BitConverter.ToUInt64(b,p);}
    byte[] Raw(long offset,int count) {
        long absolute=checked(first+offset); Need(offset>=0 && count>=0 && absolute<=file.Length-count,"image range");
        var bytes=new byte[count];file.Position=absolute;int done=0;
        while(done<count){int n=file.Read(bytes,done,count-done);if(n==0)throw new EndOfStreamException();done+=n;}return bytes;
    }
    byte[] Fix(byte[] bytes) {
        Need(Encoding.ASCII.GetString(bytes,0,4)=="FILE","FILE signature");
        int usa=U16(bytes,4),count=U16(bytes,6);Need(count==recordSize/sector+1 && usa+count*2<=bytes.Length,"FILE fixups");
        ushort stamp=U16(bytes,usa);
        for(int i=1;i<count;i++){int end=i*sector-2;Need(U16(bytes,end)==stamp,"torn FILE record");bytes[end]=bytes[usa+i*2];bytes[end+1]=bytes[usa+i*2+1];}return bytes;
    }
    IEnumerable<int> Attributes(byte[] record) {
        int p=U16(record,20),used=checked((int)U32(record,24));Need(used<=record.Length,"FILE used length");
        while(p<=used-8){uint kind=U32(record,p);if(kind==0xffffffff)yield break;
            int length=checked((int)U32(record,p+4));Need(length>=24 && length<=used-p,"attribute length");
            Need(kind!=0x20,"attribute-list export unsupported");yield return p;p+=length;
        }
    }
    Data Stream(byte[] record) {
        Data data=null;
        foreach(int p in Attributes(record)){
            if(U32(record,p)!=0x80 || record[p+9]!=0)continue;
            Need(data==null,"duplicate data stream");Need((U16(record,p+12)&0x4001)==0,"compressed/encrypted export");data=new Data();
            int length=checked((int)U32(record,p+4));
            if(record[p+8]==0){int size=checked((int)U32(record,p+16)),at=U16(record,p+20);Need(at>=24 && size<=length-at,"resident range");
                data.Resident=new byte[size];Array.Copy(record,p+at,data.Resident,0,size);data.Length=data.Initialized=size;continue;}
            Need(length>=64 && U64(record,p+16)==0,"nonresident base");data.Length=checked((long)U64(record,p+48));data.Initialized=checked((long)U64(record,p+56));
            Need(data.Initialized<=data.Length,"initialized length");int r=p+U16(record,p+32);long lcn=0,covered=0;
            while(r<p+length && record[r]!=0){byte header=record[r++];int n=header&15,m=header>>4;Need(n>0 && n<=8 && m<=8 && r+n+m<=p+length,"run encoding");
                ulong count=0,delta=0;for(int i=0;i<n;i++)count|=(ulong)record[r+i]<<(8*i);r+=n;
                for(int i=0;i<m;i++)delta|=(ulong)record[r+i]<<(8*i);
                if(m>0 && m<8 && (record[r+m-1]&128)!=0)delta|=ulong.MaxValue<<(8*m);r+=m;
                Need(count>0 && count<=long.MaxValue,"run count");if(m>0)lcn=checked(lcn+unchecked((long)delta));Need(lcn>=0,"run LCN");
                data.Runs.Add(new Extent{Lcn=lcn,Count=(long)count,Hole=m==0});covered=checked(covered+checked((long)count*cluster));
            }
            Need(r<p+length && covered>=data.Length,"run coverage");
        }
        Need(data!=null,"data stream missing");return data;
    }
    byte[] Bytes(Data data,long offset,int count) {
        Need(offset>=0 && count>=0 && offset<=data.Length-count,"stream range");var result=new byte[count];
        if(data.Resident!=null){Array.Copy(data.Resident,offset,result,0,count);return result;}
        long position=0;int written=0;
        foreach(var run in data.Runs){long bytes=checked(run.Count*cluster),end=checked(position+bytes);
            if(offset<end && written<count){long within=Math.Max(0,offset-position);int take=(int)Math.Min(count-written,bytes-within);
                int valid=(int)Math.Min(take,Math.Max(0,data.Initialized-offset));
                if(!run.Hole && valid>0)Array.Copy(Raw(checked(run.Lcn*cluster+within),valid),0,result,written,valid);
                written+=take;offset+=take;}
            position=end;
        }
        Need(written==count,"uncovered data");return result;
    }
    byte[] Record(long index) {return Fix(Bytes(mft,checked(index*recordSize),recordSize));}
    byte[] ReadPath(string path) {
        long parent=5;byte[] found=Record(parent);
        var parts=path.Replace('\\','/').Split('/',StringSplitOptions.RemoveEmptyEntries);Need(parts.Length>0 && parts.Length<=32,"path depth");
        foreach(string name in parts){Need(name!="." && name!="..","path component");Need((U16(found,22)&3)==3,"parent directory");
            ushort sequence=U16(found,16);long match=-1;byte[] selected=null;
            for(long i=0;i<mft.Initialized/recordSize;i++){
                var raw=Bytes(mft,i*recordSize,recordSize);
                if(Encoding.ASCII.GetString(raw,0,4)!="FILE" || (U16(raw,22)&1)==0)continue;
                var row=Fix(raw);
                foreach(int at in Attributes(row)){
                    if(U32(row,at)!=0x30 || row[at+8]!=0)continue;
                    int size=checked((int)U32(row,at+16)),value=at+U16(row,at+20),end=at+checked((int)U32(row,at+4));
                    Need(size>=66 && value<=end-size,"filename range");ulong reference=U64(row,value);
                    int chars=row[value+64];Need(66+chars*2<=size,"filename size");
                    if((reference&0xffffffffffffUL)!=(ulong)parent || (reference>>48)!=sequence)continue;
                    if(!String.Equals(Encoding.Unicode.GetString(row,value+66,chars*2),name,StringComparison.OrdinalIgnoreCase))continue;
                    Need(match==-1 || match==i,"ambiguous path");match=i;selected=row;
                }
            }
            if(match<0)throw new FileNotFoundException(path);parent=match;found=selected;
        }
        Need((U16(found,22)&2)==0,"file required");var stream=Stream(found);Need(stream.Length<=4*1024*1024,"export size limit");
        return Bytes(stream,0,checked((int)stream.Length));
    }
    public void Dispose(){file.Dispose();}
}

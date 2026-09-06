// Independent, read-only inspection of the serialized installation image.
// Used by the image acceptance; no formatter or guest storage implementation.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;

public sealed class InstallationImageCheck : IDisposable {
    public sealed class Partition {
        public string Role, Guid, Type;
        public long First, Count;
    }
    sealed class FatEntry { public uint First, Bytes; public bool Directory; public long Slot; }
    public sealed class Fat {
        readonly InstallationImageCheck image;
        readonly Partition partition;
        readonly byte[] table;
        readonly long data;
        readonly uint clusters;
        readonly int clusterBytes;
        readonly Dictionary<string,FatEntry> files = new Dictionary<string,FatEntry>(StringComparer.OrdinalIgnoreCase);
        public readonly long FreeBytes;
        public int ClusterBytes { get { return clusterBytes; } }
        public Fat(InstallationImageCheck image, Partition partition) {
            this.image=image; this.partition=partition;
            long start=partition.First*512; var boot=image.Read(start,512);
            Require(U16(boot,11)==512 && boot[16]==2 && U16(boot,17)==0 && U16(boot,22)==0 &&
                U32(boot,28)==partition.First && U32(boot,32)==partition.Count && Text(boot,82,8)=="FAT32   " &&
                boot[510]==85 && boot[511]==170, "FAT geometry "+partition.Role);
            int spc=boot[13]; Require(spc>0 && spc<=128 && (spc&(spc-1))==0,"FAT cluster geometry");
            clusterBytes=spc*512;
            long fat=start+U16(boot,14)*512L; int tableBytes=checked((int)U32(boot,36)*512);
            data=fat+2L*tableBytes;
            Require(tableBytes>0 && data<start+partition.Count*512,"FAT table bounds");
            clusters=checked((uint)((start+partition.Count*512-data)/clusterBytes));
            Require(clusters>=65525 && tableBytes/4L>=clusters+2,"FAT32 cluster count");
            table=image.Read(fat,tableBytes);
            Require(table.AsSpan().SequenceEqual(image.Read(fat+tableBytes,tableBytes)),"FAT mirrors");
            Require(boot.AsSpan().SequenceEqual(image.Read(start+U16(boot,50)*512L,512)),"FAT backup boot sector");
            var owners=new HashSet<uint>(); var dirs=new Queue<(uint,string)>(); dirs.Enqueue((U32(boot,44),""));
            while(dirs.Count!=0) {
                var dir=dirs.Dequeue(); var chain=Chain(dir.Item1,owners); var prefixes=new List<byte[]>(); bool ended=false;
                foreach(uint cluster in chain) {
                    long at=data+(cluster-2L)*clusterBytes; var bytes=image.Read(at,clusterBytes);
                    for(int i=0;i<bytes.Length && !ended;i+=32) {
                        var raw=bytes.AsSpan(i,32).ToArray();
                        if(raw[0]==0) { Require(prefixes.Count==0,"Dangling FAT LFN"); ended=true; break; }
                        if(raw[0]==229) { prefixes.Clear(); continue; }
                        if(raw[11]==15) { Require(prefixes.Count<20,"LFN bound"); prefixes.Add(raw); continue; }
                        string name=Text(raw,0,8).TrimEnd(); string ext=Text(raw,8,3).TrimEnd(); if(ext.Length!=0)name+="."+ext;
                        if(prefixes.Count!=0) {
                            byte checksum=0; for(int j=0;j<11;j++)checksum=(byte)(((checksum&1)<<7)+(checksum>>1)+raw[j]);
                            var chars=new StringBuilder();
                            for(int j=prefixes.Count-1;j>=0;j--) {
                                var prefix=prefixes[j]; int ordinal=prefixes.Count-j;
                                Require(prefix[0]==(ordinal|(j==0?64:0)) && prefix[13]==checksum && prefix[12]==0 && U16(prefix,26)==0,"LFN owner/sequence");
                                foreach(int offset in new[]{1,3,5,7,9,14,16,18,20,22,24,28,30}) {
                                    char c=(char)U16(prefix,offset); if(c!=0 && c!=65535)chars.Append(c);
                                }
                            }
                            name=chars.ToString(); prefixes.Clear();
                        }
                        if(name=="." || name==".." || (raw[11]&8)!=0)continue;
                        Require(name.Length>0 && !name.Contains('/') && !name.Contains('\\'),"FAT name");
                        string path=dir.Item2+name;
                        var entry=new FatEntry {First=((uint)U16(raw,20)<<16)|U16(raw,26),Bytes=U32(raw,28),Directory=(raw[11]&16)!=0,Slot=at+i};
                        Require(files.Count<8192 && files.TryAdd(path,entry),"FAT path ownership");
                        if(entry.Directory)dirs.Enqueue((entry.First,path+"/"));
                        else if(entry.Bytes!=0 || entry.First!=0) {
                            var allocated=Chain(entry.First,owners);
                            Require(allocated.Count==(entry.Bytes+(long)clusterBytes-1)/clusterBytes,"FAT file length "+path);
                        }
                    }
                }
                Require(prefixes.Count==0,"Trailing FAT LFN");
            }
            long free=0;
            for(uint i=2;i<clusters+2;i++) {
                uint value=U32(table,checked((int)i*4))&0x0fffffff;
                if(value==0){Require(!owners.Contains(i),"Live free cluster"); free++;}
                else Require(owners.Contains(i),"Unreachable FAT allocation");
            }
            var fsinfo=image.Read(start+U16(boot,48)*512L,512);
            Require(U32(fsinfo,0)==0x41615252 && U32(fsinfo,484)==0x61417272 && U32(fsinfo,488)==free,"FAT free-space summary");
            FreeBytes=free*clusterBytes;
        }
        List<uint> Chain(uint first,HashSet<uint> owners) {
            var result=new List<uint>(); uint at=first;
            while(at<0x0ffffff8) {
                Require(at>=2 && at<clusters+2 && owners.Add(at),"FAT cross-link/cycle/bounds");
                result.Add(at); at=U32(table,checked((int)at*4))&0x0fffffff;
            }
            return result;
        }
        public byte[] ReadFile(string path) {
            Require(files.TryGetValue(path,out var entry) && !entry.Directory && entry.Bytes<=1024L*1024*1024,"FAT file "+path);
            var result=new byte[checked((int)entry.Bytes)]; if(result.Length==0)return result;
            int at=0;
            foreach(uint cluster in Chain(entry.First,new HashSet<uint>())) {
                int count=Math.Min(clusterBytes,result.Length-at);
                image.Read(data+(cluster-2L)*clusterBytes,count).CopyTo(result,at); at+=count;
            }
            Require(at==result.Length,"FAT short read"); return result;
        }
        public string[] Paths() { var result=new List<string>(); foreach(var pair in files)if(!pair.Value.Directory)result.Add(pair.Key); return result.ToArray(); }
        // Return exact extents to the acceptance's separate fixture writer.
        // Inspection itself never opens the image for writing.
        public long[] FileSectors(string path) {
            Require(files.TryGetValue(path,out var entry) && !entry.Directory,"Fixture file missing");
            var result=new List<long>();
            foreach(uint cluster in Chain(entry.First,new HashSet<uint>()))
                for(int i=0;i<clusterBytes/512;i++)result.Add((data+(cluster-2L)*clusterBytes)/512+i);
            return result.ToArray();
        }
    }
    readonly Stream file;
    readonly bool leaveOpen;
    public readonly Dictionary<string,Partition> Partitions=new Dictionary<string,Partition>(StringComparer.Ordinal);
    public readonly Dictionary<string,Fat> Volumes=new Dictionary<string,Fat>(StringComparer.Ordinal);
    public readonly long Bytes;
    public readonly string DiskGuid;
    public InstallationImageCheck(string path) : this(path, false) { }
    public InstallationImageCheck(string path, bool allowNonstandardSystem) : this(File.OpenRead(path),0,allowNonstandardSystem,false) { }
    public InstallationImageCheck(Stream source,long bytes,bool allowNonstandardSystem,bool leaveOpen) {
        file=source;this.leaveOpen=leaveOpen;
        try {
            Bytes=bytes==0 ? file.Length : bytes; Require(Bytes%512==0 && Bytes>=(3411968L+32769+33)*512,"Installation image size");
            long sectors=Bytes/512;
            var mbr=Read(0,512); Require(mbr[510]==85 && mbr[511]==170 && mbr[450]==238 && U32(mbr,454)==1 && U32(mbr,458)==Math.Min(sectors-1,uint.MaxValue),"Protective MBR");
            for(int i=462;i<510;i++)Require(mbr[i]==0,"Additional MBR partition");
            var primary=Header(1,sectors-1); var backup=Header(sectors-1,1);
            Require(U64(primary,72)==2 && U64(backup,72)==(ulong)(sectors-33) && U64(primary,40)==34 && U64(primary,48)==(ulong)(sectors-34),"GPT metadata placement");
            Require(primary.AsSpan(40,32).SequenceEqual(backup.AsSpan(40,32)),"GPT range/identity agreement");
            var entries=Read(1024,16384); Require(Crc(entries)==U32(primary,88),"Primary GPT array CRC");
            var other=Read((sectors-33)*512,16384);
            Require(Crc(other)==U32(backup,88) && entries.AsSpan().SequenceEqual(other),"Backup GPT array agreement");
            DiskGuid=new Guid(primary.AsSpan(56,16)).ToString(); var ids=new HashSet<string>(); Require(DiskGuid!=Guid.Empty.ToString() && ids.Add(DiskGuid),"Disk GUID");
            string[] roles={"BIOSBOOT","BOOT","SYSTEM","RECOVERY","DATA"}; long[] first={2048,4096,266240,2363392,3411968};
            long[] count={2048,262144,2097152,1048576,sectors-33-3411968};
            string[] types={"21686148-6449-6e6f-744e-656564454649","c12a7328-f81f-11d2-ba4b-00a0c93ec93b","ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"};
            for(int i=0;i<128;i++) {
                int at=i*128;
                if(i>=5){foreach(byte b in entries.AsSpan(at,128))Require(b==0,"Extra GPT partition");continue;}
                string name=Encoding.Unicode.GetString(entries,at+56,72).TrimEnd('\0');
                var part=new Partition {Role=name,Type=new Guid(entries.AsSpan(at,16)).ToString(),Guid=new Guid(entries.AsSpan(at+16,16)).ToString(),First=checked((long)U64(entries,at+32)),Count=checked((long)(U64(entries,at+40)-U64(entries,at+32)+1))};
                Require(name==roles[i] && part.Type==types[Math.Min(i,2)] && part.First==first[i] &&
                    (part.Count==count[i] || (allowNonstandardSystem && i==2 && part.First+part.Count<=first[3])) &&
                    part.Count>0 && part.First%2048==0,"GPT role/geometry "+roles[i]);
                Require(part.Guid!=Guid.Empty.ToString() && ids.Add(part.Guid),"Duplicate/zero partition GUID");
                Partitions.Add(name,part);
            }
            Require(U64(mbr,0x1a4)==(ulong)(Partitions["BIOSBOOT"].First*512),"BIOS stage reference");
            foreach(string role in new[]{"BOOT","RECOVERY"})Volumes.Add(role,new Fat(this,Partitions[role]));
            foreach(string role in new[]{"SYSTEM","DATA"}) {
                var part=Partitions[role]; var boot=Read(part.First*512,512);
                Require(Text(boot,3,8)=="NTFS    " && U16(boot,11)==512 && U64(boot,40)==(ulong)(part.Count-1),"NTFS geometry "+role);
                Require(boot.AsSpan().SequenceEqual(Read((part.First+part.Count-1)*512,512)),"NTFS backup boot "+role);
            }
        } catch { if(!leaveOpen)file.Dispose(); throw; }
    }
    byte[] Header(long at,long other) {
        var bytes=Read(at*512,512);
        Require(Text(bytes,0,8)=="EFI PART" && U32(bytes,8)==65536 && U32(bytes,12)==92 && U32(bytes,20)==0 && U64(bytes,24)==(ulong)at && U64(bytes,32)==(ulong)other && U32(bytes,80)==128 && U32(bytes,84)==128,"GPT header");
        var header=bytes.AsSpan(0,92).ToArray(); Array.Clear(header,16,4); Require(Crc(header)==U32(bytes,16),"GPT header CRC"); return bytes;
    }
    byte[] Read(long at,int count) { Require(at>=0 && count>=0 && at<=Bytes-count,"Image read bounds"); var result=new byte[count]; file.Position=at; file.ReadExactly(result); return result; }
    static ushort U16(byte[] b,int at) { return BitConverter.ToUInt16(b,at); }
    static uint U32(byte[] b,int at) { return BitConverter.ToUInt32(b,at); }
    static ulong U64(byte[] b,int at) { return BitConverter.ToUInt64(b,at); }
    static string Text(byte[] b,int at,int count) { return Encoding.ASCII.GetString(b,at,count); }
    static void Require(bool ok,string message) { if(!ok)throw new InvalidDataException(message); }
    static uint Crc(byte[] bytes) { uint crc=uint.MaxValue; foreach(byte value in bytes){crc^=value; for(int i=0;i<8;i++)crc=(crc>>1)^((crc&1)!=0?0xedb88320u:0);} return ~crc; }
    public static string Hash(byte[] bytes) { return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(); }
    public static void RecoveryPair(byte[] elf,byte[] runtime,string version,string kernel,bool required) {
        Require(elf.Length>=64 && elf[0]==127 && Text(elf,1,3)=="ELF" && elf[4]==2 && elf[5]==1 && U16(elf,18)==62,"Recovery ELF64/x86_64");
        int start=checked((int)U64(elf,40)),stride=U16(elf,58),count=U16(elf,60),strings=U16(elf,62);
        Require(stride>=64 && count>0 && count<=4096 && strings<count && start>=0 && start<=elf.Length-count*stride,"Recovery ELF section table");
        int names=checked((int)U64(elf,start+strings*stride+24)),size=checked((int)U64(elf,start+strings*stride+32));
        Require(names>=0 && size>0 && names<=elf.Length-size,"Recovery ELF section names");bool found=false;
        for(int i=0;i<count;i++){
            int at=start+i*stride,index=checked((int)U32(elf,at));Require(index<size,"Recovery ELF name offset");
            int end=Array.IndexOf(elf,(byte)0,names+index,size-index);Require(end>=0,"Recovery ELF name termination");
            if(Text(elf,names+index,end-names-index)!=".r4os.recovery.pair")continue;
            int offset=checked((int)U64(elf,at+24));
            Require(!found && U32(elf,at+4)==1 && U64(elf,at+32)==112 && offset>=0 && offset<=elf.Length-112,"Recovery pair section");
            Require(Text(elf,offset,8)=="R4RECOV1" && U64(elf,offset+8)==(ulong)runtime.LongLength &&
                elf.AsSpan(offset+16,32).SequenceEqual(SHA256.HashData(runtime)) && Text(elf,offset+48,32).TrimEnd('\0')==version &&
                Text(elf,offset+80,32).TrimEnd('\0')==kernel,"Recovery kernel/runtime pair mismatch");found=true;
        }
        Require(!required || found,"Missing Recovery kernel/runtime binding");
    }
    public static string KernelVersion(byte[] elf) {
        Require(elf.Length>=64 && elf[0]==127 && Text(elf,1,3)=="ELF" && elf[4]==2 && elf[5]==1 && U16(elf,18)==62,"Kernel ELF64/x86_64");
        int start=checked((int)U64(elf,40)); int count=U16(elf,60); int names=U16(elf,62);
        Require(U16(elf,58)==64 && count>0 && count<=4096 && names<count && start>=64 && start<=elf.Length-count*64,"ELF section table");
        int namesAt=checked((int)U64(elf,start+names*64+24)); int namesSize=checked((int)U64(elf,start+names*64+32));
        Require(namesAt>=0 && namesSize>0 && namesAt<=elf.Length-namesSize,"ELF section names");
        string version=null;
        for(int i=0;i<count;i++) {
            int at=start+i*64; int name=checked((int)U32(elf,at)); Require(name<namesSize,"ELF section name bounds");
            int end=Array.IndexOf(elf,(byte)0,namesAt+name,namesSize-name); Require(end>=0,"ELF unterminated name");
            if(Text(elf,namesAt+name,end-namesAt-name)!=".r4os.kernel.meta")continue;
            int meta=checked((int)U64(elf,at+24));
            Require(version==null && U64(elf,at+32)==44 && meta>=0 && meta<=elf.Length-44 && Text(elf,meta,8)=="R4OSKRN1" && U32(elf,meta+8)==1 && U32(elf,meta+12)==44,"Kernel metadata");
            version=U32(elf,meta+16)+"."+U32(elf,meta+20)+"."+U32(elf,meta+24);
            Require(Text(elf,meta+28,16).TrimEnd('\0')==version,"Kernel version text");
        }
        Require(version!=null,"Missing kernel metadata"); return version;
    }
    public void Dispose() { if(!leaveOpen)file.Dispose(); }
}

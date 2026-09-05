// Deliberately artificial acceptance images. Never used by image production.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

public static class InstallationImageFixtures {
    static uint Crc(byte[] bytes) { uint crc=uint.MaxValue; foreach(byte b in bytes){crc^=b; for(int i=0;i<8;i++)crc=(crc>>1)^((crc&1)!=0?0xedb88320u:0);}return ~crc; }
    static byte[] Read(FileStream file,long offset,int count){file.Position=offset;var bytes=new byte[count];file.ReadExactly(bytes);return bytes;}
    static void Write(FileStream file,long offset,byte[] bytes){file.Position=offset;file.Write(bytes);}
    static void Replace(FileStream file,long[] sectors,byte[] bytes){int at=0;foreach(long sector in sectors){int count=Math.Min(512,bytes.Length-at);if(count==0)break;file.Position=sector*512;file.Write(bytes,at,count);at+=count;}if(at!=bytes.Length)throw new IOException("Fixture file size changed.");}
    public static void Prepare(string path,string manifestId,string diskId,string[] partitionIds,long[] manifestSectors,byte[] manifest,long[] configSectors,byte[] config,bool reidentify,bool usb,bool damageSystem) {
        if(Path.GetExtension(path)!=".img")throw new IOException("Only a test .img is accepted.");
        using(var file=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None)) {
            if(file.Length!=2048L*1024*1024)throw new IOException("Unexpected test image size.");
            string json=Encoding.UTF8.GetString(manifest),text=Encoding.UTF8.GetString(config);
            if(reidentify) {
                var replacements=new Dictionary<string,string>();replacements.Add(manifestId,Guid.NewGuid().ToString());replacements.Add(diskId,Guid.NewGuid().ToString());
                foreach(string id in partitionIds)replacements.Add(id,Guid.NewGuid().ToString());
                foreach(var pair in replacements){json=json.Replace(pair.Key,pair.Value);text=text.Replace(pair.Key,pair.Value);}
                var entries=Read(file,1024,16384);
                for(int i=0;i<5;i++)new Guid(replacements[partitionIds[i]]).ToByteArray().CopyTo(entries,i*128+16);
                long last=file.Length/512-1;
                Write(file,1024,entries);Write(file,(last-32)*512,entries);
                foreach(long lba in new[]{1L,last}){
                    var header=Read(file,lba*512,512);new Guid(replacements[diskId]).ToByteArray().CopyTo(header,56);
                    BitConverter.GetBytes(Crc(entries)).CopyTo(header,88);Array.Clear(header,16,4);
                    BitConverter.GetBytes(Crc(header.AsSpan(0,92).ToArray())).CopyTo(header,16);Write(file,lba*512,header);
                }
            }
            if(usb){text=text.Replace("default_entry: 1\n","default_entry: 2\n");}
            var jsonBytes=Encoding.UTF8.GetBytes(json);var textBytes=Encoding.UTF8.GetBytes(text);
            if(jsonBytes.Length!=manifest.Length || textBytes.Length!=config.Length)throw new IOException("Fixture metadata length changed.");
            Replace(file,manifestSectors,jsonBytes);Replace(file,configSectors,textBytes);
            if(damageSystem){Write(file,266240L*512,new byte[512]);Write(file,(266240L+2097152-1)*512,new byte[512]);}
            file.Flush(true);
        }
    }
}

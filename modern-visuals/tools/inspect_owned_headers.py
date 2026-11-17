#!/usr/bin/env python3
"""Read BSA metadata and at most128 decompressed DDS HEADER bytes per target.
Never extracts pixel payload or writes retail bytes. Output is numeric metadata.
"""
import argparse,json,struct,zlib
from pathlib import Path

def inspect(archive,targets):
    with open(archive,'rb') as f:
        raw=f.read(36)
        if raw[:4]!=b'BSA\0':raise ValueError('not BSA')
        version,folder_offset,flags,folders,files,_,_,_=struct.unpack('<8I',raw[4:])
        if version!=104 or folders>100000 or files>1000000:raise ValueError('unsupported BSA')
        f.seek(folder_offset)
        counts=[struct.unpack('<QII',f.read(16))[1] for _ in range(folders)]
        entries=[]
        for count in counts:
            size=f.read(1)[0];name=f.read(size).rstrip(b'\0').decode('ascii').replace('\\','/').lower()
            for _ in range(count):
                _,packed,offset=struct.unpack('<QII',f.read(16));entries.append([name,packed,offset])
        for e in entries:
            name=bytearray()
            while (c:=f.read(1))!=b'\0':
                if not c or len(name)>4096:raise ValueError('invalid BSA filename')
                name+=c
            e[0]+='/'+name.decode('ascii').lower()
        index={e[0]:e for e in entries};result=[]
        for target in targets:
            _,packed,offset=index[target];compressed=bool(flags&4)^bool(packed&0x40000000)
            f.seek(offset)
            if flags&0x100:f.seek(f.read(1)[0],1) # embedded path metadata
            if compressed:
                expected=struct.unpack('<I',f.read(4))[0];decoder=zlib.decompressobj();header=b''
                while len(header)<128:
                    block=f.read(256)
                    if not block:raise ValueError('truncated compressed header')
                    header+=decoder.decompress(block,128-len(header))
            else:expected=packed&0x3fffffff;header=f.read(128)
            if len(header)!=128 or header[:4]!=b'DDS ':raise ValueError('not DDS header: '+target)
            values=struct.unpack('<31I',header[4:]);fourcc=header[84:88].decode('ascii')
            result.append({'destination':target,'width':values[3],'height':values[2], 'mips':values[6],
                'format':fourcc,'pixelFormatFlags':values[19],'rgbBitCount':values[21],
                'alphaMask':values[25],'uncompressedEntryBytes':expected,'headerBytesDecoded':128})
        return {'schema':1,'scope':'BSA metadata and DDS header numbers only; zero retail pixel payload extracted', 'bsaVersion':version,'assets':result}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    names=['dirt01','dirt02','dirtpath01','pineforest01','rocks01']
    targets=['textures/landscape/'+n+suffix+'.dds' for n in names for suffix in ('','_n')]
    report=inspect(a.archive,targets);a.out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

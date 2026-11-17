#!/usr/bin/env python3
"""Rebuild CC0-only 2K legacy-DDS terrain pack from hash-pinned official archives.
Python stdlib + ImageMagick7.1.1-47; no compiler, retail assets or account needed.
"""
import argparse,hashlib,json,math,os,re,struct,subprocess,tempfile,urllib.request,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ENV=dict(os.environ,MAGICK_THREAD_LIMIT='1',OMP_NUM_THREADS='1',LC_ALL='C')

def sha(data):return hashlib.sha256(data).hexdigest()
def json_write(path,value):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,indent=2)+'\n')
def magick(*args,input=None):
    argv=['magick',*map(str,args)] if args[0]=='-version' else (['magick','identify','-limit','thread','1',*map(str,args[1:])] if args[0]=='identify' else ['magick','-limit','thread','1',*map(str,args)])
    return subprocess.check_output(argv,input=input,env=ENV)
def layout(width,height,mips):
    return sum(max(1,width>>i)//4*max(1,height>>i)//4*8 if min(max(1,width>>i),max(1,height>>i))>=4 else 8 for i in range(mips))
def inspect_dds(path):
    data=Path(path).read_bytes()
    if len(data)<128 or data[:4]!=b'DDS ':raise ValueError('not legacy DDS: '+str(path))
    v=struct.unpack('<31I',data[4:128]);fourcc=data[84:88].decode('ascii')
    width,height,mips=v[3],v[2],v[6]
    if v[0]!=124 or v[18]!=32 or v[19]!=4 or fourcc!='DXT1' or v[27]!=0 or v[28]!=0:raise ValueError('unsupported DDS flags/layout')
    if width!=2048 or height!=2048 or mips!=12 or len(data)!=128+layout(width,height,mips):raise ValueError('unexpected DDS dimensions/mips/byte length')
    if not(v[1]&0x20000) or not(v[26]&0x400000):raise ValueError('missing mip flags')
    return {'width':width,'height':height,'mips':mips,'format':fourcc,'bytes':len(data),'sha256':sha(data)}

LINEAR=[v/255/12.92 if v/255<=.04045 else ((v/255+.055)/1.055)**2.4 for v in range(256)]
def srgb(v):return min(255,max(0,int((12.92*v if v<=.0031308 else 1.055*v**(1/2.4)-.055)*255+.5)))
def mip(raw,size,normal):
    half=max(1,size//2);out=bytearray(half*half*3)
    for y in range(half):
        row=y*2*size*3
        for x in range(half):
            p=row+x*6;q=p+size*3;o=(y*half+x)*3
            sums=[raw[p+c]+raw[p+3+c]+raw[q+c]+raw[q+3+c] for c in range(3)]
            if normal:
                v=[s/510-1 for s in sums];length=math.sqrt(sum(c*c for c in v))
                v=[c/length for c in v] if length>1e-12 else [0,0,1]
                out[o:o+3]=bytes(min(255,max(0,int((c+1)*127.5+.5))) for c in v)
            else:
                for c in range(3):out[o+c]=srgb((LINEAR[raw[p+c]]+LINEAR[raw[p+3+c]]+LINEAR[raw[q+c]]+LINEAR[raw[q+3+c]])/4)
    return bytes(out)

def archive(source,cache,download):
    path=cache/source['archiveFile']
    if not path.exists():
        if not download:raise ValueError('missing pinned archive; rerun with --download: '+str(path))
        url=source['downloadURL']
        if url!='https://ambientcg.com/get?file='+source['archiveFile']:raise ValueError('unexpected official download URL')
        request=urllib.request.Request(url,headers={'User-Agent':'SkyrimAppleTerrainBuilder/1.0','Referer':source['assetURL']})
        cache.mkdir(parents=True,exist_ok=True)
        temporary=path.with_suffix('.part')
        try:
            with urllib.request.urlopen(request,timeout=60) as r,temporary.open('wb') as f:
                total=0
                while block:=r.read(1024*1024):
                    total+=len(block)
                    if total>source['archiveBytes']:raise ValueError('download exceeds pinned byte count')
                    f.write(block)
            if temporary.stat().st_size!=source['archiveBytes'] or sha(temporary.read_bytes())!=source['archiveSHA256']:raise ValueError('archive hash mismatch')
            temporary.replace(path)
        finally:
            if temporary.exists():temporary.unlink()
    if path.stat().st_size!=source['archiveBytes'] or sha(path.read_bytes())!=source['archiveSHA256']:raise ValueError('cached archive hash mismatch')
    return path

def build(lock,cache,out,download):
    version=magick('-version').decode().splitlines()[0]
    if ('ImageMagick '+lock['encoderVersion']+' ') not in version:raise ValueError('pinned ImageMagick version required: '+lock['encoderVersion'])
    assets=[]
    for source in lock['sources']:
        if not re.fullmatch(r'Ground[0-9]+',source['id']) or not re.fullmatch(r'[a-z0-9]+',source['destinationBase']) or source['license']!='CC0-1.0':raise ValueError('unexpected source or destination')
        src=archive(source,cache,download)
        with zipfile.ZipFile(src) as z,tempfile.TemporaryDirectory(prefix='modern-terrain-mips-') as temporary:
            temporary=Path(temporary)
            for kind,info in source['maps'].items():
                if kind not in ('color','normalDX'):raise ValueError('unapproved map type')
                member=z.getinfo(info['member'])
                if member.file_size>64*1024*1024:raise ValueError('source map exceeds bound')
                data=z.read(member)
                if sha(data)!=info['sha256']:raise ValueError('source map hash mismatch')
                image=temporary/(kind+'.png');image.write_bytes(data)
                facts=magick('identify','-format','%w %h %[opaque]',image).decode().strip()
                if facts!='2048 2048 True':raise ValueError('source must be opaque native2K: '+facts)
                raw=magick(image,'-alpha','off','-depth','8','RGB:-')
                if len(raw)!=2048*2048*3:raise ValueError('unexpected decoded RGB length')
                levels=[];size=2048
                for level in range(12):
                    ppm=temporary/(kind+str(level)+'.ppm');ppm.write_bytes(f'P6\n{size} {size}\n255\n'.encode()+raw);levels.append(ppm)
                    if size>1:raw=mip(raw,size,kind=='normalDX');size=max(1,size//2)
                destination='textures/landscape/'+source['destinationBase']+('_n' if kind=='normalDX' else '')+'.dds'
                file='payload/'+destination;target=out/file;target.parent.mkdir(parents=True,exist_ok=True)
                # PPM stores raw map values. SET is a label, not a gamma transform:
                # normal XYZ and the already gamma-correct colour mips stay unchanged.
                magick(*levels,'-set','colorspace','sRGB','-alpha','off','-type','TrueColor',
                    '-define','dds:compression=dxt1','-define','dds:cluster-fit=true',
                    '-define','dds:weight-by-alpha=true','-define','dds:mipmaps=fromlist',target)
                result=inspect_dds(target)
                assets.append({'destination':destination,'file':file,**result,'license':'CC0-1.0','sourceURL':source['downloadURL'],'sourceAssetID':source['id'],
                    'sourceMap':info['member'],'sourceMapSHA256':info['sha256'],'sourceArchiveSHA256':source['archiveSHA256'],'mapType':kind})
                print(destination,result['bytes'],result['sha256'],flush=True)
    manifest={'schema':1,'id':lock['id'],'totalBytes':sum(a['bytes'] for a in assets),'assets':sorted(assets,key=lambda a:a['destination'])}
    json_write(out/'manifest.json',manifest)
    return manifest,version

def verify(out):
    manifest=json.loads((out/'manifest.json').read_text());seen=set()
    if manifest['schema']!=1 or manifest['id']!='modern-terrain-v1' or len(manifest['assets'])!=6:raise ValueError('unexpected pack')
    for asset in manifest['assets']:
        d=asset['destination']
        if not re.fullmatch(r'textures/landscape/(dirt01|dirtpath01|pineforest01)(_n)?\.dds',d) or d in seen or asset['file']!='payload/'+d:raise ValueError('unexpected/duplicate target')
        seen.add(d)
        actual=inspect_dds(out/asset['file'])
        for key in actual:
            if actual[key]!=asset[key]:raise ValueError('manifest mismatch: '+key)
        if asset['license']!='CC0-1.0' or not asset['sourceURL'].startswith('https://ambientcg.com/get?file='):raise ValueError('missing source provenance')
    if sum(a['bytes'] for a in manifest['assets'])!=manifest['totalBytes']:raise ValueError('byte cost mismatch')
    expected={a['file'] for a in manifest['assets']}
    actual={p.relative_to(out).as_posix() for p in (out/'payload').rglob('*') if p.is_file()}
    if actual!=expected:raise ValueError('unexpected payload file')
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cache',type=Path,default=ROOT/'build/sources');p.add_argument('--out',type=Path,default=ROOT/'pack');p.add_argument('--download',action='store_true');p.add_argument('--verify',action='store_true');p.add_argument('--compare-shipped',action='store_true');a=p.parse_args()
    if a.compare_shipped and a.out.resolve()==(ROOT/'pack').resolve():p.error('--compare-shipped requires a separate --out directory')
    lock=json.loads((ROOT/'sources.lock.json').read_text())
    if a.verify:result=verify(a.out);print('verified',len(result['assets']),'legacy DDS files,',result['totalBytes'],'bytes')
    else:
        result,version=build(lock,a.cache,a.out,a.download);verify(a.out)
        if a.compare_shipped and result!=json.loads((ROOT/'pack/manifest.json').read_text()):raise SystemExit('rebuild differs from committed manifest')
        print('built',len(result['assets']),'files',result['totalBytes'],'bytes',version)

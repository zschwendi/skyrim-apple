#!/usr/bin/env python3
"""Check shipped bytes, mip math and rejection of malformed DDS without compilers."""
import importlib.util,math,struct,tempfile
from pathlib import Path
p=Path(__file__).with_name('build_pack.py');spec=importlib.util.spec_from_file_location('builder',p);b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
manifest=b.verify(b.ROOT/'pack')
assert manifest['totalBytes']==16778064
assert all(a['bytes']==2796344 for a in manifest['assets'])
# Linear-light black/white averaging must not use gamma-space midpoint128.
raw=bytes([0,0,0,255,255,255,0,0,0,255,255,255])
assert b.mip(raw,2,False)==bytes([188,188,188])
# A shallow paired slope averages to an upward unit normal, not a shortened vector.
raw=bytes([255,128,255,0,128,255,128,255,255,128,0,255])
normal=b.mip(raw,2,True)
v=[c/127.5-1 for c in normal]
assert abs(math.sqrt(sum(c*c for c in v))-1)<.02
assert normal[2]==255 and abs(normal[0]-128)<=1 and abs(normal[1]-128)<=1
# Real shipped header mutation controls: BC7/DX10, missing mips and truncation.
original=(b.ROOT/'pack'/manifest['assets'][0]['file']).read_bytes()
with tempfile.TemporaryDirectory(prefix='modern-dds-controls-') as temp:
    path=Path(temp)/'bad.dds'
    for label,data in [('DX10',original[:84]+b'DX10'+original[88:]),('missing-mips',original[:28]+struct.pack('<I',1)+original[32:]),('truncated',original[:-8])]:
        path.write_bytes(data)
        try:b.inspect_dds(path)
        except ValueError:print(label+': negative control rejected')
        else:raise AssertionError(label+' was accepted')
print('PASS six shipped legacyDDS hashes/headers, bounded byte cost and gamma/vector mip math')

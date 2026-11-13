#!/usr/bin/env python3
"""Independent acceptance corpus + semantic differential tests + mutated inputs."""
import argparse, ctypes as C, json, math, os, pathlib, random, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
class Node(C.Structure):
    _fields_=[('payload',C.c_uint64),('next',C.c_uint32),('tag',C.c_uint32)]
lib=C.CDLL(os.environ.get('KILN_LIB',str(ROOT/'zig-out/lib/libkiln.so')))
lib.kiln_parse.argtypes=[C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)];lib.kiln_parse.restype=C.c_void_p
lib.kiln_free.argtypes=[C.c_void_p]
lib.kiln_nodes.argtypes=[C.c_void_p,C.POINTER(C.c_size_t)];lib.kiln_nodes.restype=C.POINTER(Node)
lib.kiln_strings.argtypes=[C.c_void_p,C.POINTER(C.c_size_t)];lib.kiln_strings.restype=C.c_void_p

def parse(data,semantic=False):
    offset=C.c_size_t();doc=lib.kiln_parse(data,len(data),C.byref(offset))
    if not doc:return False,None
    try:
        if not semantic:return True,None
        n=C.c_size_t();nodes=lib.kiln_nodes(doc,C.byref(n));s=C.c_size_t();strings=lib.kiln_strings(doc,C.byref(s))
        def value(i):
            x=nodes[i]
            assert i < x.next <= n.value
            if x.tag==0:return None
            if x.tag in (1,2):return x.tag==2
            if x.tag==3:return C.c_double.from_buffer_copy(C.c_uint64(x.payload)).value
            if x.tag==4:return C.string_at(strings+(x.payload & 0xffffffff),x.payload >> 32).decode('utf8')
            cursor=i+1
            if x.tag==5:
                a=[]
                while cursor<x.next:a.append(value(cursor));cursor=nodes[cursor].next
                assert len(a)==x.payload
                return a
            assert x.tag==6
            pairs=[]
            while cursor<x.next:
                k=value(cursor);v=value(cursor+1);pairs.append((k,v));cursor=nodes[cursor+1].next
            assert len(pairs)==x.payload
            return dict(pairs)
        return True,value(0)
    finally:lib.kiln_free(doc)

def finite_float(text):
    value=float(text)
    if not math.isfinite(value):raise ValueError('outside finite f64 policy')
    return value

def reject_constant(text):
    raise ValueError('non-JSON constant: '+text)

def reference(data):
    return json.loads(data,parse_float=finite_float,parse_constant=reject_constant)

def rand_value(r,depth=0):
    kind=r.randrange(7 if depth<5 else 5)
    if kind==0:return None
    if kind==1:return bool(r.randrange(2))
    if kind==2:return r.randint(-10**12,10**12)
    if kind==3:return r.uniform(-1e20,1e20)
    if kind==4:return ''.join(r.choice(['a','b','"','\\','\n','\x00','é','ह','🚀','\t','/']) for _ in range(r.randrange(65)))
    if kind==5:return [rand_value(r,depth+1) for _ in range(r.randrange(8))]
    return {str(i)+'🚀':rand_value(r,depth+1) for i in range(r.randrange(8))}

def normalize(x):
    if isinstance(x,(int,float)) and not isinstance(x,bool):return float(x)
    if isinstance(x,list):return [normalize(v) for v in x]
    if isinstance(x,dict):return {k:normalize(v) for k,v in x.items()}
    return x

def main():
    p=argparse.ArgumentParser();p.add_argument('--suite',type=pathlib.Path,default=ROOT/'vendor/JSONTestSuite');p.add_argument('--cases',type=int,default=10000);a=p.parse_args()
    report={};failures=[]
    if a.suite:
        counts={'must_accept':0,'must_reject':0,'implementation_defined_accept':0,'implementation_defined_reject':0}
        for f in sorted((a.suite/'test_parsing').glob('*.json')):
            ok,_=parse(f.read_bytes())
            if f.name.startswith('y_'):
                counts['must_accept']+=1
                if not ok:failures.append(f.name+' rejected')
            elif f.name.startswith('n_'):
                counts['must_reject']+=1
                if ok:failures.append(f.name+' accepted')
            else:counts['implementation_defined_accept' if ok else 'implementation_defined_reject']+=1
        report['JSONTestSuite']=counts
    r=random.Random(20261113)
    generated=0
    for i in range(a.cases):
        generated+=1
        expected=rand_value(r);data=json.dumps(expected,ensure_ascii=bool(i%2),separators=(',',':')).encode()
        ok,actual=parse(data,True)
        if not ok or normalize(expected)!=actual:failures.append(f'semantics seed case {i}');break
    report['generated_semantic_cases']=generated
    # Differential validity on ASCII mutations; avoid Python's NaN / surrogate extensions.
    seeds=[b'{"a":[1,true,null,"hello"],"b":-3.5e2}',b'[0,1,2]',b'"hello world"']
    mutations=a.cases
    mutated=0
    for i in range(mutations):
        mutated+=1
        data=bytearray(r.choice(seeds))
        for _ in range(r.randrange(1,5)):
            op=r.randrange(3);pos=r.randrange(len(data)+1)
            if op==0:data[pos:pos]=bytes([r.randrange(128)])
            elif op==1 and pos<len(data):del data[pos]
            elif pos<len(data):data[pos]=r.randrange(128)
        data=bytes(data)
        try:expected=reference(data);valid=True
        except (ValueError,UnicodeError,RecursionError):valid=False
        ok,actual=parse(data,valid)
        if ok!=valid or (valid and normalize(expected)!=actual):failures.append(f'mutation {i}: {data!r}');break
    report['mutated_differential_cases']=mutated
    # Boundary lengths exercise both sides of each vector load and all alignment offsets.
    for length in range(257):
        for suffix in ['', '\\n','\\uD83D\\uDE80','é']:
            data=('"'+'a'*length+suffix+'"').encode()
            ok,actual=parse(data,True)
            if not ok or actual!=json.loads(data):failures.append(f'vector boundary {length}')
    report['vector_boundary_cases']=257*4
    # Independent real-world inputs, not just the generated distribution.
    real=0
    for f in sorted((ROOT/'bench/data').glob('*.json')):
        data=f.read_bytes();ok,actual=parse(data,True)
        if not ok or normalize(reference(data))!=actual:failures.append('public/workload semantic mismatch: '+f.name)
        real+=1
    report['workload_semantic_cases']=real
    # Arbitrary bytes exercise rejection paths beyond ASCII mutations.
    for i in range(a.cases):
        data=r.randbytes(r.randrange(513))
        parse(data)
    report['arbitrary_byte_cases']=a.cases
    report['reference_policy']='strict JSON constants, finite f64 numbers; overflow rejected to match documented Kiln policy'
    report['failures']=failures
    print(json.dumps(report,indent=2))
    return bool(failures)
if __name__=='__main__':sys.exit(main())

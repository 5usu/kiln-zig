#!/usr/bin/env python3
"""Deterministic synthetic workloads; optional pinned public benchmark datasets."""
import argparse, hashlib, json, pathlib, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--public-source',type=pathlib.Path);p.add_argument('--fetch-public',action='store_true');a=p.parse_args()
    out=ROOT/'bench/data';out.mkdir(parents=True,exist_ok=True)
    workloads={
      'telemetry': [{'frame':i,'timestamp':round(i/30,6),'position':[round(i*.001,6),-0.125,1.75],'rotation':[0,0,0,1],'gripper':bool(i%2),'label':'pick_and_place','valid':True} for i in range(2500)],
      'integers':list(range(-25000,25000)),
      'strings':[f'frame-{i:06d}-'+'abcdefghijklmnopqrstuvwxyz0123456789'*3 for i in range(5000)],
      'escaped':[{'text':'Robot says "hello"\nC:\\frames\\new\tहाय 🚀','id':i} for i in range(3000)],
    }
    previous=json.loads((ROOT/'bench/datasets.json').read_text()) if (ROOT/'bench/datasets.json').exists() else []
    manifest=[]
    for name,value in workloads.items():
        data=json.dumps(value,ensure_ascii=True,separators=(',',':')).encode();(out/(name+'.json')).write_bytes(data)
        manifest.append({'file':name+'.json','kind':'synthetic','generator':'scripts/datasets.py','sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
    if a.public_source:
        import subprocess
        commit=subprocess.check_output(['git','-C',str(a.public_source),'rev-parse','HEAD'],text=True).strip()
        for name in ['twitter','canada','citm_catalog']:
            data=(a.public_source/'data'/(name+'.json')).read_bytes();(out/(name+'.json')).write_bytes(data)
            manifest.append({'file':name+'.json','kind':'public','source':f'https://github.com/miloyip/nativejson-benchmark/blob/{commit}/data/{name}.json','sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
    elif a.fetch_public:
        public=[entry for entry in previous if entry['kind']=='public']
        if not public:raise SystemExit('Pinned public dataset manifest is missing')
        for entry in public:
            url=entry['source'].replace('https://github.com/','https://raw.githubusercontent.com/').replace('/blob/','/')
            existing=out/entry['file']
            data=existing.read_bytes() if existing.exists() and hashlib.sha256(existing.read_bytes()).hexdigest()==entry['sha256'] else urllib.request.urlopen(url,timeout=60).read()
            if hashlib.sha256(data).hexdigest()!=entry['sha256']:raise SystemExit('Dataset checksum mismatch: '+entry['file'])
            (out/entry['file']).write_bytes(data);manifest.append(entry)
    else:
        manifest.extend(entry for entry in previous if entry['kind']=='public')
    (ROOT/'bench/datasets.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Available datasets:',sum((out/entry['file']).exists() for entry in manifest),'of',len(manifest),'manifest entries')
if __name__=='__main__':main()

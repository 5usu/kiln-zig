#!/usr/bin/env python3
"""Single-core, interleaved, repeated wall-clock benchmark. No timing instrumentation."""
import argparse, datetime, hashlib, json, os, pathlib, platform, random, statistics, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--samples',type=int,default=11);p.add_argument('--duration-ms',type=int,default=250);p.add_argument('--cpu',type=int,default=0);p.add_argument('--output',type=pathlib.Path,default=ROOT/'bench/results.json');p.add_argument('--baseline-lib',type=pathlib.Path);p.add_argument('--datasets',nargs='*');a=p.parse_args()
    os.environ['KILN_BENCH_MS']=str(a.duration_ms)
    if a.samples<3:p.error('use at least 3 samples')
    data=sorted((ROOT/'bench/data').glob('*.json'))
    if a.datasets:data=[f for f in data if f.stem in a.datasets]
    if not data:p.error('generate datasets first with scripts/datasets.py')
    if hasattr(os,'sched_setaffinity'):os.sched_setaffinity(0,{a.cpu})
    def read(path):
        try:return pathlib.Path(path).read_text().strip()
        except OSError:return None
    def command(args):return subprocess.check_output(args,text=True).strip()
    zig=os.environ.get('ZIG',str(ROOT/'scripts/zig'))
    metadata={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'platform':platform.platform(),'cpu':command(['lscpu']),'pinned_logical_cpu':a.cpu,'governor':read(f'/sys/devices/system/cpu/cpu{a.cpu}/cpufreq/scaling_governor'),'power_supplies':{p.name:read(p/'online') for p in pathlib.Path('/sys/class/power_supply').glob('*') if (p/'online').exists()},'zig':command([zig,'version']),'c_compiler':command([os.environ.get('CC',zig),*(['cc'] if 'CC' not in os.environ else []),'--version']),'vendor_commits':json.loads((ROOT/'vendor/versions.json').read_text()),'timing':'CLOCK_MONOTONIC; warmup 8; each sample calibrated to ~configured duration; parse includes free; traverse includes full decoded strings and free','flags':{'zig':'ReleaseFast -Dcpu=native','c':'-O3 -march=native; no LTO'},'sample_target_ms':a.duration_ms,'samples_per_case':a.samples,'dataset_sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in data}}
    sources=['build.zig','bench/benchmark.c','scripts/build.sh','src/kiln.h']+[str(p.relative_to(ROOT)) for p in sorted((ROOT/'src').rglob('*.zig'))]
    metadata['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources}
    libraries=['kiln','cjson','yyjson']
    if a.baseline_lib:
        a.baseline_lib=a.baseline_lib.resolve()
        metadata['baseline_library_sha256']=hashlib.sha256((a.baseline_lib/'libkiln.so').read_bytes()).hexdigest()
        metadata['baseline_source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'bench/baseline/src').glob('*.zig'))}
        libraries.append('kiln_v1')
    rows=[];r=random.Random(20261113)
    jobs=[(f,lib,mode) for f in data for lib in libraries for mode in ['parse','traverse']]
    for sample in range(a.samples):
        r.shuffle(jobs)
        for f,lib,mode in jobs:
            env=os.environ.copy()
            if lib=='kiln_v1':env['LD_LIBRARY_PATH']=str(a.baseline_lib)
            row=json.loads(subprocess.check_output([str(ROOT/'bench/bin/benchmark'),str(f),'kiln' if lib=='kiln_v1' else lib,mode],text=True,env=env));row.update(library=lib,dataset=f.stem,sample=sample);rows.append(row)
        print(f'Sample {sample+1}/{a.samples} complete',flush=True)
    metadata['power_supplies_end']={p.name:read(p/'online') for p in pathlib.Path('/sys/class/power_supply').glob('*') if (p/'online').exists()}
    metadata['governor_end']=read(f'/sys/devices/system/cpu/cpu{a.cpu}/cpufreq/scaling_governor')
    checks={}
    for row in rows:
        previous=checks.setdefault(row['dataset'],row['checksum'])
        if row['checksum']!=previous:raise RuntimeError(f"cross-library semantic checksum mismatch: {row['dataset']} {row['library']}")
    summary=[]
    for f in data:
        for mode in ['parse','traverse']:
            for lib in libraries:
                group=[x for x in rows if x['dataset']==f.stem and x['mode']==mode and x['library']==lib]
                times=[x['ns_per_op'] for x in group];median=statistics.median(times)
                summary.append({'dataset':f.stem,'library':lib,'mode':mode,'bytes':group[0]['bytes'],'median_ns':median,'min_ns':min(times),'max_ns':max(times),'cv_percent':100*statistics.stdev(times)/statistics.mean(times),'mb_per_s':group[0]['bytes']*1000/median,'live_bytes':group[0]['live_bytes'],'peak_bytes':group[0]['peak_bytes'],'allocation_calls':group[0]['allocation_calls'],'checksum':group[0]['checksum']})
    result={'metadata':metadata,'summary':summary,'raw_samples':rows}
    a.output.write_text(json.dumps(result,indent=2)+'\n')
    for f in data:
        group={x['library']:x for x in summary if x['dataset']==f.stem and x['mode']=='parse'}
        k,c,y=[group[l] for l in ['kiln','cjson','yyjson']]
        print(f"{f.stem}: Kiln {k['mb_per_s']:.1f} MB/s | cJSON {c['mb_per_s']:.1f} | yyjson {y['mb_per_s']:.1f} | {c['median_ns']/k['median_ns']:.2f}x cJSON | {y['median_ns']/k['median_ns']:.2f}x yyjson | memory {100*(1-k['live_bytes']/c['live_bytes']):.1f}% less vs cJSON")
    print('Saved',a.output)
if __name__=='__main__':main()

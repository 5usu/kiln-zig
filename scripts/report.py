#!/usr/bin/env python3
"""Charts, confidence intervals, and prose generated from measured samples."""
import json, math, pathlib, random, statistics
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
ROOT=pathlib.Path(__file__).resolve().parents[1]
r=json.loads((ROOT/'bench/results.json').read_text());meta=r['metadata']
rows={(x['dataset'],x['library'],x['mode']):x for x in r['summary']}
names=['canada','citm_catalog','twitter','telemetry','integers','strings','escaped']
labels=['Canada · public','CITM catalog · public','Twitter · public','Robot telemetry · generated','Integers · generated','ASCII strings · generated','Escaped strings · generated']
libs=['kiln','cjson','yyjson'];display={'kiln':'Kiln / Zig','cjson':'cJSON / C','yyjson':'yyjson / C'}
colors={'kiln':'#d76529','cjson':'#828b94','yyjson':'#273846'}
plt.rcParams.update({'font.family':'DejaVu Sans','font.size':13,'axes.spines.top':False,'axes.spines.right':False,'axes.spines.left':False,'axes.edgecolor':'#c5c9cb','text.color':'#172b39','axes.labelcolor':'#172b39','xtick.color':'#485560','ytick.color':'#172b39','figure.facecolor':'#fbfaf7','axes.facecolor':'#fbfaf7','svg.fonttype':'none'})
power='AC' if any(v=='1' for v in meta['power_supplies'].values()) else 'battery'
ratios=[rows[(n,'cjson','parse')]['median_ns']/rows[(n,'kiln','parse')]['median_ns'] for n in names]
gmean=math.exp(statistics.mean(map(math.log,ratios)))
wins=[n for n in names if rows[(n,'kiln','parse')]['median_ns']<rows[(n,'yyjson','parse')]['median_ns']]

# Resample complete sample-round blocks, preserving the association of interleaved runs.
random_=random.Random(20261114)
comparisons=[]
for mode in ['parse','traverse']:
    for name in names:
        for reference in ['yyjson','cjson','kiln_v1']:
            if (name,reference,mode) not in rows:continue
            a={x['sample']:x['ns_per_op'] for x in r['raw_samples'] if x['dataset']==name and x['library']=='kiln' and x['mode']==mode}
            b={x['sample']:x['ns_per_op'] for x in r['raw_samples'] if x['dataset']==name and x['library']==reference and x['mode']==mode}
            samples=sorted(a.keys() & b.keys());boot=[]
            for _ in range(5000):
                chosen=random_.choices(samples,k=len(samples))
                boot.append(statistics.median(b[i] for i in chosen)/statistics.median(a[i] for i in chosen))
            boot.sort();ratio=rows[(name,reference,mode)]['median_ns']/rows[(name,'kiln',mode)]['median_ns']
            comparisons.append({'dataset':name,'mode':mode,'reference':reference,'throughput_ratio':ratio,'bootstrap_95_low':boot[125],'bootstrap_95_high':boot[4874]})
(ROOT/'bench/comparisons.json').write_text(json.dumps({'method':'5000 paired sample-round bootstrap resamples; ratio of median times; deterministic seed; intervals describe within-run sampling variation only','comparisons':comparisons},indent=2)+'\n')
comparison={(x['dataset'],x['reference'],x['mode']):x for x in comparisons}

def footer(fig, last):
    fig.text(.055,.065,f'Source: bench/results.json · {meta["utc"][:10]} UTC · Intel i3-1305U · logical CPU {meta["pinned_logical_cpu"]} · {power} / {meta["governor"]}',fontsize=10,color='#52616b')
    fig.text(.055,.043,f'Median of {meta["samples_per_case"]} interleaved samples · owned DOMs · free included · Zig 0.15.2 / zig cc · native CPU',fontsize=10,color='#52616b')
    fig.text(.055,.021,last,fontsize=10,color='#52616b')

for metric in ['throughput','memory']:
    fig,ax=plt.subplots(figsize=(14,10),dpi=160)
    fig.subplots_adjust(left=.25,right=.95,top=.78,bottom=.18)
    fig.text(.055,.94,'KILN JSON',fontsize=15,fontweight='bold',color=colors['kiln'])
    if metric=='throughput':
        fig.text(.055,.888,'A native Zig parser. 16-byte nodes.',fontsize=27,fontweight='bold')
        fig.text(.055,.84,f'{gmean:.2f}× cJSON geometric mean throughput; ahead of yyjson on {len(wins)} of these seven workloads.',fontsize=14)
    else:
        fig.text(.055,.888,'One storage allocation. Owned strings.',fontsize=27,fontweight='bold')
        fig.text(.055,.84,'Live requested heap includes reserved capacity and the C API document wrapper.',fontsize=15)
    y=np.arange(len(names));height=.23
    for j,lib in enumerate(libs):
        vals=[rows[(n,lib,'parse')]['mb_per_s'] if metric=='throughput' else rows[(n,lib,'parse')]['live_bytes']/1e6 for n in names]
        offset=y+(j-1)*height
        if metric=='throughput':
            low=[rows[(n,lib,'parse')]['bytes']*1000/rows[(n,lib,'parse')]['max_ns'] for n in names]
            high=[rows[(n,lib,'parse')]['bytes']*1000/rows[(n,lib,'parse')]['min_ns'] for n in names]
            errors=np.array([[v-l for v,l in zip(vals,low)],[h-v for h,v in zip(high,vals)]])
        else:errors=None
        bars=ax.barh(offset,vals,height=height*.85,label=display[lib],color=colors[lib],xerr=errors,error_kw={'elinewidth':.7,'capsize':2,'ecolor':'#687780'},zorder=3)
        for bar,value in zip(bars,vals):ax.text(value+.012*max(vals),bar.get_y()+bar.get_height()/2,f'{value:,.0f}' if metric=='throughput' else f'{value:.2f}',va='center',fontsize=9,color=colors[lib])
    ax.set_yticks(y,labels);ax.invert_yaxis();ax.tick_params(axis='y',length=0,pad=12)
    ax.set_xlabel('Parse + free throughput (MB/s, decimal; higher is better)' if metric=='throughput' else 'Live allocator-requested memory after parsing (MB, decimal; lower is better)',labelpad=14)
    ax.grid(axis='x',color='#e2e4e2',linewidth=.7,zorder=0);ax.set_axisbelow(True);ax.set_xlim(0,ax.get_xlim()[1]*1.12)
    ax.legend(loc='lower left',bbox_to_anchor=(0,1.005),ncol=3,frameon=False,fontsize=12)
    footer(fig,'Whiskers show observed sample min–max. These results compare parser designs, not language superiority.' if metric=='throughput' else 'Requested bytes exclude allocator bookkeeping, fragmentation, and shared input. These are not RSS measurements.')
    file='benchmark' if metric=='throughput' else 'memory'
    fig.savefig(ROOT/f'bench/{file}.png',dpi=160);fig.savefig(ROOT/f'bench/{file}.svg');plt.close(fig)

fig,ax=plt.subplots(figsize=(14,8),dpi=160)
fig.subplots_adjust(left=.26,right=.94,top=.74,bottom=.23)
fig.text(.055,.93,'KILN vs yyjson',fontsize=15,fontweight='bold',color=colors['kiln'])
fig.text(.055,.858,f'Ahead on {len(wins)} workloads. All seven shown.',fontsize=26,fontweight='bold')
fig.text(.055,.796,'Native Zig · owned JSON DOM · 16-byte nodes · parse and free included',fontsize=15)
for i,name in enumerate(names):
    c=comparison[(name,'yyjson','parse')];value=c['throughput_ratio'];lo=c['bootstrap_95_low'];hi=c['bootstrap_95_high']
    color=colors['kiln'] if lo>1 else colors['cjson']
    ax.barh(i,value,height=.58,color=color,xerr=[[max(0,value-lo)],[max(0,hi-value)]],error_kw={'capsize':3,'elinewidth':1,'ecolor':colors['yyjson']},zorder=3)
    ax.text(max(value,hi)+.07 if lo>1 else 1.06,i,f'{value:.2f}×',va='center',fontsize=14,fontweight='bold',color=color)
ax.axvline(1,color=colors['yyjson'],linewidth=1.2,zorder=4)
ax.set_yticks(range(len(names)),labels);ax.invert_yaxis();ax.tick_params(axis='y',length=0,pad=12)
ax.set_xlabel('Kiln throughput ÷ yyjson throughput (×; above 1 favors Kiln)',labelpad=12)
ax.set_xlim(0,max(comparison[(n,'yyjson','parse')]['bootstrap_95_high'] for n in names)*1.22)
ax.grid(axis='x',color='#e2e4e2',linewidth=.7,zorder=0);ax.set_axisbelow(True)
footer(fig,'Whiskers: paired sample-round bootstrap 95% intervals. They reflect this run’s variation, not other systems.')
fig.savefig(ROOT/'bench/versus-yyjson.png',dpi=160);fig.savefig(ROOT/'bench/versus-yyjson.svg');plt.close(fig)

out=['# Measured results','',f"Measured {meta['utc']} on an Intel Core i3-1305U laptop with about 8 GB RAM. All benchmark processes were pinned to logical CPU {meta['pinned_logical_cpu']} (a performance-core hardware thread), using {power} power and the existing {meta['governor']} governor. Background desktop activity and laptop power management can affect results.",'',f"Each case has {meta['samples_per_case']} randomized, interleaved samples, with warmup and a nominal {meta['sample_target_ms']} ms timed interval per sample. Throughput is decimal MB/s. The actual durations and all raw samples are in `bench/results.json`.",'',f'**Kiln achieved {min(ratios):.2f}–{max(ratios):.2f}× cJSON parse + free throughput on these seven workloads ({gmean:.2f}× equally weighted geometric mean). It was ahead of yyjson on {len(wins)} workloads and behind on {7-len(wins)}.**','', '![Throughput relative to yyjson](bench/versus-yyjson.png)','']
for n,label in zip(names,labels):
    k,c,y=[rows[(n,l,'parse')] for l in libs];ci=comparison[(n,'yyjson','parse')]
    memory_y=100*(1-k['live_bytes']/y['live_bytes'])
    out.append(f"- **{label}:** Kiln {k['mb_per_s']:.1f} MB/s; cJSON {c['mb_per_s']:.1f}; yyjson {y['mb_per_s']:.1f}. Kiln/yyjson **{ci['throughput_ratio']:.2f}×** (bootstrap 95% interval {ci['bootstrap_95_low']:.2f}–{ci['bootstrap_95_high']:.2f}×). Live requested heap is {abs(memory_y):.1f}% {'lower' if memory_y>=0 else 'higher'} than yyjson.")
out+=['','![Absolute throughput](bench/benchmark.png)','','## Memory and allocation trade-off','','![Live requested allocation size](bench/memory.png)','','Kiln now allocates one storage block for nodes and source-sized string capacity. The C API also allocates its small document wrapper: two allocations per parse in total. Capacity is retained until freeing the document; it is not shrunk after parsing. This trades some retained memory for less allocation work and fewer system calls.','', 'Live memory is total requested allocation size after parsing, including the wrapper and unused capacity. The original input is shared and excluded. Peak figures and allocation-call counts are recorded too. Instrumentation runs separately from timing; figures exclude allocator bookkeeping and fragmentation and are not RSS measurements.','']
for n in names:
    k,c,y=[rows[(n,l,'parse')] for l in libs]
    out.append(f"- `{n}` live requested MB: Kiln {k['live_bytes']/1e6:.3f}; cJSON {c['live_bytes']/1e6:.3f}; yyjson {y['live_bytes']/1e6:.3f}. Kiln allocation calls: {k['allocation_calls']}.")
if (names[0],'kiln_v1','parse') in rows:
    out+=['','## Compared with original Kiln under the same conditions','','The original parser was recompiled with the same compiler and interleaved in this run as `kiln_v1`. Its source is preserved in `bench/baseline/src/`. These comparisons use the fresh measurements, not the older battery-powered run.','']
    for n in names:
        ci=comparison[(n,'kiln_v1','parse')];old=rows[(n,'kiln_v1','parse')];new=rows[(n,'kiln','parse')]
        out.append(f"- `{n}`: {ci['throughput_ratio']:.2f}× original Kiln throughput (bootstrap 95% interval {ci['bootstrap_95_low']:.2f}–{ci['bootstrap_95_high']:.2f}×); live requested bytes {old['live_bytes']:,} → {new['live_bytes']:,}.")
out+=['','## Parse plus traversal','','This mode visits every node and decoded string byte, folds f64 values into a checksum, and frees the document. Checksums match for every library on every dataset. Kiln uses a contiguous preorder traversal; cJSON and yyjson use recursive iteration. The mode measures those traversal implementations as well as parsing.','']
for n in names:
    k,c,y=[rows[(n,l,'traverse')] for l in libs]
    out.append(f"- `{n}`: Kiln {k['mb_per_s']:.1f} MB/s; cJSON {c['mb_per_s']:.1f}; yyjson {y['mb_per_s']:.1f}; Kiln/yyjson {y['median_ns']/k['median_ns']:.2f}×.")
cv=[x['cv_percent'] for x in r['summary']]
out+=['','## Reproduction and boundaries','',f"- Observed timing coefficient of variation across all cases: {min(cv):.1f}–{max(cv):.1f}%. Min/max samples are retained; the absolute-throughput chart shows their range.",'- Ratio intervals use 5,000 deterministic paired sample-round bootstrap resamples. They describe sampling variation within this run, not systematic bias or performance on other systems. Details and derived values are in `bench/comparisons.json`.','- Zig: ReleaseFast, native CPU target. C: zig cc, `-O3 -march=native`, no LTO. Exact compiler output, source fingerprints, and dependency revisions are in the raw metadata.','- All implementations use fresh owning-document APIs and own their decoded strings. Kiln includes strict UTF-8 and grammar validation; cJSON does not offer equivalent strict UTF-8 validation.','- Timed work includes allocation, parsing, and destruction. It excludes file reads and process startup. No reusable arena, pooled cJSON allocator, or in-situ yyjson mode is used.','- Kiln reuses the MIT-licensed Eisel–Lemire converter from Zig 0.15.2, supplying the mantissa and exponent already scanned. Ambiguous cases and numbers exceeding 19 digits retain the standard float-parser fallback. Attribution is in `src/float/ORIGIN.md`.','- This compares algorithms, allocation patterns, and data layouts. It does not establish that Zig is intrinsically faster than C. cJSON and yyjson provide capabilities absent from this read-only parser.','- Generated workloads are labeled. Public source URLs and hashes are in `bench/datasets.json`.','- Kiln stores numbers as f64. Other implementations may preserve integer types; checksums convert all numbers to f64.','', 'Run the commands in README.md to reproduce. Results depend on CPU, compiler, power state, and workload.','']
(ROOT/'BENCHMARKS.md').write_text('\n'.join(out))
public_wins=[n for n in names[:3] if comparison[(n,'yyjson','parse')]['bootstrap_95_low']>1]
if public_wins:
    best=max(public_wins,key=lambda n:comparison[(n,'yyjson','parse')]['throughput_ratio']);ratio=comparison[(best,'yyjson','parse')]['throughput_ratio']
    post=f"Took Kiln, my native Zig JSON parser, further.\n\nOn my i3 laptop: {ratio:.2f}× yyjson throughput on public {best}.json. Owned strings, parse + free included.\n\nAhead on {len(wins)}/7 workloads; yyjson wins the rest. Source, tests and every benchmark sample included."
else:
    post=f"Took Kiln, my native Zig JSON parser, further.\n\n16-byte nodes, one storage allocation, exact float conversion. Ahead of yyjson on {len(wins)}/7 measured workloads; all seven comparisons are included with tests and raw samples."
(ROOT/'docs/POST.md').write_text('# Draft post\n\n'+post+'\n\n## Evidence and follow-up notes\n\nThe main result is workload-specific. Use bench/versus-yyjson.png when posting so all wins and losses remain visible. The same-condition original-parser comparison is in BENCHMARKS.md.\n\nA conservative SIMD punctuation count bounds node capacity. ASCII scanning and copying are fused; hot ASCII parsing is separated from escape/Unicode handling. Numbers are scanned once and use a credited Zig standard-library conversion helper. The owned DOM occupies one reserved storage block, which is retained until free.\n\nDo not describe this as a general win over yyjson, or reuse the original 75%-less-memory claim: the allocation layout and measurements have changed.\n')
print(f'Rendered charts and report. Ahead of yyjson: {wins}; cJSON geometric mean: {gmean:.2f}x; draft length: {len(post)}.')

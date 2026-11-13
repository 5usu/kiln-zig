#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <stddef.h>
#include <inttypes.h>
#include "../src/kiln.h"
#include "../vendor/cJSON/cJSON.h"
#include "../vendor/yyjson/yyjson.h"

static uint64_t mix(uint64_t h, uint64_t x) { return (h ^ x) * UINT64_C(1099511628211); }
static uint64_t text(uint64_t h, const char *s, size_t len) {
    h = mix(h, KILN_STRING);
    for (size_t i=0;i<len;i++) h = mix(h, (unsigned char)s[i]);
    return h;
}
static uint64_t cjson_hash(const cJSON *n, uint64_t h) {
    if (cJSON_IsNull(n)) return mix(h,KILN_NULL);
    if (cJSON_IsBool(n)) return mix(h,cJSON_IsTrue(n)?KILN_TRUE:KILN_FALSE);
    if (cJSON_IsNumber(n)) { uint64_t bits; memcpy(&bits,&n->valuedouble,8); return mix(mix(h,KILN_NUMBER),bits); }
    if (cJSON_IsString(n)) return text(h,n->valuestring,strlen(n->valuestring));
    int object=cJSON_IsObject(n);
    h=mix(h,object?KILN_OBJECT:KILN_ARRAY);
    for (const cJSON *c=n->child;c;c=c->next) {
        if (object) h=text(h,c->string,strlen(c->string));
        h=cjson_hash(c,h);
    }
    return h;
}
static uint64_t yyjson_hash(yyjson_val *n, uint64_t h) {
    if (yyjson_is_null(n)) return mix(h,KILN_NULL);
    if (yyjson_is_bool(n)) return mix(h,yyjson_get_bool(n)?KILN_TRUE:KILN_FALSE);
    if (yyjson_is_num(n)) { double d=yyjson_get_num(n); uint64_t bits; memcpy(&bits,&d,8); return mix(mix(h,KILN_NUMBER),bits); }
    if (yyjson_is_str(n)) return text(h,yyjson_get_str(n),yyjson_get_len(n));
    if (yyjson_is_arr(n)) {
        h=mix(h,KILN_ARRAY); size_t i,max; yyjson_val *v;
        yyjson_arr_foreach(n,i,max,v) h=yyjson_hash(v,h);
    } else {
        h=mix(h,KILN_OBJECT); size_t i,max; yyjson_val *k,*v;
        yyjson_obj_foreach(n,i,max,k,v) { h=text(h,yyjson_get_str(k),yyjson_get_len(k)); h=yyjson_hash(v,h); }
    }
    return h;
}
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec; }
static void fail(const char *s) { fprintf(stderr,"%s\n",s); exit(1); }
static volatile uint64_t sink;
static char *input; static size_t input_len;
static uint64_t kiln_once(int traverse) {
    kiln_document *doc=kiln_parse((uint8_t *)input,input_len,NULL); if (!doc) fail("Kiln rejected input");
    uint64_t h=traverse?kiln_checksum(doc):1; kiln_free(doc); return h;
}
static uint64_t cjson_once(int traverse) {
    const char *end=NULL;
    cJSON *doc=cJSON_ParseWithLengthOpts(input,input_len+1,&end,1); if (!doc) fail("cJSON rejected input");
    uint64_t h=traverse?cjson_hash(doc,UINT64_C(14695981039346656037)):1; cJSON_Delete(doc); return h;
}
static uint64_t yyjson_once(int traverse) {
    yyjson_doc *doc=yyjson_read(input,input_len,0); if (!doc) fail("yyjson rejected input");
    uint64_t h=traverse?yyjson_hash(yyjson_doc_get_root(doc),UINT64_C(14695981039346656037)):1; yyjson_doc_free(doc); return h;
}

/* Count requested bytes separately, so instrumentation does not affect timings. */
typedef union { struct { size_t size; } s; max_align_t alignment; } Header;
static size_t live,peak,calls;
static void *tracked_malloc(size_t n) {
    if (n>SIZE_MAX-sizeof(Header)) return NULL;
    Header *p=malloc(sizeof(Header)+n); if (!p) return NULL; p->s.size=n;
    live+=n; if (live>peak) peak=live; calls++; return p+1;
}
static void tracked_free(void *p) { if (p) { Header *h=(Header *)p-1; live-=h->s.size; free(h); } }
static void *ymalloc(void *ctx,size_t n) { (void)ctx; return tracked_malloc(n); }
static void yfree(void *ctx,void *p) { (void)ctx; tracked_free(p); }
static void *yrealloc(void *ctx,void *p,size_t old,size_t n) {
    (void)ctx; (void)old;
    if (!p) return tracked_malloc(n);
    if (!n) { tracked_free(p); return NULL; }
    Header *h=(Header *)p-1; size_t previous=h->s.size;
    if (n>SIZE_MAX-sizeof(Header)) return NULL;
    Header *q=realloc(h,sizeof(Header)+n); if (!q) return NULL;
    q->s.size=n; live=live-previous+n; if (live>peak) peak=live; calls++; return q+1;
}
static kiln_memory_stats measure(const char *name) {
    kiln_memory_stats out={0}; live=peak=calls=0;
    if (!strcmp(name,"kiln")) { if (!kiln_measure((uint8_t*)input,input_len,&out)) fail("memory parse failed"); return out; }
    if (!strcmp(name,"cjson")) {
        cJSON_Hooks hooks={tracked_malloc,tracked_free}; cJSON_InitHooks(&hooks);
        cJSON *doc=cJSON_ParseWithLengthOpts(input,input_len+1,NULL,1); if (!doc) fail("memory parse failed");
        out=(kiln_memory_stats){live,peak,calls}; cJSON_Delete(doc); cJSON_InitHooks(NULL);
    } else {
        yyjson_alc alc={ymalloc,yrealloc,yfree,NULL};
        yyjson_doc *doc=yyjson_read_opts(input,input_len,0,&alc,NULL); if (!doc) fail("memory parse failed");
        out=(kiln_memory_stats){live,peak,calls}; yyjson_doc_free(doc);
    }
    if (live) fail("memory not released");
    return out;
}
int main(int argc,char **argv) {
    if (argc<4) fail("usage: benchmark FILE kiln|cjson|yyjson parse|traverse [ITERATIONS]");
    FILE *f=fopen(argv[1],"rb"); if (!f) fail("cannot open dataset");
    if (fseek(f,0,SEEK_END)) fail("cannot seek dataset");
    long size=ftell(f); if (size<0) fail("cannot size dataset"); rewind(f); input_len=(size_t)size;
    input=malloc(input_len+1); if (!input) fail("out of memory");
    if (fread(input,1,input_len,f)!=input_len) fail("cannot read dataset"); fclose(f); input[input_len]=0;
    uint64_t (*once)(int)=NULL;
    if (!strcmp(argv[2],"kiln")) once=kiln_once;
    if (!strcmp(argv[2],"cjson")) once=cjson_once;
    if (!strcmp(argv[2],"yyjson")) once=yyjson_once;
    if (!once) fail("unknown library");
    int traverse=!strcmp(argv[3],"traverse");
    if (!traverse && strcmp(argv[3],"parse")) fail("unknown mode");
    uint64_t check=once(1);
    for (int i=0;i<8;i++) sink=once(traverse);
    size_t iterations=argc>4?strtoull(argv[4],NULL,10):0;
    if (!iterations) {
        size_t pilot=1; uint64_t elapsed;
        do { uint64_t start=now_ns(); for (size_t i=0;i<pilot;i++) sink=once(traverse); elapsed=now_ns()-start; if(elapsed<20000000) pilot*=2; } while(elapsed<20000000);
        const char *duration_env=getenv("KILN_BENCH_MS");
        double duration_ms=duration_env?strtod(duration_env,NULL):250.0;
        if (duration_ms<1 || duration_ms>5000) fail("KILN_BENCH_MS must be between 1 and 5000");
        iterations=(size_t)((double)pilot*duration_ms*1000000.0/(double)elapsed); if (!iterations) iterations=1;
    }
    uint64_t start=now_ns(); for (size_t i=0;i<iterations;i++) sink=once(traverse); uint64_t elapsed=now_ns()-start;
    kiln_memory_stats stats=measure(argv[2]);
    printf("{\"library\":\"%s\",\"mode\":\"%s\",\"bytes\":%zu,\"iterations\":%zu,\"elapsed_ns\":%" PRIu64 ",\"ns_per_op\":%.3f,\"mb_per_s\":%.3f,\"checksum\":\"%016" PRIx64 "\",\"live_bytes\":%zu,\"peak_bytes\":%zu,\"allocation_calls\":%zu}\n",argv[2],argv[3],input_len,iterations,elapsed,(double)elapsed/iterations,(double)input_len*iterations*1000.0/elapsed,check,stats.live_bytes,stats.peak_bytes,stats.allocation_calls);
    free(input); return 0;
}

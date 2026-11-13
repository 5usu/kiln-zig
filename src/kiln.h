#ifndef KILN_JSON_H
#define KILN_JSON_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Owned read-only DOM. Input is borrowed only during kiln_parse(). */
typedef struct kiln_document kiln_document;
typedef enum { KILN_NULL, KILN_FALSE, KILN_TRUE, KILN_NUMBER, KILN_STRING, KILN_ARRAY, KILN_OBJECT } kiln_tag;
typedef struct { uint64_t payload; uint32_t next; kiln_tag tag; } kiln_node;
typedef struct { size_t live_bytes, peak_bytes, allocation_calls; } kiln_memory_stats;
kiln_document *kiln_parse(const uint8_t *data, size_t len, size_t *error_offset);
void kiln_free(kiln_document *doc);
uint64_t kiln_checksum(const kiln_document *doc);
size_t kiln_capacity(const kiln_document *doc);
const kiln_node *kiln_nodes(const kiln_document *doc, size_t *len);
const uint8_t *kiln_strings(const kiln_document *doc, size_t *len);
bool kiln_measure(const uint8_t *data, size_t len, kiln_memory_stats *result);
#ifdef __cplusplus
}
#endif
#endif

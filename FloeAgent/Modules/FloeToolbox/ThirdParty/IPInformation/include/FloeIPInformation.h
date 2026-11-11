#ifndef FLOE_IP_INFORMATION_H
#define FLOE_IP_INFORMATION_H
#include <stdint.h>
#include <stddef.h>
typedef struct FloeIPDatabase FloeIPDatabase;
typedef struct {
    char type[128];
    uint64_t build_epoch;
    uint16_t ip_version;
} FloeIPDatabaseMetadata;
typedef struct {
    int found;
    int has_asn;
    uint32_t asn;
    uint16_t prefix_length;
    char country_code[8];
    char country[512];
    char region[512];
    char city[512];
    char organization[512];
} FloeIPDatabaseRecord;
// kind1=City, kind2=ASN. Errors never contain the caller's file path.
FloeIPDatabase *floe_ip_open(const char *path, int kind, uint64_t maximum_bytes,
                           FloeIPDatabaseMetadata *metadata, int *error);
int floe_ip_lookup(FloeIPDatabase *database, const char *numeric_address,
                   const char *language, FloeIPDatabaseRecord *record);
void floe_ip_close(FloeIPDatabase *database);
int floe_ip_validate(FloeIPDatabase *database, int (*cancelled)(void *), void *context);
// CRC-checked streaming gzip, exclusive destination, bounded expanded bytes.
// 0success, -1input/IO, -2format/CRC, -3limit, -4cancelled.
int floe_ip_expand_gzip(const char *source, const char *destination,
                        uint64_t maximum_bytes, int (*cancelled)(void *), void *context);
#endif

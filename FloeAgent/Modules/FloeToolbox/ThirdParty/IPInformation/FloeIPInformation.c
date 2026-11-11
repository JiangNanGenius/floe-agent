// SPDX-License-Identifier: MPL-2.0
#include "FloeIPInformation.h"
#include "maxminddb.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

struct FloeIPDatabase { MMDB_s reader; int kind; };

FloeIPDatabase *floe_ip_open(const char *path, int kind, uint64_t maximum_bytes,
                           FloeIPDatabaseMetadata *metadata, int *error) {
    if (error) *error = -1;
    if (!path || !metadata || !error || (kind != 1 && kind != 2)) return NULL;
    struct stat value;
    if (lstat(path, &value) != 0 || !S_ISREG(value.st_mode) || value.st_size <= 0 ||
        (uint64_t)value.st_size > maximum_bytes) return NULL;
    FloeIPDatabase *db = calloc(1, sizeof(*db));
    if (!db) return NULL;
    *error = MMDB_open(path, MMDB_MODE_MMAP, &db->reader);
    if (*error != MMDB_SUCCESS) { free(db); return NULL; }
    const char *type = db->reader.metadata.database_type;
    if (!type || strlen(type) >= sizeof(metadata->type) ||
        !strstr(type, kind == 1 ? "City" : "ASN") ||
        db->reader.metadata.binary_format_major_version != 2 ||
        (db->reader.metadata.ip_version != 4 && db->reader.metadata.ip_version != 6)) {
        *error = -2; MMDB_close(&db->reader); free(db); return NULL;
    }
    memset(metadata, 0, sizeof(*metadata));
    memcpy(metadata->type, type, strlen(type));
    metadata->build_epoch = db->reader.metadata.build_epoch;
    metadata->ip_version = db->reader.metadata.ip_version;
    db->kind = kind;
    return db;
}

static int text_value(MMDB_entry_s *entry, const char *const *path,
                      char *destination, size_t capacity) {
    MMDB_entry_data_s value;
    int status = MMDB_aget_value(entry, &value, path);
    if (status == MMDB_LOOKUP_PATH_DOES_NOT_MATCH_DATA_ERROR) return 0;
    if (status != MMDB_SUCCESS) return status;
    if (!value.has_data) return 0;
    if (value.type != MMDB_DATA_TYPE_UTF8_STRING || value.data_size >= capacity ||
        memchr(value.utf8_string, 0, value.data_size)) return MMDB_INVALID_DATA_ERROR;
    memcpy(destination, value.utf8_string, value.data_size);
    destination[value.data_size] = 0;
    return 0;
}

static int named_value(MMDB_entry_s *entry, const char *field, const char *language,
                       char *destination, size_t capacity) {
    const char *path[] = {field, "names", language, NULL};
    int status = text_value(entry, path, destination, capacity);
    if (!status && !destination[0] && strcmp(language, "en")) {
        path[2] = "en";
        status = text_value(entry, path, destination, capacity);
    }
    return status;
}

/* Optional MMDB numbers remain absent unless their actual field exists. */
static int number_value(MMDB_entry_s *entry, const char *const *path,
                        double *destination, int *present) {
    MMDB_entry_data_s value;
    int status = MMDB_aget_value(entry, &value, path);
    *present = 0;
    if (status == MMDB_LOOKUP_PATH_DOES_NOT_MATCH_DATA_ERROR) return 0;
    if (status != MMDB_SUCCESS) return status;
    if (!value.has_data) return 0;
    switch (value.type) {
        case MMDB_DATA_TYPE_DOUBLE: *destination = value.double_value; break;
        case MMDB_DATA_TYPE_FLOAT: *destination = value.float_value; break;
        case MMDB_DATA_TYPE_UINT16: *destination = value.uint16; break;
        case MMDB_DATA_TYPE_UINT32: *destination = value.uint32; break;
        case MMDB_DATA_TYPE_UINT64: *destination = (double)value.uint64; break;
        case MMDB_DATA_TYPE_INT32: *destination = value.int32; break;
        default: return MMDB_INVALID_DATA_ERROR;
    }
    *present = 1;
    return 0;
}

static int location_value(MMDB_entry_s *entry, FloeIPDatabaseRecord *record) {
    const char *latitude_path[] = {"location", "latitude", NULL};
    const char *longitude_path[] = {"location", "longitude", NULL};
    const char *accuracy_path[] = {"location", "accuracy_radius", NULL};
    double latitude = 0, longitude = 0, accuracy = 0;
    int has_latitude = 0, has_longitude = 0, has_accuracy = 0;
    int status = number_value(entry, latitude_path, &latitude, &has_latitude);
    if (status) return status;
    status = number_value(entry, longitude_path, &longitude, &has_longitude);
    if (status) return status;
    status = number_value(entry, accuracy_path, &accuracy, &has_accuracy);
    if (status) return status;
    /* Invalid optional geography must not erase usable country/ASN fields. */
    if (!has_latitude || !has_longitude || !isfinite(latitude) || !isfinite(longitude) ||
        latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return 0;
    record->has_location = 1;
    record->latitude = latitude;
    record->longitude = longitude;
    if (has_accuracy && isfinite(accuracy) && accuracy >= 0) {
        record->has_accuracy_radius = 1;
        record->accuracy_radius_kilometers = accuracy;
    }
    return 0;
}

int floe_ip_lookup(FloeIPDatabase *db, const char *numeric_address,
                   const char *language, FloeIPDatabaseRecord *record) {
    if (!db || !numeric_address || !language || !record) return -1;
    memset(record, 0, sizeof(*record));
    struct sockaddr_storage address;
    memset(&address, 0, sizeof(address));
    struct sockaddr_in *v4 = (struct sockaddr_in *)&address;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&address;
    int family;
    if (inet_pton(AF_INET, numeric_address, &v4->sin_addr) == 1) {
        family = AF_INET; v4->sin_family = AF_INET;
    } else if (inet_pton(AF_INET6, numeric_address, &v6->sin6_addr) == 1) {
        family = AF_INET6; v6->sin6_family = AF_INET6;
        if (db->reader.metadata.ip_version == 4) return 0;
    } else return -1;
    int error = 0;
    MMDB_lookup_result_s result = MMDB_lookup_sockaddr(&db->reader, (struct sockaddr *)&address, &error);
    if (error || !result.found_entry) return error;
    record->found = 1;
    record->prefix_length = result.netmask;
    if (family == AF_INET && db->reader.metadata.ip_version == 6)
        record->prefix_length = result.netmask >= 96 ? result.netmask - 96 : 0;
    if (db->kind == 2) {
        MMDB_entry_data_s value;
        const char *asn[] = {"autonomous_system_number", NULL};
        error = MMDB_aget_value(&result.entry, &value, asn);
        if (error != MMDB_SUCCESS && error != MMDB_LOOKUP_PATH_DOES_NOT_MATCH_DATA_ERROR) return error;
        if (!error && value.has_data) {
            if (value.type != MMDB_DATA_TYPE_UINT32) return MMDB_INVALID_DATA_ERROR;
            record->has_asn = 1; record->asn = value.uint32;
        }
        const char *org[] = {"autonomous_system_organization", NULL};
        return text_value(&result.entry, org, record->organization, sizeof(record->organization));
    }
    const char *code[] = {"country", "iso_code", NULL};
    error = text_value(&result.entry, code, record->country_code, sizeof(record->country_code));
    if (error) return error;
    if ((error = named_value(&result.entry, "country", language, record->country, sizeof(record->country)))) return error;
    if ((error = named_value(&result.entry, "city", language, record->city, sizeof(record->city)))) return error;
    const char *region[] = {"subdivisions", "0", "names", language, NULL};
    error = text_value(&result.entry, region, record->region, sizeof(record->region));
    if (!error && !record->region[0] && strcmp(language, "en")) {
        region[3] = "en";
        error = text_value(&result.entry, region, record->region, sizeof(record->region));
    }
    return error ? error : location_value(&result.entry, record);
}

void floe_ip_close(FloeIPDatabase *db) {
    if (db) { MMDB_close(&db->reader); free(db); }
}

// Import validation walks the finite search-node table and decodes each
// distinct data record once, retaining all upstream depth/value/byte limits.
// The offset bitmap costs at most file_bytes/8; no record strings are copied.
int floe_ip_validate(FloeIPDatabase *db, int (*cancelled)(void *), void *context) {
    if (!db) return -1;
    if (db->reader.metadata.node_count > 32000000U) return -3;
    size_t size = ((size_t)db->reader.data_section_size + 7) / 8;
    unsigned char *seen = calloc(size ? size : 1, 1);
    if (!seen) return -3;
    int error = 0;
    for (uint32_t index = 0; index < db->reader.metadata.node_count; index++) {
        if (cancelled && cancelled(context)) { error = -4; break; }
        MMDB_search_node_s node;
        if ((error = MMDB_read_node(&db->reader, index, &node))) break;
        MMDB_entry_s *entries[] = {&node.left_record_entry, &node.right_record_entry};
        uint8_t types[] = {node.left_record_type, node.right_record_type};
        for (int i = 0; i < 2; i++) {
            if (types[i] == MMDB_RECORD_TYPE_INVALID) { error = MMDB_INVALID_DATA_ERROR; break; }
            if (types[i] != MMDB_RECORD_TYPE_DATA) continue;
            uint32_t offset = entries[i]->offset;
            if (offset >= db->reader.data_section_size) { error = MMDB_INVALID_DATA_ERROR; break; }
            if (seen[offset / 8] & (1U << (offset % 8))) continue;
            seen[offset / 8] |= 1U << (offset % 8);
            MMDB_entry_data_list_s *list = NULL;
            error = MMDB_get_entry_data_list(entries[i], &list);
            MMDB_free_entry_data_list(list);
            if (error) break;
        }
        if (error) break;
    }
    free(seen); return error;
}

int floe_ip_expand_gzip(const char *source, const char *destination,
                        uint64_t maximum_bytes, int (*cancelled)(void *), void *context) {
    if (!source || !destination || !maximum_bytes) return -1;
    int probe = open(source, O_RDONLY | O_NOFOLLOW);
    unsigned char magic[2];
    if (probe < 0) return -1;
    ssize_t probed = read(probe, magic, 2); close(probe);
    if (probed != 2 || magic[0] != 0x1f || magic[1] != 0x8b) return -2;
    gzFile input = gzopen(source, "rb");
    if (!input) return -1;
    int output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (output < 0) { gzclose(input); return -1; }
    unsigned char buffer[65536];
    uint64_t total = 0;
    int status = 0;
    for (;;) {
        if (cancelled && cancelled(context)) { status = -4; break; }
        int count = gzread(input, buffer, sizeof(buffer));
        if (count < 0) { status = -2; break; }
        if (!count) {
            int error = 0; gzerror(input, &error);
            if (error != Z_OK && error != Z_STREAM_END) status = -2;
            break;
        }
        if ((uint64_t)count > maximum_bytes - total) { status = -3; break; }
        total += (uint64_t)count;
        size_t offset = 0;
        while (offset < (size_t)count) {
            ssize_t written = write(output, buffer + offset, (size_t)count - offset);
            if (written <= 0) { status = -1; break; }
            offset += (size_t)written;
        }
        if (status) break;
    }
    if (gzclose(input) != Z_OK && !status) status = -2;
    if (!status && fsync(output)) status = -1;
    if (close(output) && !status) status = -1;
    if (status) unlink(destination);
    return status;
}

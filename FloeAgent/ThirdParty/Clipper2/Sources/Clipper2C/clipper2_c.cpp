/*
 * Thin C ABI implementation over the pinned Clipper2 engine.
 *
 * SPDX-License-Identifier: BSL-1.0
 *
 * This file is a project-authored adapter, not an upstream Clipper2 source
 * file. It owns no document state and performs no I/O.
 */

#include "clipper2_c.h"

#include "clipper2/clipper.engine.h"
#include "clipper2/clipper.offset.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include <string>
#include <vector>

namespace {

using Clipper2Lib::ClipType;
using Clipper2Lib::Clipper64;
using Clipper2Lib::ClipperOffset;
using Clipper2Lib::EndType;
using Clipper2Lib::FillRule;
using Clipper2Lib::JoinType;
using Clipper2Lib::Path64;
using Clipper2Lib::Paths64;
using Clipper2Lib::Point64;

FloeClipperResult zero_result() {
    FloeClipperResult result;
    result.coords = nullptr;
    result.coord_count = 0;
    result.offsets = nullptr;
    result.path_count = 0;
    result.error_code = 0;
    result.error_message = nullptr;
    return result;
}

char *copy_message(const std::string &message) {
    const size_t size = message.size() + 1;
    char *out = static_cast<char *>(std::malloc(size));
    if (out == nullptr) {
        return nullptr;
    }
    std::memcpy(out, message.c_str(), size);
    return out;
}

FloeClipperResult error_result(int32_t code, const std::string &message) {
    FloeClipperResult result = zero_result();
    result.error_code = code;
    result.error_message = copy_message(message);
    return result;
}

bool read_paths(
    const int64_t *coords,
    size_t coord_count,
    const size_t *offsets,
    size_t path_count,
    Paths64 &out,
    std::string &error
) {
    if ((coord_count % 2) != 0) {
        error = "coordinate count must be an even number of x/y values";
        return false;
    }
    const size_t point_count = coord_count / 2;
    if (path_count == 0) {
        if (point_count != 0) {
            error = "non-empty coordinates require at least one path";
            return false;
        }
        return true;
    }
    if (offsets == nullptr) {
        error = "path offsets are missing";
        return false;
    }
    if (offsets[0] != 0) {
        error = "first path offset must be zero";
        return false;
    }
    if (offsets[path_count] != point_count) {
        error = "final path offset does not match the coordinate count";
        return false;
    }
    if (point_count > 0 && coords == nullptr) {
        error = "coordinates are missing";
        return false;
    }

    out.clear();
    out.reserve(path_count);
    for (size_t index = 0; index < path_count; ++index) {
        const size_t start = offsets[index];
        const size_t end = offsets[index + 1];
        if (end < start || end > point_count) {
            error = "path offsets are not monotonic or exceed the coordinate count";
            return false;
        }
        if (start == end) {
            // Empty sub-paths are legal transport but contribute no geometry.
            continue;
        }
        Path64 path;
        path.reserve(end - start);
        for (size_t point = start; point < end; ++point) {
            path.emplace_back(coords[point * 2], coords[point * 2 + 1]);
        }
        out.emplace_back(std::move(path));
    }
    return true;
}

bool clip_type_from(int32_t value, ClipType &out) {
    switch (value) {
    case FLOE_CLIPPER_INTERSECTION: out = ClipType::Intersection; return true;
    case FLOE_CLIPPER_UNION: out = ClipType::Union; return true;
    case FLOE_CLIPPER_DIFFERENCE: out = ClipType::Difference; return true;
    case FLOE_CLIPPER_XOR: out = ClipType::Xor; return true;
    default: return false;
    }
}

bool fill_rule_from(int32_t value, FillRule &out) {
    switch (value) {
    case FLOE_CLIPPER_FILL_EVEN_ODD: out = FillRule::EvenOdd; return true;
    case FLOE_CLIPPER_FILL_NON_ZERO: out = FillRule::NonZero; return true;
    case FLOE_CLIPPER_FILL_POSITIVE: out = FillRule::Positive; return true;
    case FLOE_CLIPPER_FILL_NEGATIVE: out = FillRule::Negative; return true;
    default: return false;
    }
}

bool join_type_from(int32_t value, JoinType &out) {
    switch (value) {
    case FLOE_CLIPPER_JOIN_SQUARE: out = JoinType::Square; return true;
    case FLOE_CLIPPER_JOIN_BEVEL: out = JoinType::Bevel; return true;
    case FLOE_CLIPPER_JOIN_ROUND: out = JoinType::Round; return true;
    case FLOE_CLIPPER_JOIN_MITER: out = JoinType::Miter; return true;
    default: return false;
    }
}

bool end_type_from(int32_t value, EndType &out) {
    switch (value) {
    case FLOE_CLIPPER_END_POLYGON: out = EndType::Polygon; return true;
    case FLOE_CLIPPER_END_JOINED: out = EndType::Joined; return true;
    case FLOE_CLIPPER_END_BUTT: out = EndType::Butt; return true;
    case FLOE_CLIPPER_END_SQUARE: out = EndType::Square; return true;
    case FLOE_CLIPPER_END_ROUND: out = EndType::Round; return true;
    default: return false;
    }
}

FloeClipperResult result_from_paths(const Paths64 &paths) {
    FloeClipperResult result = zero_result();
    size_t point_count = 0;
    for (const auto &path : paths) {
        if (path.size() > (std::numeric_limits<size_t>::max() - point_count)) {
            return error_result(3, "result point count overflow");
        }
        point_count += path.size();
    }
    if (point_count == 0) {
        return result;
    }
    if (point_count > (std::numeric_limits<size_t>::max() / 2)) {
        return error_result(3, "result coordinate count overflow");
    }
    const size_t coord_count = point_count * 2;
    if (coord_count > (std::numeric_limits<size_t>::max() / sizeof(int64_t))) {
        return error_result(3, "result allocation overflow");
    }
    result.coords = static_cast<int64_t *>(std::malloc(coord_count * sizeof(int64_t)));
    if (result.coords == nullptr) {
        return error_result(3, "could not allocate result coordinates");
    }
    if (paths.size() + 1 < paths.size() ||
        (paths.size() + 1) > (std::numeric_limits<size_t>::max() / sizeof(size_t))) {
        std::free(result.coords);
        return error_result(3, "result path allocation overflow");
    }
    result.offsets = static_cast<size_t *>(std::malloc((paths.size() + 1) * sizeof(size_t)));
    if (result.offsets == nullptr) {
        std::free(result.coords);
        return error_result(3, "could not allocate result offsets");
    }

    size_t coord_index = 0;
    size_t path_index = 0;
    result.offsets[0] = 0;
    for (const auto &path : paths) {
        for (const auto &point : path) {
            result.coords[coord_index++] = point.x;
            result.coords[coord_index++] = point.y;
        }
        result.offsets[++path_index] = coord_index / 2;
    }
    result.coord_count = coord_count;
    result.path_count = paths.size();
    return result;
}

FloeClipperResult run_boolean(
    int32_t operation,
    int32_t fill_rule,
    const int64_t *subject_coords,
    size_t subject_coord_count,
    const size_t *subject_offsets,
    size_t subject_path_count,
    const int64_t *clip_coords,
    size_t clip_coord_count,
    const size_t *clip_offsets,
    size_t clip_path_count
) {
    ClipType clip_type;
    FillRule rule;
    if (!clip_type_from(operation, clip_type)) {
        return error_result(1, "unknown boolean operation");
    }
    if (!fill_rule_from(fill_rule, rule)) {
        return error_result(1, "unknown fill rule");
    }

    Paths64 subjects;
    Paths64 clips;
    std::string error;
    if (!read_paths(subject_coords, subject_coord_count, subject_offsets, subject_path_count, subjects, error)) {
        return error_result(1, "invalid subject paths: " + error);
    }
    if (!read_paths(clip_coords, clip_coord_count, clip_offsets, clip_path_count, clips, error)) {
        return error_result(1, "invalid clip paths: " + error);
    }

    try {
        Paths64 solution;
        Clipper64 clipper;
        clipper.AddSubject(subjects);
        clipper.AddClip(clips);
        if (!clipper.Execute(clip_type, rule, solution)) {
            if (clipper.ErrorCode() == 0) {
                return result_from_paths(solution);
            }
            return error_result(
                2,
                "Clipper2 boolean execution failed with error " + std::to_string(clipper.ErrorCode())
            );
        }
        return result_from_paths(solution);
    } catch (const std::exception &exception) {
        return error_result(2, std::string("Clipper2 exception: ") + exception.what());
    } catch (...) {
        return error_result(2, "Clipper2 raised an unknown exception");
    }
}

FloeClipperResult run_offset(
    const int64_t *coords,
    size_t coord_count,
    const size_t *offsets,
    size_t path_count,
    double delta,
    int32_t join_type,
    int32_t end_type,
    double miter_limit,
    double arc_tolerance
) {
    JoinType join;
    EndType end;
    if (!join_type_from(join_type, join)) {
        return error_result(1, "unknown join type");
    }
    if (!end_type_from(end_type, end)) {
        return error_result(1, "unknown end type");
    }
    if (!std::isfinite(delta)) {
        return error_result(1, "offset delta must be finite");
    }
    if (!std::isfinite(miter_limit) || miter_limit < 1.0) {
        return error_result(1, "miter limit must be finite and >= 1");
    }
    if (!std::isfinite(arc_tolerance) || arc_tolerance < 0.0) {
        return error_result(1, "arc tolerance must be finite and >= 0");
    }

    Paths64 paths;
    std::string error;
    if (!read_paths(coords, coord_count, offsets, path_count, paths, error)) {
        return error_result(1, "invalid offset paths: " + error);
    }

    try {
        Paths64 solution;
        ClipperOffset offsetter(miter_limit, arc_tolerance);
        offsetter.AddPaths(paths, join, end);
        offsetter.Execute(delta, solution);
        if (offsetter.ErrorCode() != 0) {
            return error_result(
                2,
                "Clipper2 offset execution failed with error " + std::to_string(offsetter.ErrorCode())
            );
        }
        return result_from_paths(solution);
    } catch (const std::exception &exception) {
        return error_result(2, std::string("Clipper2 exception: ") + exception.what());
    } catch (...) {
        return error_result(2, "Clipper2 raised an unknown exception");
    }
}

} // namespace

extern "C" {

FloeClipperResult floe_clipper_boolean(
    int32_t operation,
    int32_t fill_rule,
    const int64_t *subject_coords,
    size_t subject_coord_count,
    const size_t *subject_offsets,
    size_t subject_path_count,
    const int64_t *clip_coords,
    size_t clip_coord_count,
    const size_t *clip_offsets,
    size_t clip_path_count
) {
    return run_boolean(
        operation,
        fill_rule,
        subject_coords,
        subject_coord_count,
        subject_offsets,
        subject_path_count,
        clip_coords,
        clip_coord_count,
        clip_offsets,
        clip_path_count
    );
}

FloeClipperResult floe_clipper_offset(
    const int64_t *coords,
    size_t coord_count,
    const size_t *offsets,
    size_t path_count,
    double delta,
    int32_t join_type,
    int32_t end_type,
    double miter_limit,
    double arc_tolerance
) {
    return run_offset(
        coords,
        coord_count,
        offsets,
        path_count,
        delta,
        join_type,
        end_type,
        miter_limit,
        arc_tolerance
    );
}

void floe_clipper_result_free(FloeClipperResult *result) {
    if (result == nullptr) {
        return;
    }
    std::free(result->coords);
    std::free(result->offsets);
    std::free(result->error_message);
    *result = zero_result();
}

const char *floe_clipper_version(void) {
    return "Clipper2 2.0.1 (PolyClipping/Clipper2 b496b454df168a2280354857c1cd90bd6fa7b4dd)";
}

} // extern "C"

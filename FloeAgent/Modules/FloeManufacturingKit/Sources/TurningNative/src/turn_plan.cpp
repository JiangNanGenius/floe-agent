/*
 * turn_plan.cpp — TurningNative C ABI: fm_turn_plan / fm_turn_free.
 *
 * Parses the CONTRACT.md formatVersion-1 request, validates it, runs the
 * ported LibLathe face/rough/profile operations and serialises the result.
 * All exceptions are contained; failures return {"ok":false,"error":...}.
 */
#include "TurningNative.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <new>
#include <string>
#include <vector>

#include "fmjson.h"
#include "turn_ops.h"
#include "turn_tool.h"

namespace
{

const char *kBackend = "liblathe@4bac3400 (TurningNative C++ port, prototype)";
/* Safety cap on generated output size (points across all paths). */
const size_t kMaxOutputPoints = 100000;

char *dupCStr(const std::string &s)
{
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out)
        return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

std::string errorJson(const std::string &message)
{
    fmjson::Writer w;
    w.raw("{\"ok\":false,\"error\":");
    w.string(message);
    w.raw("}");
    return w.str();
}

bool finiteNumber(const fmjson::Value *v)
{
    return v && v->type == fmjson::Value::Number && std::isfinite(v->number);
}

struct Request
{
    double stockRadius = 0;
    double stockZMin = 0;
    double stockZMax = 0;
    std::vector<std::pair<double, double>> profile; /* [radius, z] pairs */
    double stepOverMM = 1.5;
    double allowanceMM = 0.0;
    int finishPasses = 1;
    double toolNoseRadiusMM = 0.4;
    double feedMMPerMinute = 100.0;
    bool hasSetup = false;             /* top-level turningSetup present */
    turning::TurningSetup setup;       /* resolved only when hasSetup */
};

void boolField(const fmjson::Value &object, const char *key, bool &out)
{
    const fmjson::Value *v = object.find(key);
    if (!v)
        return; /* absent keeps the default */
    if (v->type != fmjson::Value::Bool)
        throw std::runtime_error(std::string("turningSetup.") + key + " must be a boolean");
    out = v->boolean;
}

/* Optional finite number in [min, max]; absent returns `def`. */
double numberField(const fmjson::Value &object, const char *key, double def, double min,
                   double max, const char *rangeText)
{
    const fmjson::Value *v = object.find(key);
    if (!v)
        return def;
    if (!finiteNumber(v) || v->number < min || v->number > max)
        throw std::runtime_error(std::string("turningSetup.") + key + " must be finite and " +
                                 rangeText);
    return v->number;
}

/*
 * Validate and decode the optional top-level turningSetup. Unknown keys are
 * refused so a silently-ignored new field cannot pass as success. Defaults
 * match the pre-R4 behaviour (and the contract's explicit defaults).
 */
void parseSetup(const fmjson::Value &root, Request &req)
{
    const fmjson::Value *setup = root.find("turningSetup");
    if (!setup)
        return;
    if (setup->type != fmjson::Value::Object)
        throw std::runtime_error("turningSetup must be an object");

    const fmjson::Value *fv = setup->find("formatVersion");
    if (!fv || fv->type != fmjson::Value::Number || fv->number != 1)
        throw std::runtime_error("unsupported or missing turningSetup.formatVersion (expected 1)");

    static const char *kKnown[] = {"formatVersion",   "faceEnabled",
                                   "roughEnabled",    "profileEnabled",
                                   "clearanceMM",     "horizontalFeedMMPerMinute",
                                   "verticalFeedMMPerMinute", "leadinAngleDegrees",
                                   "leadoutAngleDegrees",     "allowGrooving",
                                   "insertShape",     "insertEdgeLengthMM",
                                   "insertRotationDegrees"};
    for (const auto &member : setup->members)
    {
        bool known = false;
        for (const char *key : kKnown)
            if (member.first == key)
                known = true;
        if (!known)
            throw std::runtime_error("unknown turningSetup key '" + member.first + "'");
    }

    turning::TurningSetup s;
    boolField(*setup, "faceEnabled", s.faceEnabled);
    boolField(*setup, "roughEnabled", s.roughEnabled);
    boolField(*setup, "profileEnabled", s.profileEnabled);
    if (!s.faceEnabled && !s.roughEnabled && !s.profileEnabled)
        throw std::runtime_error("all turning operations disabled (faceEnabled, roughEnabled, profileEnabled)");

    s.clearanceMM = numberField(*setup, "clearanceMM", 3.0, 0.0, 10000.0, "in [0, 10000]");
    s.horizontalFeedMMPerMinute = numberField(*setup, "horizontalFeedMMPerMinute", 120.0, 1e-6, 1e6, "in (0, 1e6]");
    s.verticalFeedMMPerMinute = numberField(*setup, "verticalFeedMMPerMinute", 120.0, 1e-6, 1e6, "in (0, 1e6]");
    s.leadinAngleDegrees = numberField(*setup, "leadinAngleDegrees", 270.0, 0.0, 360.0 - 1e-9, "in [0, 360)");
    s.leadoutAngleDegrees = numberField(*setup, "leadoutAngleDegrees", 315.0, 0.0, 360.0 - 1e-9, "in [0, 360)");
    boolField(*setup, "allowGrooving", s.allowGrooving);

    const fmjson::Value *shape = setup->find("insertShape");
    if (shape)
    {
        if (shape->type != fmjson::Value::String || shape->str.size() != 1)
            throw std::runtime_error("turningSetup.insertShape must be a single character");
        char c = shape->str[0];
        if (c >= 'a' && c <= 'z')
            c = static_cast<char>(c - 'a' + 'A');
        if (!turning::supportedInsertShape(c))
            throw std::runtime_error(std::string("unsupported insertShape '") + c +
                                     "'; supported shapes: " + turning::supportedInsertShapesText());
        s.insertShape = c;
    }

    s.insertEdgeLengthMM = numberField(*setup, "insertEdgeLengthMM", 6.35, 1e-6, 1000.0, "in (0, 1000]");
    s.insertRotationDegrees = numberField(*setup, "insertRotationDegrees", 0.0, 0.0, 360.0 - 1e-9, "in [0, 360)");

    /* Re-check through the builder's own guard so the receipt can never
     * describe a shape the geometry engine would refuse. */
    (void)turning::buildInsertShape(s.insertShape, s.insertEdgeLengthMM, s.insertRotationDegrees);

    req.hasSetup = true;
    req.setup = s;
}

/* Validate and decode the request. Throws fmjson::ParseError/std::string. */
Request parseRequest(const fmjson::Value &root)
{
    Request req;
    const fmjson::Value *fv = root.find("formatVersion");
    if (!fv || fv->type != fmjson::Value::Number || fv->number != 1)
        throw std::runtime_error("unsupported or missing formatVersion (expected 1)");

    const fmjson::Value *stock = root.find("stock");
    if (!stock || stock->type != fmjson::Value::Object)
        throw std::runtime_error("missing stock object");
    if (!finiteNumber(stock->find("radiusMM")) || !finiteNumber(stock->find("zMinMM")) ||
        !finiteNumber(stock->find("zMaxMM")))
        throw std::runtime_error("stock radiusMM/zMinMM/zMaxMM must be finite numbers");
    req.stockRadius = stock->find("radiusMM")->number;
    req.stockZMin = stock->find("zMinMM")->number;
    req.stockZMax = stock->find("zMaxMM")->number;
    if (req.stockRadius <= 0 || req.stockRadius > 100000)
        throw std::runtime_error("stock radiusMM must be positive and bounded");
    if (req.stockZMax <= req.stockZMin)
        throw std::runtime_error("stock zMaxMM must be greater than zMinMM");
    if (std::fabs(req.stockZMax - req.stockZMin) > 1e6)
        throw std::runtime_error("stock length must be bounded");
    if (std::fabs(req.stockZMin) > 100000 || std::fabs(req.stockZMax) > 100000)
        throw std::runtime_error("stock Z coordinates exceed prototype bounds");

    const fmjson::Value *profile = root.find("profile");
    if (!profile || profile->type != fmjson::Value::Array || profile->items.size() < 2 || profile->items.size() > 256)
        throw std::runtime_error("profile must contain at least two [radius,z] points");
    double prevZ = -std::numeric_limits<double>::infinity();
    for (const auto &item : profile->items)
    {
        if (item.type != fmjson::Value::Array || item.items.size() != 2 ||
            !finiteNumber(&item.items[0]) || !finiteNumber(&item.items[1]))
            throw std::runtime_error("profile points must be finite [radius,z] pairs");
        double radius = item.items[0].number;
        double z = item.items[1].number;
        if (radius < 0 || radius > req.stockRadius || z < req.stockZMin || z > req.stockZMax)
            throw std::runtime_error("profile radius/Z exceeds stock bounds");
        if (z < prevZ)
            throw std::runtime_error("profile z values must be ordered (equal-z shoulders allowed)");
        if (!req.profile.empty() && req.profile.back().first == radius && req.profile.back().second == z)
            throw std::runtime_error("duplicate profile point");
        prevZ = z;
        req.profile.emplace_back(radius, z);
    }

    const fmjson::Value *turning = root.find("turning");
    if (turning && turning->type == fmjson::Value::Object)
    {
        const fmjson::Value *v = turning->find("stepOverMM");
        if (v)
        {
            if (!finiteNumber(v) || v->number < 0.05 || v->number > req.stockRadius)
                throw std::runtime_error("turning.stepOverMM must be finite, positive and no larger than the stock radius");
            req.stepOverMM = v->number;
        }
        v = turning->find("allowanceMM");
        if (v)
        {
            if (!finiteNumber(v) || v->number < 0 || v->number >= req.stockRadius)
                throw std::runtime_error("turning.allowanceMM must be a finite nonnegative number");
            req.allowanceMM = v->number;
        }
        v = turning->find("finishPasses");
        if (v)
        {
            if (!finiteNumber(v) || v->number < 1 || v->number > 32 ||
                std::floor(v->number) != v->number)
                throw std::runtime_error("turning.finishPasses must be an integer in [1,32]");
            req.finishPasses = static_cast<int>(v->number);
        }
        v = turning->find("toolNoseRadiusMM");
        if (v)
        {
            if (!finiteNumber(v) || v->number < 0)
                throw std::runtime_error("turning.toolNoseRadiusMM must be a finite nonnegative number");
            req.toolNoseRadiusMM = v->number;
            if (std::fabs(req.toolNoseRadiusMM - 0.4) > 1e-9)
                throw std::runtime_error("this prototype uses a fixed DCMT insert; adjustable nose geometry is unsupported");
        }
        v = turning->find("feedMMPerMinute");
        if (v)
        {
            if (!finiteNumber(v) || v->number <= 0 || v->number > 1e6)
                throw std::runtime_error("turning.feedMMPerMinute must be a finite positive number");
            req.feedMMPerMinute = v->number;
        }
    }
    parseSetup(root, req);

    if (req.profile.back().second <= req.profile.front().second)
        throw std::runtime_error("profile requires positive Z extent");
    if (std::ceil(req.stockRadius / req.stepOverMM) +
        std::ceil((req.stockZMax - req.profile.back().second) / req.stepOverMM) > 12000)
        throw std::runtime_error("turning pass budget exceeded");
    return req;
}

/* Append one polyline path entry. */
void emitPath(fmjson::Writer &w, const char *kind, const std::vector<Point> &points,
              double feed, bool &first, size_t &totalPoints, bool precise = false)
{
    totalPoints += points.size();
    if (totalPoints > kMaxOutputPoints)
        throw std::runtime_error("step budget exceeded (too many output points)");
    if (!first)
        w.raw(",");
    first = false;
    w.raw("{\"kind\":");
    w.string(kind);
    w.raw(",\"points\":[");
    for (size_t i = 0; i < points.size(); ++i)
    {
        if (i)
            w.raw(",");
        w.raw("[");
        if (precise) w.numberPrecise(points[i].X); else w.number(points[i].X);
        w.raw(",");
        if (precise) w.numberPrecise(points[i].Z); else w.number(points[i].Z);
        w.raw("]");
    }
    w.raw("],\"feedMMPerMinute\":");
    if (precise) w.numberPrecise(feed); else w.number(feed);
    w.raw("}");
}

/*
 * Feed policy for emitted paths. `directional == false` is the pre-R4
 * behaviour: every path carries the single legacy scalar feed and the
 * polyline merging below is byte-for-byte unchanged. `directional == true`
 * (turningSetup enabled) computes a real per-segment feed: pure X segments
 * run at the horizontal feed, pure Z segments at the vertical feed, and
 * diagonal segments are limited so neither axis component rate exceeds its
 * configured axis feed. Segments with different feeds are split into
 * separate paths (no implicit connecting moves are introduced either way).
 */
struct FeedPolicy
{
    bool directional = false;
    double horizontalFeedMMPerMinute = 0;
    double verticalFeedMMPerMinute = 0;
    double legacyFeedMMPerMinute = 0;
};

/* Per-segment feed under a directional policy; negative => zero-length skip. */
double directionalSegmentFeed(const Segment &seg, const FeedPolicy &policy)
{
    const double dx = std::fabs(static_cast<double>(seg.end.X) - seg.start.X);
    const double dz = std::fabs(static_cast<double>(seg.end.Z) - seg.start.Z);
    if (dx == 0 && dz == 0)
        return -1.0;
    if (dx == 0)
        return policy.verticalFeedMMPerMinute;
    if (dz == 0)
        return policy.horizontalFeedMMPerMinute;
    const double length = std::sqrt(dx * dx + dz * dz);
    const double horizontalCap = policy.horizontalFeedMMPerMinute * length / dx;
    const double verticalCap = policy.verticalFeedMMPerMinute * length / dz;
    return std::min(horizontalCap, verticalCap);
}

/*
 * Flatten a segment group into separate cut polylines: consecutive segments
 * whose endpoints touch are merged into one polyline; disconnected segments
 * start a new path. No implicit connecting moves are introduced.
 */
void emitSegmentGroup(fmjson::Writer &w, const char *kind, const SegmentGroup &group,
                      const FeedPolicy &policy, bool &first, size_t &totalPoints)
{
    SegmentGroup groupCopy = group; /* vendored accessor is non-const */
    std::vector<Segment> segs = groupCopy.getSegments();
    std::vector<Point> polyline;
    double polylineFeed = policy.legacyFeedMMPerMinute;
    auto flush = [&]() {
        if (polyline.size() >= 2)
            emitPath(w, kind, polyline, polylineFeed, first, totalPoints, policy.directional);
        polyline.clear();
    };
    for (const auto &seg : segs)
    {
        double segFeed = policy.legacyFeedMMPerMinute;
        if (policy.directional)
        {
            segFeed = directionalSegmentFeed(seg, policy);
            if (segFeed < 0.0)
                continue; /* zero-length segment */
        }
        if (polyline.empty())
        {
            polylineFeed = segFeed;
            polyline.push_back(seg.start);
            polyline.push_back(seg.end);
        }
        else if (policy.directional ? (polyline.back().X == seg.start.X && polyline.back().Z == seg.start.Z) : polyline.back().isSame(seg.start))
        {
            if (policy.directional && std::fabs(segFeed - polylineFeed) > 1e-9)
            {
                flush();
                polylineFeed = segFeed;
                polyline.push_back(seg.start);
            }
            if (policy.directional) polylineFeed = std::min(polylineFeed,segFeed);
            polyline.push_back(seg.end);
        }
        else
        {
            flush();
            polylineFeed = segFeed;
            polyline.push_back(seg.start);
            polyline.push_back(seg.end);
        }
    }
    flush();
}

/* Emit the R4 setupReceipt: the fully-resolved applied setup, the exact 2D
 * tool outline used for defeature, and the backend identity string. */
void emitSetupReceipt(fmjson::Writer &w, const turning::TurningSetup &s,
                      const std::vector<std::pair<float, float>> &outline)
{
    w.raw("{\"formatVersion\":1,\"applied\":{\"formatVersion\":1,");
    w.raw("\"faceEnabled\":");
    w.raw(s.faceEnabled ? "true" : "false");
    w.raw(",\"roughEnabled\":");
    w.raw(s.roughEnabled ? "true" : "false");
    w.raw(",\"profileEnabled\":");
    w.raw(s.profileEnabled ? "true" : "false");
    w.raw(",\"clearanceMM\":");
    w.numberPrecise(s.clearanceMM);
    w.raw(",\"horizontalFeedMMPerMinute\":");
    w.numberPrecise(s.horizontalFeedMMPerMinute);
    w.raw(",\"verticalFeedMMPerMinute\":");
    w.numberPrecise(s.verticalFeedMMPerMinute);
    w.raw(",\"leadinAngleDegrees\":");
    w.numberPrecise(s.leadinAngleDegrees);
    w.raw(",\"leadoutAngleDegrees\":");
    w.numberPrecise(s.leadoutAngleDegrees);
    w.raw(",\"allowGrooving\":");
    w.raw(s.allowGrooving ? "true" : "false");
    w.raw(",\"insertShape\":");
    w.string(std::string(1, s.insertShape));
    w.raw(",\"insertEdgeLengthMM\":");
    w.numberPrecise(s.insertEdgeLengthMM);
    w.raw(",\"insertRotationDegrees\":");
    w.numberPrecise(s.insertRotationDegrees);
    w.raw("},\"toolProfile\":[");
    for (size_t i = 0; i < outline.size(); ++i)
    {
        if (i)
            w.raw(",");
        w.raw("[");
        w.numberPrecise(outline[i].first);
        w.raw(",");
        w.numberPrecise(outline[i].second);
        w.raw("]");
    }
    w.raw("],\"backend\":");
    w.string(kBackend);
    w.raw("}");
}

std::string plan(const char *requestJson, FMProgress callback, void *context)
{
    fmjson::Value root = fmjson::Parser(requestJson).parseDocument();
    Request req = parseRequest(root);

    turning::Progress progress(callback, context);
    if (progress.poll(0.0, "validate"))
        return errorJson("cancelled");

    /* Build part segment group from the [radius,z] profile. The profile is
     * a stepped contour; add the axis endpoint so the group spans z=0..max
     * like LibLathe's own examples (first segment at the profile front,
     * final segment returning to the axis at the back). */
    SegmentGroup partGroup;
    const double zFront = req.profile.back().second;
    partGroup.addSegment(Segment(Point(0.0f, static_cast<float>(zFront)),
                                 Point(static_cast<float>(req.profile.back().first),
                                       static_cast<float>(zFront))));
    for (size_t i = req.profile.size() - 1; i-- > 0;)
    {
        partGroup.addSegment(Segment(Point(static_cast<float>(req.profile[i + 1].first),
                                           static_cast<float>(req.profile[i + 1].second)),
                                     Point(static_cast<float>(req.profile[i].first),
                                           static_cast<float>(req.profile[i].second))));
    }
    partGroup.addSegment(Segment(Point(static_cast<float>(req.profile.front().first),
                                       static_cast<float>(req.profile.front().second)),
                                 Point(0.0f, static_cast<float>(req.profile.front().second))));

    BoundBox stock(Point(0.0f, static_cast<float>(req.stockZMin)),
                   Point(static_cast<float>(req.stockRadius), static_cast<float>(req.stockZMax)));
    /* The insert shape is the real defeature tool: setup-driven when present,
     * otherwise the exact legacy fixed DCMT-equivalent insert. */
    SegmentGroup tool =
        req.hasSetup
            ? turning::buildInsertShape(req.setup.insertShape, req.setup.insertEdgeLengthMM,
                                        req.setup.insertRotationDegrees)
            : turning::buildInsertShape('D', 6.35f, 0.0f);

    auto configure = [&](turning::BaseOP &op) {
        turning::OpParams::apply(op, static_cast<float>(req.stepOverMM),
                                 static_cast<float>(req.allowanceMM), req.finishPasses,
                                 static_cast<float>(req.feedMMPerMinute),
                                 req.hasSetup ? &req.setup : nullptr);
        op.addStock(stock);
        op.addToolShape(tool);
        op.addPartSegments(partGroup.getSegments());
    };

    const turning::TurningSetup &s = req.setup;
    std::vector<SegmentGroup> facePaths, roughPaths, profilePaths;
    if (!req.hasSetup || s.faceEnabled)
    {
        turning::FaceOP face;
        configure(face);
        facePaths = face.generatePath(progress);
    }
    if (!req.hasSetup || s.roughEnabled)
    {
        turning::RoughOP rough;
        configure(rough);
        roughPaths = rough.generatePath(progress);
    }
    if (!req.hasSetup || s.profileEnabled)
    {
        turning::ProfileOP profile;
        configure(profile);
        // Integration policy: allowance belongs to roughing; finishing reaches
        // the requested profile. This is an explicit change from applying one
        // upstream BaseOP stockToLeave value to every operation.
        turning::OpParams::apply(profile, static_cast<float>(req.stepOverMM),
                                 0.0f, req.finishPasses,
                                 static_cast<float>(req.feedMMPerMinute),
                                 req.hasSetup ? &req.setup : nullptr);
        profilePaths = profile.generatePath(progress);
    }

    FeedPolicy policy;
    policy.directional = req.hasSetup;
    policy.legacyFeedMMPerMinute = req.feedMMPerMinute;
    if (req.hasSetup)
    {
        policy.horizontalFeedMMPerMinute = s.horizontalFeedMMPerMinute;
        policy.verticalFeedMMPerMinute = s.verticalFeedMMPerMinute;
    }

    fmjson::Writer w;
    w.raw("{\"ok\":true,\"backend\":");
    w.string(kBackend);
    w.raw(",\"paths\":[");
    bool first = true;
    size_t totalPoints = 0;
    for (const auto &g : facePaths)
        emitSegmentGroup(w, "face", g, policy, first, totalPoints);
    for (const auto &g : roughPaths)
        emitSegmentGroup(w, "rough", g, policy, first, totalPoints);
    for (const auto &g : profilePaths)
        emitSegmentGroup(w, "profile", g, policy, first, totalPoints);
    /* Legacy responses keep their exact R3 warning text; setup-enabled
     * responses describe the configured insert instead. */
    if (!req.hasSetup)
        w.raw("],\"warnings\":[\"Fixed DCMT rhombus geometry; no adjustable nose compensation, internal turning or grooves.\"],\"turning\":{\"stepOverMM\":");
    else
    {
        w.raw("],\"warnings\":[\"Configured insert shape without nose-radius compensation; geometry uses upstream Float32, receipt preserves requested values; no internal turning or threading operations.\"");
        if (s.insertShape == 'R')
            w.raw(",\"Round insert receipt profile is a 2-degree sampling; defeature uses exact arcs.\"");
        w.raw("],\"turning\":{\"stepOverMM\":");
    }
    w.number(req.stepOverMM);
    w.raw(",\"allowanceMM\":");
    w.number(req.allowanceMM);
    w.raw(",\"finishPasses\":");
    w.number(req.finishPasses);
    w.raw("}");
    if (req.hasSetup)
    {
        w.raw(",\"setupReceipt\":");
        emitSetupReceipt(w, s, turning::toolProfileOutline(s.insertShape, s.insertEdgeLengthMM,
                                                           s.insertRotationDegrees));
    }
    w.raw("}");
    return w.str();
}

} // namespace

char *fm_turn_plan(const char *request_json, FMProgress callback, void *context)
{
    std::string result;
    try
    {
        if (!request_json)
            result = errorJson("request JSON is null");
        else
            result = plan(request_json, callback, context);
    }
    catch (const turning::Cancelled &)
    {
        result = errorJson("cancelled");
    }
    catch (const fmjson::ParseError &e)
    {
        result = errorJson(std::string("invalid request JSON: ") + e.msg);
    }
    catch (const std::exception &e)
    {
        result = errorJson(e.what());
    }
    catch (...)
    {
        result = errorJson("unknown internal error");
    }
    return dupCStr(result);
}

void fm_turn_free(char *json)
{
    std::free(json);
}

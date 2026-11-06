/*
 * turn_ops.h — mechanical C++ port of LibLathe turning operations
 * (liblathe/op/{base,face,rough,profile}.py and the tool-shape builders of
 * liblathe/tool/tool.py) from dubstar-04/LibLathe
 * @ 4bac3400813f40a15e0bf22e12998453e337d96e (GPL-2.0).
 *
 * The geometric heavy lifting (Segment/SegmentGroup offset/defeature via the
 * quadtree, intersections, point-in-region) is performed by the vendored,
 * unmodified LibLathe C++ core in ../Vendor/liblathe — this file only
 * re-expresses the Python operation flow in C++.
 */
#ifndef TURN_OPS_H
#define TURN_OPS_H

#include <string>
#include <vector>

#include "../include/TurningNative.h"

#include "../Vendor/liblathe/base/boundbox.h"
#include "../Vendor/liblathe/base/point.h"
#include "../Vendor/liblathe/base/segment.h"
#include "../Vendor/liblathe/base/segmentgroup.h"

#include "turn_tool.h"

namespace turning
{

/* Thrown when the progress callback requests cancellation. */
struct Cancelled
{
};

/* Cooperative cancellation hook; checked between passes. */
class Progress
{
public:
    Progress(FMProgress cb, void *ctx) : callback(cb), context(ctx) {}

    /* Returns true when the caller requested cancellation. */
    bool poll(double fraction, const char *phase)
    {
        return callback != nullptr && callback(context, fraction, phase) != 0;
    }

private:
    FMProgress callback;
    void *context;
};

/* BaseOP — port of liblathe/op/base.py::BaseOP. */
class BaseOP
{
public:
    BaseOP();

    void addStock(const BoundBox &stockBox) { stock = stockBox; }
    void addToolShape(const SegmentGroup &toolShape) { tool = toolShape; }
    void addPartSegments(const std::vector<Segment> &partSegments);

    /* Generate paths; throws std::runtime_error / std::invalid_argument on
     * failure (mirrors the Python ops raising ValueError/Warning). */
    virtual std::vector<SegmentGroup> generatePath(Progress &progress) = 0;
    virtual ~BaseOP() = default;

protected:
    BoundBox stock;
    SegmentGroup tool;
    SegmentGroup partSegmentGroup;

    bool allowGrooving = false;
    float stepOver = 1.5f;
    int finishPasses = 1;
    float stockToLeave = 0.0f;
    float hfeed = 100.0f;
    float vfeed = 50.0f;
    float clearance = 3.0f;

    float leadinAngle = static_cast<float>(M_PI) * 1.5f;
    float leadoutAngle = static_cast<float>(M_PI) * 1.75f;

    friend struct OpParams;
};

/* Parameter application shared by all ops (mirrors BaseOP.setParams).
 * `setup` is the resolved R4 turningSetup, or nullptr to keep the exact
 * pre-R4 behaviour (clearance 3, legacy scalar feed on both axes, no
 * grooving, default lead angles). */
struct OpParams
{
    static void apply(BaseOP &op, float stepOverMM, float allowanceMM, int finishPasses,
                      float feedMMPerMinute, const TurningSetup *setup);
};

/* FaceOP — port of liblathe/op/face.py::FaceOP. */
class FaceOP : public BaseOP
{
public:
    std::vector<SegmentGroup> generatePath(Progress &progress) override;
};

/* RoughOP — port of liblathe/op/rough.py::RoughOP. */
class RoughOP : public BaseOP
{
public:
    std::vector<SegmentGroup> generatePath(Progress &progress) override;
};

/* ProfileOP — port of liblathe/op/profile.py::ProfileOP. */
class ProfileOP : public BaseOP
{
public:
    std::vector<SegmentGroup> generatePath(Progress &progress) override;

private:
    void addLeadin(SegmentGroup &segmentgroup);
};

/*
 * The 2D insert shape is built by turning::buildInsertShape() (turn_tool.h),
 * the mechanical port of tool.py's shape builders. The legacy tool is
 * buildInsertShape('D', 6.35, 0) — the fixed insert equivalent to upstream's
 * "DCMT070204R" (rhombic 55 deg, edge length 6.35 mm, tip at the origin, no
 * rotation). The nose radius is ignored by the pinned upstream builders and
 * by this port; nothing here claims nose-radius compensation.
 */

} // namespace turning

#endif /* TURN_OPS_H */

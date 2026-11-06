/*
 * turn_ops.cpp — implementation of the ported LibLathe turning operations.
 * Line-for-line fidelity to the Python originals is preserved where
 * practical; deviations are marked with PORT NOTE comments.
 */
#include "turn_ops.h"

#include <cmath>
#include <stdexcept>

namespace turning
{

BaseOP::BaseOP() : stock(Point(0, 0), Point(0, 0))
{
}

void BaseOP::addPartSegments(const std::vector<Segment> &partSegments)
{
    for (const auto &segment : partSegments)
        partSegmentGroup.addSegment(segment);
    partSegmentGroup.validate();
}

void OpParams::apply(BaseOP &op, float stepOverMM, float allowanceMM, int finishPasses,
                     float feedMMPerMinute, const TurningSetup *setup)
{
    op.stepOver = stepOverMM;
    op.stockToLeave = allowanceMM;
    op.finishPasses = finishPasses;
    if (setup)
    {
        op.hfeed = setup->horizontalFeedMMPerMinute;
        op.vfeed = setup->verticalFeedMMPerMinute;
        op.allowGrooving = setup->allowGrooving;
        op.clearance = setup->clearanceMM;
        op.leadinAngle = static_cast<float>(setup->leadinAngleDegrees) * static_cast<float>(M_PI) / 180.0f;
        op.leadoutAngle = static_cast<float>(setup->leadoutAngleDegrees) * static_cast<float>(M_PI) / 180.0f;
    }
    else
    {
        op.hfeed = feedMMPerMinute;
        op.vfeed = feedMMPerMinute;
        op.allowGrooving = false;
        op.clearance = 3.0f;
        op.leadinAngle = static_cast<float>(M_PI) * 1.5f;
        op.leadoutAngle = static_cast<float>(M_PI) * 1.75f;
    }
}

/* ---------------- FaceOP (face.py) ---------------- */

std::vector<SegmentGroup> FaceOP::generatePath(Progress &progress)
{
    std::vector<SegmentGroup> clearingPaths;
    BoundBox partBoundbox = partSegmentGroup.boundbox();

    float XMin = stock.XMin;
    float XMax = stock.XMax + clearance;
    float ZMin = partBoundbox.ZMax + stockToLeave;
    float ZMax = std::ceil(stock.ZMax) + stepOver;

    /* work backwards from ZMin to ZMax adding a segmentgroup for each stepover */
    float z_pos = ZMin;
    while (z_pos < ZMax)
    {
        if (progress.poll(0.05, "face"))
            throw Cancelled{};

        SegmentGroup segmentgroup;
        Point pt1(XMax, z_pos);
        Point pt2(XMin, z_pos);
        segmentgroup.addSegment(Segment(pt1, pt2));

        Point pt3 = pt2.project(leadoutAngle, stepOver);
        segmentgroup.addSegment(Segment(pt2, pt3));
        z_pos += stepOver;
        clearingPaths.push_back(segmentgroup);
    }

    /* face.py emits reversed(clearing_paths) for gcode ordering */
    std::reverse(clearingPaths.begin(), clearingPaths.end());
    return clearingPaths;
}

/* ---------------- RoughOP (rough.py) ---------------- */

namespace
{
struct Intersection
{
    Point point;
    Segment seg; /* PORT NOTE: Python keeps the (possibly None) owning segment;
                    an empty segmentgroup marker stands in for None. */
    bool hasSeg = false;
};
} // namespace

std::vector<SegmentGroup> RoughOP::generatePath(Progress &progress)
{
    std::vector<SegmentGroup> toolPaths;
    SegmentGroup roughingSegmentGroup =
        partSegmentGroup.defeature(stock, tool, allowGrooving);

    /* internal segment group to check if it intersects the part */
    SegmentGroup internalOffset = roughingSegmentGroup.offset(-0.1f);

    float ZMax = stock.ZMax;
    float ZMin = stock.ZMin;

    /* roughing boundary offset by stock-to-leave plus a minimal offset */
    float offset = 0.01f + stockToLeave;
    SegmentGroup roughingBoundary = roughingSegmentGroup.offset(offset);

    float XMin = stock.XMin;
    float XMax = std::ceil(stock.XMax);

    float roughingBoundaryX = roughingBoundary.getSegments().front().start.X;
    float x_pos = std::max(1e-6f, std::max(XMin, roughingBoundaryX));

    while (x_pos < XMax)
    {
        if (progress.poll(0.1 + 0.5 * (x_pos / std::max(XMax, 1.0f)), "rough"))
            throw Cancelled{};

        Point pt1(x_pos, ZMax);
        Point pt2(x_pos, ZMin);
        Segment pathLine(pt1, pt2);
        std::vector<Intersection> intersections;
        for (auto &seg : roughingBoundary.getSegments())
        {
            std::vector<Point> points = seg.intersect(pathLine, false);
            for (auto &p : points)
                intersections.push_back({p, seg, true});
        }

        SegmentGroup segmentgroup;

        if (intersections.empty())
        {
            /* add passes with no intersections only if outside the part radius */
            if (x_pos >= roughingBoundary.boundbox().XMax)
                segmentgroup.addSegment(pathLine);
        }

        if (intersections.size() == 1)
        {
            segmentgroup.addSegment(Segment(pt1, intersections[0].point));
            if (intersections[0].hasSeg)
            {
                Point startPt = intersections[0].point;
                Point endPt = startPt.project(leadoutAngle, stepOver);
                segmentgroup.addSegment(Segment(startPt, endPt));
            }
        }

        if (intersections.size() > 1)
        {
            if (!roughingBoundary.isInside(pt1))
                intersections.insert(intersections.begin(), {pt1, Segment(), false});
            if (!roughingBoundary.isInside(pt2))
                intersections.push_back({pt2, Segment(), false});

            std::sort(intersections.begin(), intersections.end(),
                      [](const Intersection &a, const Intersection &b) {
                          return a.point.Z > b.point.Z;
                      });

            for (size_t i = 0; i < intersections.size(); ++i)
            {
                if (i + 1 < intersections.size())
                {
                    if (i % 2 == 0)
                    {
                        Segment primarySegment(intersections[i].point, intersections[i + 1].point);
                        if (primarySegment.getLength() < stepOver)
                            continue;

                        if (intersections[i].hasSeg)
                        {
                            Point endPt = intersections[i].point;
                            Point startPt = endPt.project(leadinAngle, stepOver);
                            segmentgroup.addSegment(Segment(startPt, endPt));
                        }

                        segmentgroup.addSegment(primarySegment);

                        if (intersections[i + 1].hasSeg)
                        {
                            Point startPt = intersections[i + 1].point;
                            Point endPt = startPt.project(leadoutAngle, stepOver);
                            segmentgroup.addSegment(Segment(startPt, endPt));
                        }
                    }
                }
            }
        }

        x_pos += stepOver;

        if (segmentgroup.count())
        {
            if (segmentgroup.intersectsGroup(internalOffset))
                throw std::runtime_error("Calculated roughing path intersects part");
            toolPaths.push_back(segmentgroup);
        }
    }

    /* rough.py emits reversed(tool_paths) for gcode ordering */
    std::reverse(toolPaths.begin(), toolPaths.end());
    return toolPaths;
}

/* ---------------- ProfileOP (profile.py) ---------------- */

std::vector<SegmentGroup> ProfileOP::generatePath(Progress &progress)
{
    std::vector<SegmentGroup> toolPaths;
    SegmentGroup profileSegmentGroup =
        partSegmentGroup.defeature(stock, tool, allowGrooving);
    SegmentGroup internalOffset = profileSegmentGroup.offset(-0.1f);

    SegmentGroup baseSegmentGroup = profileSegmentGroup.offset(stockToLeave);
    addLeadin(baseSegmentGroup);

    int f_pass = 0;
    while (f_pass < finishPasses)
    {
        if (progress.poll(0.7 + 0.05 * f_pass, "profile"))
            throw Cancelled{};

        SegmentGroup segmentgroup;
        segmentgroup.extend(baseSegmentGroup.offset(stepOver * f_pass));
        if (segmentgroup.intersectsGroup(internalOffset))
            throw std::runtime_error("Calculated profile path intersects part");

        toolPaths.push_back(segmentgroup);
        f_pass += 1;
    }
    return toolPaths;
}

void ProfileOP::addLeadin(SegmentGroup &segmentgroup)
{
    Segment segment = segmentgroup.getSegments().front();
    float z_pos;
    if (segment.start.Z < stock.ZMax)
        z_pos = stock.ZMax;
    else
        z_pos = segment.start.Z + clearance;
    Point startPoint(segment.start.X, z_pos);
    Point endPoint = segment.start;
    segmentgroup.insertSegment(Segment(startPoint, endPoint), 0);
}

} // namespace turning

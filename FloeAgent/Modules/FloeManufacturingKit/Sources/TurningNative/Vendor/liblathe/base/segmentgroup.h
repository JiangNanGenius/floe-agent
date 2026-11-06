#ifndef SegmentGroup_H
#define SegmentGroup_H

#include <algorithm>
#include <array>

#include "boundbox.h"
#include "point.h"
#include "utils.h"
#include "segment.h"

class SegmentGroup
{
public:
    static constexpr float offsetTolerance = 0.05f;

    SegmentGroup();
    ~SegmentGroup() {};

    void addSegment(Segment segment);
    void insertSegment(Segment segment, int position);
    std::vector<Segment> getSegments();
    // C++ accessor without copying geometry; throws invalid_argument if empty.
    const Point &getStartPoint() const;
    void extend(SegmentGroup segmentgroup);
    int count();
    BoundBox boundbox();
    bool intersectsGroup(SegmentGroup segmentGroup);
    // Throws invalid_argument for empty geometry or nonfinite offsets,
    // runtime_error if fewer than two distinct contour points are produced or
    // connecting chords cannot be certified within offsetTolerance.
    SegmentGroup offset(float step_over);
    // C++ extraction/simplification guard; empty and single-point contours are
    // handled separately by offset(). Does not certify contour completeness.
    void validateOffsetContour(const std::vector<Point> &points, float offset);
    SegmentGroup defeature(BoundBox stock, SegmentGroup tool, bool allow_grooving);
    void validate();
    SegmentGroup fromPoints(std::vector<Point> points);
    std::vector<Point> reduce(std::vector<Point> &points, float tolerance);
    // Ordered, connected lines/arcs must form a simple region with their axis
    // closure. Open endpoints close radially to X=0 and along the axis.
    // Endpoints at the same Z close directly; closed profiles add no edges.
    // Boundary points count as inside. Empty geometry throws invalid_argument.
    bool isInside(Point point);
    // Signed distance to that complete boundary: negative inside, zero on it,
    // positive outside. Query points must be finite.
    float sdv(Point point);
    // Nearest point on the same boundary. Original geometry wins exact ties.
    // If supplied, onProfile distinguishes original from artificial edges.
    Point closestPoint(Point point, bool *onProfile = nullptr);

private:
    friend class Quadtree;
    struct PreparedSegment
    {
        struct Interval
        {
            double startX;
            double endX;
            bool positiveZ;
        };
        Segment segment;
        Segment::ArcGeometry arc;
        std::array<Interval, 3> intervals{};
        size_t intervalCount = 0;
        explicit PreparedSegment(Segment source);
        int crossings(const Point &point) const;
    };
    struct PreparedGeometry
    {
        std::vector<PreparedSegment> boundary;
        size_t originalCount = 0;
        Point closestPoint(Point point, bool *onProfile = nullptr) const;
        float unsignedDistance(Point point) const;
        float sdv(Point point) const;
        bool isInside(Point point) const;
        void validateContour(const std::vector<Point> &points, float offset) const;
        void validateChord(Point start, Point end, float offset) const;
    };
    PreparedGeometry prepareGeometry();
    std::vector<Segment> segments;
    std::array<Segment, 3> axisClosure();
    void rdp(std::vector<Point> &points, float tolerance, std::vector<Point> &out);
    SegmentGroup copy();
};

#endif

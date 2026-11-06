#include <iostream>
#include <cmath>
#include <stdexcept>
#include <array>
#include <limits>

#include "segmentgroup.h"
#include "quadtree.h"

namespace
{
BoundBox intersectionBounds(Segment segment)
{
    BoundBox bounds = segment.Boundbox();
    const float scale = std::max({1.0f, std::abs(bounds.XMin), std::abs(bounds.XMax),
                                 std::abs(bounds.ZMin), std::abs(bounds.ZMax)});
    // The arc narrow phase rounds radial membership to two decimals.
    const float padding = 1e-4f + (segment.bulge != 0 ? 0.01f : 0.0f) +
                          4 * std::numeric_limits<float>::epsilon() * scale;
    bounds.XMin -= padding;
    bounds.XMax += padding;
    bounds.ZMin -= padding;
    bounds.ZMax += padding;
    return bounds;
}

struct IntersectionSegment
{
    Segment segment;
    BoundBox bounds;
    explicit IntersectionSegment(Segment source)
        : segment(source), bounds(intersectionBounds(source)) {}
};

std::vector<IntersectionSegment> prepareIntersections(const std::vector<Segment> &segments)
{
    std::vector<IntersectionSegment> prepared;
    prepared.reserve(segments.size());
    for (const auto &segment : segments)
        prepared.emplace_back(segment);
    return prepared;
}

bool boundsOverlap(const BoundBox &first, const BoundBox &second)
{
    return !(first.XMax < second.XMin || first.XMin > second.XMax ||
             first.ZMax < second.ZMin || first.ZMin > second.ZMax);
}

bool intersectsAt(const std::vector<IntersectionSegment> &part,
                  const std::vector<IntersectionSegment> &tool, const Point &position)
{
    for (const auto &edge : tool)
    {
        BoundBox bounds = edge.bounds;
        bounds.XMin += position.X;
        bounds.XMax += position.X;
        bounds.ZMin += position.Z;
        bounds.ZMax += position.Z;
        for (const auto &target : part)
        {
            if (!boundsOverlap(bounds, target.bounds))
                continue;
            Segment translated(
                Point(edge.segment.start.X + position.X, edge.segment.start.Z + position.Z),
                Point(edge.segment.end.X + position.X, edge.segment.end.Z + position.Z),
                edge.segment.bulge);
            if (!translated.intersect(target.segment, false).empty())
                return true;
        }
    }
    return false;
}
}

SegmentGroup::SegmentGroup()
{
}

void SegmentGroup::addSegment(Segment segment)
{
    // Add segment to group //
    this->segments.push_back(segment);
}

void SegmentGroup::insertSegment(Segment segment, int position)
{
    // Insert segment into group at position //
    segments.insert(segments.begin() + position, segment);
}

std::vector<Segment> SegmentGroup::getSegments()
{
    // Return segments //
    return this->segments;
}

const Point &SegmentGroup::getStartPoint() const
{
    if (this->segments.empty())
        throw std::invalid_argument("Cannot get start point of empty geometry");
    return this->segments.front().start;
}

void SegmentGroup::extend(SegmentGroup segmentgroup)
{
    // Add segment group to this segmentgroup //
    std::vector<Segment> segs = segmentgroup.getSegments();
    this->segments.insert(segments.end(), segs.begin(), segs.end());
}

int SegmentGroup::count()
{
    // Return the number of segments in the segmentgroup //
    return this->segments.size();
}

BoundBox SegmentGroup::boundbox()
{
    // Return the boundbox for the segmentgroup //

    if (this->count() == 0)
    {
        return BoundBox(Point(), Point());
    }

    std::vector<float> xvalues;
    std::vector<float> zvalues;

    // collect all points from each segment by direction
    for (auto &segment : this->segments)
    {
        BoundBox bb = segment.Boundbox();

        xvalues.push_back(bb.XMin);
        xvalues.push_back(bb.XMax);

        zvalues.push_back(bb.ZMin);
        zvalues.push_back(bb.ZMax);
    }

    float XMin = *std::min_element(std::begin(xvalues), std::end(xvalues));
    float XMax = *std::max_element(std::begin(xvalues), std::end(xvalues));
    float ZMin = *std::min_element(zvalues.begin(), zvalues.end());
    float ZMax = *std::max_element(zvalues.begin(), zvalues.end());

    Point pt1 = Point(XMin, ZMin);
    Point pt2 = Point(XMax, ZMax);
    BoundBox segmentgroupBoundBox = BoundBox(pt1, pt2);

    return segmentgroupBoundBox;
}

bool SegmentGroup::intersectsGroup(SegmentGroup segmentGroup)
{
    return intersectsAt(prepareIntersections(this->segments),
                        prepareIntersections(segmentGroup.segments), Point());
}

SegmentGroup SegmentGroup::offset(float step_over)
{
    // Create an offset segmentgroup by the distance of step_over //
    if (this->count() == 0)
    {
        throw std::invalid_argument("Cannot offset empty geometry");
    }
    if (!std::isfinite(step_over))
    {
        throw std::invalid_argument("Offset must be finite");
    }

    BoundBox bb = this->boundbox();
    // Pad the half-open root without extending the search past the axis.
    float padding = std::abs(step_over) + Quadtree::defaultPrecision;
    float xmin = std::min(0.0f, bb.XMin);
    float zmin = bb.ZMin - padding;
    float size = std::max(bb.XMax + padding - xmin, bb.ZLength() + 2 * padding);
    Point center = Point(xmin + size / 2, zmin + size / 2);

    Quadtree qt = Quadtree();
    qt.initialise(this, center, size, size);
    std::vector<Point> offset = qt.getOffset(step_over);
    offset.erase(std::unique(offset.begin(), offset.end(),
                             [](Point first, Point second) { return first.isSame(second); }),
                 offset.end());
    if (offset.empty())
    {
        throw std::runtime_error("Offset produced no points");
    }
    if (offset.size() < 2)
    {
        throw std::runtime_error("Offset produced fewer than two points");
    }

    // attempt simplification
    float resolution = 0.01;
    std::vector<Point> defeatured_points;
    this->rdp(offset, resolution, defeatured_points);
    qt.validateContour(defeatured_points);
    return this->fromPoints(defeatured_points);
}

void SegmentGroup::validateOffsetContour(const std::vector<Point> &points, float offset)
{
    this->prepareGeometry().validateContour(points, offset);
}

void SegmentGroup::PreparedGeometry::validateContour(
    const std::vector<Point> &points, float offset) const
{
    if (points.size() < 2)
        return;
    if (offset != 0)
    {
        for (const Point &point : points)
        {
            const double magnitude = std::max({1.0, std::abs(double(point.X)),
                                              std::abs(double(point.Z)), std::abs(double(offset))});
            const double numerical = 1e-5 + 4 * std::numeric_limits<float>::epsilon() * magnitude;
            if (std::abs(offset) <= numerical)
                continue;
            std::vector<Point> nearest;
            for (const auto &prepared : this->boundary)
            {
                Point closest = prepared.segment.closestPointPrepared(point, prepared.arc);
                const double distance = std::hypot(double(closest.X) - point.X,
                                                   double(closest.Z) - point.Z);
                if (std::abs(distance - std::abs(offset)) > numerical)
                    continue;
                // Opposite nearest normals identify a zero-width level-set branch.
                for (const Point &other : nearest)
                {
                    if (std::hypot(double(closest.X) + other.X - 2 * double(point.X),
                                   double(closest.Z) + other.Z - 2 * double(point.Z)) <=
                        2 * numerical)
                        throw std::runtime_error(
                            "Offset contour contains a collapsed branch; "
                            "zero-width contours are not supported");
                }
                nearest.push_back(closest);
            }
        }
    }
    for (size_t i = 1; i < points.size(); ++i)
        this->validateChord(points[i - 1], points[i], offset);
}

void SegmentGroup::PreparedGeometry::validateChord(Point start, Point end, float offset) const
{
    Point midpoint = start.mid(end);
    const double residual = std::abs(double(this->sdv(midpoint)) - offset);
    const double magnitude = std::max({1.0, std::abs(double(midpoint.X)),
                                      std::abs(double(midpoint.Z)), std::abs(double(offset))});
    const double numerical = 1e-5 + 4 * std::numeric_limits<float>::epsilon() * magnitude;
    if (residual > offsetTolerance)
        throw std::runtime_error(
            "Offset contour exceeds 0.05 model-unit accuracy; "
            "collapsed or disconnected contours are not supported");

    // The signed distance is 1-Lipschitz: bound the entire chord from its midpoint.
    const double radius = std::max(
        std::hypot(double(start.X) - midpoint.X, double(start.Z) - midpoint.Z),
        std::hypot(double(end.X) - midpoint.X, double(end.Z) - midpoint.Z));
    if (residual + numerical + radius <= offsetTolerance)
        return;
    if ((midpoint.X == start.X && midpoint.Z == start.Z) ||
        (midpoint.X == end.X && midpoint.Z == end.Z))
        throw std::runtime_error(
            "Cannot certify offset contour within 0.05 model units at coordinate precision");
    this->validateChord(start, midpoint, offset);
    this->validateChord(midpoint, end, offset);
}

SegmentGroup SegmentGroup::defeature(BoundBox stock, SegmentGroup tool, bool allow_grooving = false)
{
    // Defeature the segment group. Remove features that cannot be turned. e.g. undercuts / grooves etc //

    float XMin = 0;
    float XMax = stock.XMax;
    float ZMin = stock.ZMin;
    float ZMax = stock.ZMax;
    float resolution = 0.01;

    std::vector<Point> points;

    // get start position
    BoundBox partBounds = this->boundbox();
    const auto part = prepareIntersections(this->segments);
    std::vector<IntersectionSegment> toolEdges;
    toolEdges.reserve(tool.segments.size());
    // Preserve the chord footprint used by the previous tool translation.
    for (const auto &segment : tool.segments)
        toolEdges.emplace_back(Segment(segment.start, segment.end));
    Point start = Point(0, partBounds.ZMax);

    if (start.X > 0)
    {
        throw std::runtime_error("segment groups first segment must be at x = 0");
    }

    if (partBounds.ZMax < stock.ZMax)
    {
        while (intersectsAt(part, toolEdges, start))
        {
            // move the tool along the z axis until it no longer intersects the part.
            start = start.add(Point(0, resolution));
        }

        points.push_back(start);
    }

    float z_pos = start.Z;
    while (z_pos > ZMin)
    {
        // test for intersection at z with a single segment
        Segment test_segment = Segment(Point(XMax, z_pos), Point(XMin, z_pos));
        const BoundBox testBounds = intersectionBounds(test_segment);
        for (const auto &edge : part)
        {
            if (!boundsOverlap(testBounds, edge.bounds))
                continue;
            std::vector<Point> pts = test_segment.intersect(edge.segment, false);
            if (pts.size() > 0)
            {
                float x_pos = pts[0].X - resolution;
                while (x_pos < (pts[0].X + resolution))
                {
                    Point iteration_position = Point(x_pos, z_pos);
                    if (!intersectsAt(part, toolEdges, iteration_position))
                    {

                        // if allow_grooving is false
                        if (points.size() > 1 && allow_grooving == false)
                        {
                            float last_x = points.back().X;
                            if (x_pos < last_x)
                            {
                                iteration_position.X = last_x;
                            }
                        }

                        points.push_back(iteration_position);
                        break;
                    }
                    x_pos += resolution * 0.5;
                }
                break;
            }
        }

        z_pos -= resolution;
    }

    // attempt simplification
    std::vector<Point> defeatured_points;
    this->rdp(points, resolution, defeatured_points);
    return this->fromPoints(defeatured_points);
}

SegmentGroup SegmentGroup::fromPoints(std::vector<Point> points)
{
    // create a segment group from a vector of points //
    SegmentGroup segmentGroup = SegmentGroup();

    if (points.size() > 0)
    {
        for (int i = 0; i < points.size(); i++)
        {
            if (i >= 1)
            {
                Segment seg = Segment(points[i - 1], points[i]);
                segmentGroup.addSegment(seg);
            }
        }
    }

    return segmentGroup;
}

SegmentGroup SegmentGroup::copy()
{
    // create a copy of the segment group //
    SegmentGroup segmentGroup = SegmentGroup();

    for (auto &segment : this->segments)
    {
        Point start = Point(segment.start.X, segment.start.Z);
        Point end = Point(segment.end.X, segment.end.Z);
        segmentGroup.addSegment(Segment(start, end, segment.bulge));
    }

    return segmentGroup;
}

std::vector<Point> SegmentGroup::reduce(std::vector<Point> &points, float tolerance)
{
    std::vector<Point> out;
    this->rdp(points, tolerance, out);
    return out;
}

void SegmentGroup::rdp(std::vector<Point> &points, float tolerance, std::vector<Point> &out)
{
    // reduce the number of points in the segmentgroup using a Ramer–Douglas–Peucker algorithm

    if (points.size() < 2)
    {
        throw std::runtime_error("SegmentGroup error not enough points to simplify group");
    }

    // Find the point with the maximum distance from line between start and end
    double dmax = 0.0;
    size_t index = 0;
    size_t end = points.size() - 1;
    for (size_t i = 1; i < end; i++)
    {
        double d = Segment(points[0], points[end]).distanceToPoint(points[i]);
        if (d > dmax)
        {
            index = i;
            dmax = d;
        }
    }

    // If max distance is greater than tolerance, recursively simplify
    if (dmax > tolerance)
    {
        // Recursive call
        std::vector<Point> recResults1;
        std::vector<Point> recResults2;
        std::vector<Point> firstLine(points.begin(), points.begin() + index + 1);
        std::vector<Point> lastLine(points.begin() + index, points.end());
        this->rdp(firstLine, tolerance, recResults1);
        this->rdp(lastLine, tolerance, recResults2);

        // Build the result list
        out.assign(recResults1.begin(), recResults1.end() - 1);
        out.insert(out.end(), recResults2.begin(), recResults2.end());
        if (out.size() < 2)
        {
            throw std::runtime_error("SegmentGroup error when performing point reduction");
        }
    }
    else
    {
        // Just return start and end points
        out.clear();
        out.push_back(points[0]);
        out.push_back(points[end]);
    }
}

void SegmentGroup::validate()
{
    // validate the segment group//

    // check each segment is connected

    // check that the group is open i.e, the start and end points are not connected

    // check that the start and end points are at x = 0 (only valid for the primary group / part shape)
}

std::array<Segment, 3> SegmentGroup::axisClosure()
{
    if (this->segments.empty())
        throw std::invalid_argument("Cannot evaluate empty geometry");

    const Point start = this->segments.front().start;
    const Point end = this->segments.back().end;
    // Radial closures at the same Z overlap; retain only their uncancelled part.
    if (start.Z == end.Z)
        return {Segment(end, start), Segment(start, start), Segment(start, start)};
    return {
        Segment(Point(0, start.Z), start),
        Segment(end, Point(0, end.Z)),
        Segment(Point(0, end.Z), Point(0, start.Z))
    };
}

Point SegmentGroup::closestPoint(Point point, bool *onProfile)
{
    return this->prepareGeometry().closestPoint(point, onProfile);
}

SegmentGroup::PreparedGeometry SegmentGroup::prepareGeometry()
{
    const auto closure = this->axisClosure();
    PreparedGeometry prepared;
    prepared.originalCount = this->segments.size();
    prepared.boundary.reserve(this->segments.size() + closure.size());
    for (const auto &segment : this->segments)
        prepared.boundary.emplace_back(segment);
    for (const auto &segment : closure)
        prepared.boundary.emplace_back(segment);
    return prepared;
}

Point SegmentGroup::PreparedGeometry::closestPoint(Point point, bool *onProfile) const
{
    if (!std::isfinite(point.X) || !std::isfinite(point.Z))
        throw std::invalid_argument("Query point must be finite");
    Point closest = this->boundary.front().segment.start;
    double closestDistance = std::numeric_limits<double>::infinity();
    bool closestOnProfile = true;
    auto consider = [&](const PreparedSegment &prepared, bool original) {
        Point pnt = prepared.segment.closestPointPrepared(point, prepared.arc);
        if (!std::isfinite(pnt.X) || !std::isfinite(pnt.Z))
            throw std::runtime_error("Boundary closest point is not finite");
        const double dx = double(pnt.X) - point.X;
        const double dz = double(pnt.Z) - point.Z;
        const double distance = dx * dx + dz * dz;
        if (distance < closestDistance)
        {
            closest = pnt;
            closestDistance = distance;
            closestOnProfile = original;
        }
    };
    for (size_t i = 0; i < this->boundary.size(); ++i)
        consider(this->boundary[i], i < this->originalCount);
    if (onProfile != nullptr)
        *onProfile = closestOnProfile;
    return closest;
}

float SegmentGroup::sdv(Point point)
{
    return this->prepareGeometry().sdv(point);
}

float SegmentGroup::PreparedGeometry::unsignedDistance(Point point) const
{
    return this->closestPoint(point).distanceTo(point);
}

float SegmentGroup::PreparedGeometry::sdv(Point point) const
{
    const float distance = this->unsignedDistance(point);
    return this->isInside(point) ? -distance : distance;
}

bool SegmentGroup::isInside(Point point)
{
    return this->prepareGeometry().isInside(point);
}

SegmentGroup::PreparedSegment::PreparedSegment(Segment source)
    : segment(source), arc(this->segment.prepareArc())
{
    if (segment.bulge == 0 ||
        (segment.start.X == segment.end.X && segment.start.Z == segment.end.Z))
        return;
    const double pi = std::acos(-1.0);
    std::array<std::pair<double, double>, 4> breaks;
    breaks[0] = {0, segment.start.X};
    breaks[1] = {arc.sweep, segment.end.X};
    size_t count = 2;
    for (double angle : {0.0, pi})
    {
        const double position = std::fmod(
            arc.direction * (angle - arc.startAngle) + 2 * pi, 2 * pi);
        if (position > 0 && position < arc.sweep)
            breaks[count++] = {position, arc.centre.X + (angle == 0 ? arc.radius : -arc.radius)};
    }
    std::sort(breaks.begin(), breaks.begin() + count);
    for (size_t i = 1; i < count; ++i)
    {
        const double middle = arc.startAngle + arc.direction *
                              (breaks[i - 1].first + breaks[i].first) / 2;
        intervals[intervalCount++] = {
            breaks[i - 1].second, breaks[i].second, std::sin(middle) > 0};
    }
}

int SegmentGroup::PreparedSegment::crossings(const Point &point) const
{
    // Return -1 on the boundary; otherwise count crossings above the query.
    const Point start = segment.start;
    const Point end = segment.end;
    if (point.X == start.X && point.Z == start.Z)
        return -1;
    if (point.X == end.X && point.Z == end.Z)
        return -1;
    if (segment.bulge == 0 || (start.X == end.X && start.Z == end.Z))
    {
        const double dx = double(end.X) - start.X;
        const double dz = double(end.Z) - start.Z;
        const double cross = dx * (double(point.Z) - start.Z) -
                             dz * (double(point.X) - start.X);
        if (cross == 0 &&
            point.X >= std::min(start.X, end.X) && point.X <= std::max(start.X, end.X) &&
            point.Z >= std::min(start.Z, end.Z) && point.Z <= std::max(start.Z, end.Z))
            return -1;
        if ((start.X > point.X) == (end.X > point.X))
            return 0;
        const double z = start.Z + (double(point.X) - start.X) * dz / dx;
        return z > point.Z ? 1 : 0;
    }

    const Point centre = arc.centre;
    const double radius = arc.radius;
    const double pi = std::acos(-1.0);
    const double direction = arc.direction;
    const double sweep = arc.sweep;
    const double startAngle = arc.startAngle;
    auto progress = [&](double angle) {
        return std::fmod(direction * (angle - startAngle) + 2 * pi, 2 * pi);
    };
    const double px = double(point.X) - centre.X;
    const double pz = double(point.Z) - centre.Z;
    const double epsilon = 4 * std::numeric_limits<float>::epsilon();
    if (std::abs(px * px + pz * pz - radius * radius) <=
            epsilon * radius * radius &&
        progress(std::atan2(pz, px)) <= sweep + epsilon)
        return -1;

    const double discriminant = radius * radius - px * px;
    if (discriminant <= 0)
        return 0;
    const double height = std::sqrt(discriminant);
    int result = 0;
    for (size_t i = 0; i < intervalCount; ++i)
    {
        const auto &interval = intervals[i];
        if ((interval.startX > point.X) == (interval.endX > point.X))
            continue;
        const double z = centre.Z + (interval.positiveZ ? height : -height);
        if (z > point.Z)
            ++result;
    }
    return result;
}

bool SegmentGroup::PreparedGeometry::isInside(Point point) const
{
    int intersections = 0;
    for (const auto &segment : this->boundary)
    {
        const int count = segment.crossings(point);
        if (count < 0)
            return true;
        intersections += count;
    }
    return intersections % 2 != 0;
}

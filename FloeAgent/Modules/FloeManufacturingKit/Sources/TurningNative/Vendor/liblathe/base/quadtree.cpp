#include <iostream>
#include <limits>
#include <cmath>
#include <stdexcept>
#include <cstdint>
#include <unordered_map>

#include "quadtree.h"

namespace
{
constexpr const char *orderingError = "Quadtree error when ordering offset points";

struct PointCell
{
    int64_t x;
    int64_t z;
    bool operator==(const PointCell &other) const
    {
        return x == other.x && z == other.z;
    }
};

struct PointCellHash
{
    size_t operator()(const PointCell &cell) const
    {
        const size_t x = std::hash<int64_t>{}(cell.x);
        const size_t z = std::hash<int64_t>{}(cell.z);
        return x ^ (z + size_t(0x9e3779b9) + (x << 6) + (x >> 2));
    }
};

struct PointBucket
{
    std::vector<size_t> indices;
    float xmin = std::numeric_limits<float>::infinity();
    float xmax = -std::numeric_limits<float>::infinity();
    float zmin = std::numeric_limits<float>::infinity();
    float zmax = -std::numeric_limits<float>::infinity();

    float lowerBound(const Point &point) const
    {
        const float dx = std::max({0.0f, xmin - point.X, point.X - xmax});
        const float dz = std::max({0.0f, zmin - point.Z, point.Z - zmax});
        return std::sqrt(dx * dx + dz * dz);
    }
};

class PointGrid
{
public:
    PointGrid(const std::vector<Point> &points, float precision) : points(points)
    {
        float zmin = points.front().Z;
        float zmax = zmin;
        for (const auto &point : points)
        {
            zmin = std::min(zmin, point.Z);
            zmax = std::max(zmax, point.Z);
        }
        originX = points.front().X;
        originZ = zmin;
        const double spanX = double(points.back().X) - originX;
        const double spanZ = double(zmax) - originZ;
        // Bound keys with ample headroom for ring offsets and double arithmetic.
        width = std::max(double(precision),
                         std::max(spanX, spanZ) / std::numeric_limits<int32_t>::max());
        // Inset search boundaries to account for rounding in the grid arithmetic.
        roundingSlack = 8 * std::numeric_limits<double>::epsilon() *
                        std::max({1.0, std::abs(originX), std::abs(originZ), spanX, spanZ});
        cells.reserve(points.size());
        for (size_t i = 0; i < points.size(); ++i)
        {
            auto &bucket = cells[cellFor(points[i])];
            bucket.indices.push_back(i);
            bucket.xmin = std::min(bucket.xmin, points[i].X);
            bucket.xmax = std::max(bucket.xmax, points[i].X);
            bucket.zmin = std::min(bucket.zmin, points[i].Z);
            bucket.zmax = std::max(bucket.zmax, points[i].Z);
        }
    }

    size_t takeNearest(Point &target)
    {
        size_t best = points.size();
        float distance = std::numeric_limits<float>::infinity();
        auto consider = [&](const PointBucket &bucket) {
            if (bucket.lowerBound(target) > distance)
                return;
            for (const size_t index : bucket.indices)
            {
                const float candidate = target.distanceTo(points[index]);
                // Canonical indices preserve ties independently of bucket traversal.
                if (candidate < distance ||
                    (candidate == distance && best != points.size() && index < best))
                {
                    best = index;
                    distance = candidate;
                }
            }
        };
        const PointCell centre = cellFor(target);
        const size_t budget = cells.size();
        size_t probes = 0;
        auto visit = [&](int64_t x, int64_t z) {
            if (probes == budget)
                return false;
            ++probes;
            auto found = cells.find({x, z});
            if (found != cells.end())
                consider(found->second);
            return true;
        };
        for (int64_t radius = 0;; ++radius)
        {
            bool complete = true;
            if (radius == 0)
                complete = visit(centre.x, centre.z);
            else
            {
                for (int64_t dx = -radius; complete && dx <= radius; ++dx)
                    complete = visit(centre.x + dx, centre.z - radius) &&
                               visit(centre.x + dx, centre.z + radius);
                for (int64_t dz = 1 - radius; complete && dz < radius; ++dz)
                    complete = visit(centre.x - radius, centre.z + dz) &&
                               visit(centre.x + radius, centre.z + dz);
            }
            if (complete && best != points.size() &&
                outsideBound(target, centre, radius) > distance)
                break;
            if (probes == budget)
            {
                // Sparse jumps must not walk an arbitrarily large empty lattice.
                for (const auto &cell : cells)
                    consider(cell.second);
                break;
            }
        }
        if (best == points.size())
            throw std::runtime_error(orderingError);
        auto found = cells.find(cellFor(points[best]));
        if (found == cells.end())
            throw std::runtime_error(orderingError);
        auto &indices = found->second.indices;
        auto position = std::find(indices.begin(), indices.end(), best);
        if (position == indices.end())
            throw std::runtime_error(orderingError);
        *position = indices.back();
        indices.pop_back();
        if (indices.empty())
            cells.erase(found);
        return best;
    }

private:
    const std::vector<Point> &points;
    std::unordered_map<PointCell, PointBucket, PointCellHash> cells;
    double originX;
    double originZ;
    double width;
    double roundingSlack;

    PointCell cellFor(const Point &point) const
    {
        return {static_cast<int64_t>(std::floor((double(point.X) - originX) / width)),
                static_cast<int64_t>(std::floor((double(point.Z) - originZ) / width))};
    }

    float outsideBound(const Point &target, PointCell centre, int64_t radius) const
    {
        auto separation = [&](float coordinate, double edge, bool positive) {
            const float infinity = std::numeric_limits<float>::infinity();
            const float boundary = std::nextafter(
                static_cast<float>(edge + (positive ? -roundingSlack : roundingSlack)),
                positive ? -infinity : infinity);
            const float gap = std::max(0.0f, positive ? boundary - coordinate
                                                    : coordinate - boundary);
            // Match float distance arithmetic, including rounded ties and underflow.
            return std::sqrt(gap * gap);
        };
        return std::min({
            separation(target.X, originX + (centre.x - radius) * width, false),
            separation(target.X, originX + (centre.x + radius + 1) * width, true),
            separation(target.Z, originZ + (centre.z - radius) * width, false),
            separation(target.Z, originZ + (centre.z + radius + 1) * width, true)});
    }
};
}

Quadtree::Quadtree()
{
}

Quadtree::~Quadtree() {}

void Quadtree::initialise(SegmentGroup *segmentgroup, Point center, float width, float height)
{
    // Initialise the quadtree //
    // depth is the current node depth
    // basenode the the primary tree node

    if (segmentgroup == nullptr)
    {
        throw std::invalid_argument("Quadtree source geometry must not be null");
    }
    if (!std::isfinite(center.X) || !std::isfinite(center.Z))
    {
        throw std::invalid_argument("Quadtree centre must be finite");
    }
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0)
    {
        throw std::invalid_argument("Quadtree dimensions must be finite and positive");
    }

    // check width and height are the same
    // TODO: remove the width and height if they need to match
    if (width != height)
    {
        throw std::invalid_argument("quadtree width and height must match");
    }
    // create the base node
    int depth = 0;
    Node bn = {center, width, height, depth};
    this->basenode = bn;
    this->nodes.clear();
    this->geometry = SegmentGroup::PreparedGeometry();
    this->segmentGroup = segmentgroup;
    this->initialised = true;

    // set the precision
    this->precision = defaultPrecision;
}

std::vector<Point> Quadtree::getOffset(float offsetValue)
{
    // return the points that represent the calculated offset //
    if (!this->initialised)
    {
        throw std::runtime_error("Quadtree must be initialised before generating an offset");
    }
    if (this->segmentGroup->count() == 0)
    {
        throw std::invalid_argument("Cannot offset empty geometry");
    }
    if (!std::isfinite(offsetValue))
    {
        throw std::invalid_argument("Offset must be finite");
    }
    this->offsetBoundaryPoints.clear();
    this->nodes.clear();
    this->offset = offsetValue;
    this->segmentStart = this->segmentGroup->getStartPoint();
    this->geometry = this->segmentGroup->prepareGeometry();
    // start to process the quadtree, populating the offsetBoundaryPoints
    this->conquer(this->basenode, this->geometry);
    // sort the points so they can be used to build a tool path
    std::vector<Point> points =
        this->sortPoints(this->segmentStart, this->offsetBoundaryPoints);
    this->validateContour(points);
    return points;
}

void Quadtree::conquer(Node &node, const SegmentGroup::PreparedGeometry &geometry)
{
    // Recursively divide each node until the target precision is reached //

    // Reject by distance magnitude before classifying the surviving cells.
    node.sdv = geometry.unsignedDistance(node.center);
    node.distanceSigned = this->nodeCouldContain(std::abs(this->offset), node);
    if (node.distanceSigned && geometry.isInside(node.center))
        node.sdv = -node.sdv;
    this->nodes.push_back(node);

    // check if it is possible that this node contains the target offset
    if (node.distanceSigned && this->nodeCouldContain(this->offset, node))
    {
        // check if we have reached the desired precision
        if ((node.width <= this->precision))
        {
            // Corner seeds preserve intersections when offset features meet inside a leaf.
            const float half = node.width / 2;
            const std::array<Point, 5> seeds = {
                node.center,
                Point(node.center.X - half, node.center.Z - half),
                Point(node.center.X - half, node.center.Z + half),
                Point(node.center.X + half, node.center.Z - half),
                Point(node.center.X + half, node.center.Z + half)};
            for (size_t i = 0; i < seeds.size(); ++i)
            {
                float value = i == 0 ? node.sdv : geometry.sdv(seeds[i]);
                // A zero level can be approached from either side of the boundary.
                if (this->offset != 0 && std::signbit(value) != std::signbit(this->offset))
                    continue;
                Point projectedPoint;
                if (this->projectToOffset(seeds[i], value, projectedPoint, geometry) &&
                    this->insideNode(projectedPoint, node))
                {
                    if (projectedPoint.Z <= this->segmentStart.Z)
                        this->offsetBoundaryPoints.push_back(projectedPoint);
                }
            }

            return;
        }
        else
        {
            this->divide(node, geometry);
        }
    }
}

bool Quadtree::projectToOffset(Point query, float value, Point &point,
                              const SegmentGroup::PreparedGeometry &geometry)
{
    // Re-evaluate the nearest feature after each signed-distance projection.
    for (int iteration = 0; iteration < 8; ++iteration)
    {
        bool onProfile;
        Point closest = geometry.closestPoint(query, &onProfile);
        if (!onProfile)
            return false;
        if (value == 0)
        {
            if (this->offset != 0)
                return false;
            point = closest;
            return true;
        }
        const double scale = double(this->offset) / value;
        point = Point(closest.X + (double(query.X) - closest.X) * scale,
                      closest.Z + (double(query.Z) - closest.Z) * scale);
        value = geometry.sdv(point);
        const float magnitude = std::max({1.0f, std::abs(point.X), std::abs(point.Z),
                                         std::abs(this->offset)});
        // Arc centres are rounded to five decimals; coordinates are floats.
        const float tolerance = 1e-5f +
            4 * std::numeric_limits<float>::epsilon() * magnitude;
        if (std::abs(value - this->offset) <= tolerance)
        {
            geometry.closestPoint(point, &onProfile);
            return onProfile;
        }
        query = point;
    }
    return false;
}

void Quadtree::divide(Node &node, const SegmentGroup::PreparedGeometry &geometry)
{
    // Divide this node by creating four child nodes //

    float cx = node.center.X;
    float cy = node.center.Z;
    float w = node.width / 2;
    float h = node.height / 2;
    int depth = node.depth + 1;

    float x = cx - h / 2;
    float z = cy + w / 2;
    Point pne = Point(x, z);
    Node ne = {pne, w, h, depth};

    x = cx + h / 2;
    z = cy + w / 2;
    Point pse = Point(x, z);
    Node se = {pse, w, h, depth};

    x = cx + h / 2;
    z = cy - w / 2;
    Point psw = Point(x, z);
    Node sw = {psw, w, h, depth};

    x = cx - h / 2;
    z = cy - w / 2;
    Point pnw = Point(x, z);
    Node nw = {pnw, w, h, depth};

    std::array<Node, 4> children = {ne, se, sw, nw};
    for (auto &child : children)
    {
        this->conquer(child, geometry);
    }
}

bool Quadtree::nodeCouldContain(float offset, Node &node)
{
    // check if the target offset could be within the node//

    // get the distance from the node center to a corner of the node
    // Based on pythagoras theorem: A^2 + B^2 = C^2; assumes the node is square
    // This is a quick check and could include false positives
    constexpr double halfDiagonalFactor = 0.7071067811865475244; // sqrt(2) / 2
    float cornerDistance = node.width * halfDiagonalFactor;

    if (node.sdv - cornerDistance <= offset && node.sdv + cornerDistance >= offset)
    {
        return true;
    }

    return false;
}

bool Quadtree::insideNode(Point &point, Node &node)
{
    // determine if point is inside node //
    float nodeXMin = node.center.X - node.height * 0.5;
    float nodeXMax = node.center.X + node.height * 0.5;
    float nodeZMin = node.center.Z - node.width * 0.5;
    float nodeZMax = node.center.Z + node.width * 0.5;

    // Rounded child centres can leave gaps between nominally shared edges.
    const float magnitude = std::max({1.0f, std::abs(node.center.X),
                                     std::abs(node.center.Z), node.width});
    const float tolerance = 4 * std::numeric_limits<float>::epsilon() * magnitude;
    return point.X >= nodeXMin - tolerance && point.X < nodeXMax + tolerance &&
           point.Z >= nodeZMin - tolerance && point.Z < nodeZMax + tolerance;
}

std::vector<Point> Quadtree::sortPoints(Point datum, std::vector<Point> &points)
{
    for (const auto &point : points)
        if (!std::isfinite(point.X) || !std::isfinite(point.Z))
            throw std::runtime_error(orderingError);
    std::sort(points.begin(), points.end(), [](const Point &first, const Point &second) {
        return first.X < second.X || (first.X == second.X && first.Z < second.Z);
    });
    points.erase(std::unique(points.begin(), points.end(),
                            [](Point first, Point second) { return first.isSame(second); }),
                 points.end());
    std::vector<Point> sorted_points;
    sorted_points.reserve(points.size());
    const size_t input_point_count = points.size();
    Point target = datum;

    if (!points.empty())
    {
        // Start at the retained front plane, not at a closer interior groove.
        auto start = std::max_element(points.begin(), points.end(),
            [&datum](const Point &first, const Point &second) {
                if (first.Z != second.Z)
                    return first.Z < second.Z;
                return datum.distanceTo(first) > datum.distanceTo(second);
            });
        target = *start;
    }

    if (points.empty())
        return sorted_points;
    PointGrid grid(points, this->precision);
    while (sorted_points.size() < input_point_count)
    {
        const size_t closest_index = grid.takeNearest(target);
        sorted_points.push_back(points[closest_index]);
        target = sorted_points.back();
    }

    if (input_point_count != sorted_points.size())
    {
        throw std::runtime_error(orderingError);
    }
    points.clear();
    return sorted_points;
}

std::vector<Node> Quadtree::getNodes()
{
    if (this->nodes.empty())
        return {this->basenode};
    for (auto &node : this->nodes)
    {
        if (!node.distanceSigned)
        {
            if (this->geometry.isInside(node.center))
                node.sdv = -node.sdv;
            node.distanceSigned = true;
        }
    }
    return this->nodes;
}

void Quadtree::validateContour(const std::vector<Point> &points) const
{
    this->geometry.validateContour(points, this->offset);
}

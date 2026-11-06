#ifndef Quadtree_H
#define Quadtree_H

#include <vector>
#include <math.h>

#include "point.h"
#include "segment.h"
#include "segmentgroup.h"

struct Node
{
    Point center = Point(0, 0);
    float width = 0;
    float height = 0;
    int depth = 0;
    float sdv = 0;
    bool distanceSigned = true;
    Node(Point center, float width, float height, int depth) : center(center), width(width), height(height), depth(depth) {}
    Node() {}
};

// forward declaration for segment group
class SegmentGroup;

class Quadtree
{
public:
    static constexpr float defaultPrecision = 0.05f;

    Quadtree();
    ~Quadtree();

    // C++ callers own the geometry; it must outlive its use by this tree.
    // Python retains all groups supplied to initialise until the tree is destroyed.
    // Invalid geometry pointers or root bounds throw invalid_argument without changing state.
    void initialise(SegmentGroup *segmentgroup, Point center, float width, float height);
    // Throws runtime_error before initialisation, invalid_argument for empty geometry
    // or nonfinite offsets. A valid request with no contour returns an empty vector.
    // Uses the axis-closed field, but excludes artificial-closure candidates.
    // Original faces remain eligible; the first segment's start-Z clip is retained.
    // Zero levels sample both sides; centre/corner seeds preserve feature joins.
    // Candidates converge within float/arc-rounding precision. Connecting chords
    // must satisfy SegmentGroup::offsetTolerance; detected collapsed branches
    // and uncertifiable chords throw runtime_error. Completeness is not guaranteed.
    std::vector<Point> getOffset(float offsetValue);
    // Independent flat snapshots in root-first depth-first traversal order.
    // Before extraction (including after initialise), returns only the root.
    // Deferred signs are resolved against the geometry from the latest extraction.
    std::vector<Node> getNodes();

private:
    friend class SegmentGroup;
    // value to offset the segmentgroup by
    float offset = 0;
    // precision of the quadtree
    float precision = defaultPrecision;
    Point segmentStart = Point(0, 0);

    SegmentGroup *segmentGroup = nullptr;
    bool initialised = false;
    Node basenode;
    std::vector<Node> nodes;
    // Rebuilt for every offset; retained only to finish debug-node signs on demand.
    SegmentGroup::PreparedGeometry geometry;

    std::vector<Point> offsetBoundaryPoints;

    void divide(Node &, const SegmentGroup::PreparedGeometry &geometry);
    void conquer(Node &, const SegmentGroup::PreparedGeometry &geometry);
    bool projectToOffset(Point query, float value, Point &point,
                         const SegmentGroup::PreparedGeometry &geometry);
    void validateContour(const std::vector<Point> &points) const;
    bool nodeCouldContain(float offset, Node &node);
    bool insideNode(Point &point, Node &node);
    std::vector<Point> sortPoints(Point datum, std::vector<Point> &points);
};

#endif
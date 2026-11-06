/*
 * turn_tool.cpp — implementation of the ported LibLathe insert builders.
 * Line-for-line fidelity to liblathe/tool/tool.py @ 4bac3400 is preserved
 * where practical; deviations are marked with PORT NOTE comments.
 */
#include "turn_tool.h"

#include <cmath>
#include <stdexcept>
#include <string>

#include "../Vendor/liblathe/base/point.h"
#include "../Vendor/liblathe/base/segment.h"

namespace turning
{

namespace
{

float degreesToRadians(float degrees)
{
    return degrees * static_cast<float>(M_PI) / 180.0f;
}

void validateInsert(char shape, float edgeLengthMM, float rotationDegrees)
{
    if (!supportedInsertShape(shape))
        throw std::runtime_error(std::string("unsupported insertShape '") + shape +
                                 "'; supported shapes: " + supportedInsertShapesText());
    if (!std::isfinite(edgeLengthMM) || edgeLengthMM <= 0.0f || edgeLengthMM > 1000.0f)
        throw std::runtime_error("insertEdgeLengthMM must be finite and in (0, 1000]");
    if (!std::isfinite(rotationDegrees) || rotationDegrees < 0.0f || rotationDegrees >= 360.0f)
        throw std::runtime_error("insertRotationDegrees must be finite and in [0, 360)");
}

/* tool.py::get_segmentgroup_from_string_rectangle (shapes C, D, S, V). */
SegmentGroup buildRectangle(float tipAngle, float edgeLengthMM)
{
    SegmentGroup shapeGroup;
    float ang = 270.0f - tipAngle / 2.0f;
    Point startPoint;
    Point pt2 = startPoint.project(degreesToRadians(ang), edgeLengthMM);

    ang += tipAngle;
    Point pt3 = pt2.project(degreesToRadians(ang), edgeLengthMM);

    ang += 180.0f - tipAngle;
    Point pt4 = pt3.project(degreesToRadians(ang), edgeLengthMM);

    shapeGroup.addSegment(Segment(startPoint, pt2));
    shapeGroup.addSegment(Segment(pt2, pt3));
    shapeGroup.addSegment(Segment(pt3, pt4));
    shapeGroup.addSegment(Segment(pt4, startPoint));
    return shapeGroup;
}

/* tool.py::get_segmentgroup_from_string_triangle (shape T). */
SegmentGroup buildTriangle(float tipAngle, float edgeLengthMM)
{
    SegmentGroup shapeGroup;
    float ang = 270.0f - tipAngle / 2.0f;
    Point startPoint;
    Point pt2 = startPoint.project(degreesToRadians(ang), edgeLengthMM);

    ang += tipAngle * 2.0f;
    Point pt3 = pt2.project(degreesToRadians(ang), edgeLengthMM);

    shapeGroup.addSegment(Segment(startPoint, pt2));
    shapeGroup.addSegment(Segment(pt2, pt3));
    shapeGroup.addSegment(Segment(pt3, startPoint));
    return shapeGroup;
}

/* tool.py::get_segmentgroup_from_string_round (shape R). */
SegmentGroup buildRound(float edgeLengthMM)
{
    SegmentGroup shapeGroup;
    const float half = edgeLengthMM * 0.5f;

    Point centerPoint(0.0f, half);
    Point startPoint(centerPoint.X + half, centerPoint.Z);
    Point endPoint(centerPoint.X - half, centerPoint.Z);

    shapeGroup.addSegment(Segment(startPoint, endPoint, 1.0f));
    shapeGroup.addSegment(Segment(endPoint, startPoint, 1.0f));
    return shapeGroup;
}

/* tool.py::rotate_tool_shape — rotate every segment endpoint about the
 * origin, preserving the bulge. */
SegmentGroup rotateShape(const SegmentGroup &shape, float rotationDegrees)
{
    SegmentGroup copy = shape; /* vendored accessor is non-const */
    const float angle = degreesToRadians(rotationDegrees);
    const Point origin;

    SegmentGroup rotated;
    for (const auto &segment : copy.getSegments())
    {
        Point start = segment.start; /* vendored rotate() is a non-const member */
        Point end = segment.end;
        start = start.rotate(origin, angle);
        end = end.rotate(origin, angle);
        rotated.addSegment(Segment(start, end, segment.bulge));
    }
    return rotated;
}

/* Exact polygon vertices for the rectangle/triangle builders, tip first. */
std::vector<Point> rectangleVertices(float tipAngle, float edgeLengthMM)
{
    std::vector<Point> vertices;
    float ang = 270.0f - tipAngle / 2.0f;
    Point startPoint;
    vertices.push_back(startPoint);
    vertices.push_back(startPoint.project(degreesToRadians(ang), edgeLengthMM));
    ang += tipAngle;
    vertices.push_back(vertices.back().project(degreesToRadians(ang), edgeLengthMM));
    ang += 180.0f - tipAngle;
    vertices.push_back(vertices.back().project(degreesToRadians(ang), edgeLengthMM));
    return vertices;
}

std::vector<Point> triangleVertices(float tipAngle, float edgeLengthMM)
{
    std::vector<Point> vertices;
    float ang = 270.0f - tipAngle / 2.0f;
    Point startPoint;
    vertices.push_back(startPoint);
    vertices.push_back(startPoint.project(degreesToRadians(ang), edgeLengthMM));
    ang += tipAngle * 2.0f;
    vertices.push_back(vertices.back().project(degreesToRadians(ang), edgeLengthMM));
    return vertices;
}

} // namespace

bool supportedInsertShape(char shape)
{
    switch (shape)
    {
    case 'C':
    case 'D':
    case 'S':
    case 'V':
    case 'R':
    case 'T':
        return true;
    default:
        return false;
    }
}

float tipAngleForShape(char shape)
{
    switch (shape)
    {
    case 'C':
        return 80.0f; /* Rhombic 80 (tool.py shape table) */
    case 'D':
        return 55.0f; /* Rhombic 55 — legacy fixed DCMT insert */
    case 'S':
        return 90.0f; /* Square */
    case 'V':
        return 35.0f; /* Rhombic 35 */
    case 'R':
        return 90.0f; /* Round (angle unused by the round builder) */
    case 'T':
        return 60.0f; /* Triangular */
    default:
        return 0.0f;
    }
}

const char *supportedInsertShapesText()
{
    return "C, D, S, V, R, T";
}

SegmentGroup buildInsertShape(char shape, float edgeLengthMM, float rotationDegrees)
{
    validateInsert(shape, edgeLengthMM, rotationDegrees);

    SegmentGroup shapeGroup;
    if (shape == 'R')
        shapeGroup = buildRound(edgeLengthMM);
    else if (shape == 'T')
        shapeGroup = buildTriangle(tipAngleForShape(shape), edgeLengthMM);
    else
        shapeGroup = buildRectangle(tipAngleForShape(shape), edgeLengthMM);

    if (rotationDegrees != 0.0f)
        shapeGroup = rotateShape(shapeGroup, rotationDegrees);
    return shapeGroup;
}

std::vector<std::pair<float, float>> toolProfileOutline(char shape, float edgeLengthMM,
                                                        float rotationDegrees)
{
    validateInsert(shape, edgeLengthMM, rotationDegrees);

    std::vector<Point> vertices;
    if (shape == 'R')
    {
        /* The contract receipt is a polyline; sample the exact insert circle
         * (centre (0, d/2), radius d/2 — the shape defeature uses as arcs) at
         * a fixed 2-degree step starting at the tip, plus its closing point.
         * PORT NOTE: upstream has no outline export; this is a receipt-only
         * sampling, not an additional geometry authority. */
        const float half = edgeLengthMM * 0.5f;
        const int steps = 180;
        for (int i = 0; i <= steps; ++i)
        {
            float angle = degreesToRadians(-90.0f + (360.0f * i) / steps);
            vertices.emplace_back(half * std::cos(angle), half + half * std::sin(angle));
        }
    }
    else if (shape == 'T')
    {
        vertices = triangleVertices(tipAngleForShape(shape), edgeLengthMM);
    }
    else
    {
        vertices = rectangleVertices(tipAngleForShape(shape), edgeLengthMM);
    }

    if (rotationDegrees != 0.0f)
    {
        const float angle = degreesToRadians(rotationDegrees);
        const Point origin;
        for (auto &vertex : vertices)
            vertex = vertex.rotate(origin, angle);
    }

    if (vertices.size() > kMaxToolProfilePoints)
        throw std::runtime_error("toolProfile outline exceeds point budget");

    std::vector<std::pair<float, float>> outline;
    outline.reserve(vertices.size());
    for (const auto &vertex : vertices)
        outline.emplace_back(vertex.X, vertex.Z);
    return outline;
}

} // namespace turning

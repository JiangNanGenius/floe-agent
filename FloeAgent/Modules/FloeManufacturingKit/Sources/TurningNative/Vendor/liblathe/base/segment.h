#ifndef Segment_H
#define Segment_H

#define _USE_MATH_DEFINES
#include <math.h>

#include "boundbox.h"
#include "point.h"
#include "utils.h"

class Segment
{
public:
    Segment() {};
    Segment(Point start, Point end);
    Segment(Point start, Point end, float bulge);
    ~Segment() {};

    Point start = Point();
    Point end = Point();
    float bulge = 0;

    float getAngle();
    void setBulge(float angle);
    Point getCentrePoint();
    float getRadius();
    float getRotation();
    BoundBox Boundbox();
    bool crossesAxis(float startAngle, float endAngle, float axisAngle);
    float getLength();
    float getSagitta();
    float getApothem();
    float getEta();
    float getEpsilon();
    float getPhi();
    float get_gamma();
    bool isSame(Segment seg);
    std::vector<Point> intersect(Segment seg, bool extend);
    bool pointOnSegment(Point point);
    // Distance to the finite line or arc, including its endpoints.
    float distanceToPoint(Point point);
    // Arc-centre queries and equal-distance endpoints return the start point.
    Point closestPoint(Point point);

private:
    friend class SegmentGroup;
    struct ArcGeometry
    {
        Point centre = Point();
        double radius = 0;
        double direction = 0;
        double startAngle = 0;
        double sweep = 0;
    };
    ArcGeometry prepareArc();
    Point closestPointPrepared(const Point &point, const ArcGeometry &arc) const;
    std::vector<Point> intersectLineLine(Segment seg, bool extend);
    std::vector<Point> intersectCircleLine(Segment seg, bool extend);
    std::vector<Point> intersectCircleCircle(Segment seg, bool extend);
};

#endif

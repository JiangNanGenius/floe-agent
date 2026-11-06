#include <cmath>
#include <iostream>
#include "segment.h"

Segment::Segment(Point start, Point end) : start(start), end(end)
{
}

Segment::Segment(Point start, Point end, float bulge = 0) : start(start), end(end), bulge(bulge)
{
}

float Segment::getAngle()
{
    // Returns the included angle between the start && end points in radians//
    // TODO: Is this supposed to return 0 to 2 * M_PIf?

    if (this->bulge == 0)
    {
        return M_PIf;
    }

    return atan(abs(this->bulge)) * 4;
}

void Segment::setBulge(float angle)
{
    /*
    Sets the bulge of the arc (tan(angle/4))
    Negative bulge = clockwise
    Positive bulge = anticlockwise
    angle in radians
    */

    this->bulge = tan(angle / 4);
}

Point Segment::getCentrePoint()
{
    // Returns the centre point of the arc //
    Point midp = this->start.mid(this->end);
    if (this->bulge == 0)
    {
        return midp;
    }

    float a = this->getApothem();
    //  check if (the center point is inverted. i.e. at 180 it goes inside the arc
    if (this->getAngle() > M_PIf)
    {
        a = -a;
    }

    Point centre_pt = midp.project(this->getRotation() + M_PI_2f, a);
    if (this->bulge > 0)
    {
        centre_pt = midp.project(this->getRotation() - M_PI_2f, a);
    }

    return centre_pt;
}

float Segment::getRadius()
{
    // Return the radius of the arc //

    if (this->bulge == 0)
    {
        return 0.0;
    }

    float rad = this->getLength() * (1 + pow(this->bulge, 2)) / (4 * abs(this->bulge));
    return rad;
}

float Segment::getRotation()
{
    // returns the rotation of the segment//
    return this->start.angleTo(this->end);
}

BoundBox Segment::Boundbox()
{
    // returns the segments boundingbox //

    Point topLeft, bottomRight;

    if (this->bulge == 0)
    {
        topLeft = this->start;
        bottomRight = this->end;
    }
    else
    {
        float startAngle = this->getCentrePoint().angleTo(this->start);
        float endAngle = this->getCentrePoint().angleTo(this->end);

        bool cross0 = this->crossesAxis(startAngle, endAngle, 0);
        bool cross90 = this->crossesAxis(startAngle, endAngle, M_PI_2f);
        bool cross180 = this->crossesAxis(startAngle, endAngle, M_PIf);
        bool cross270 = this->crossesAxis(startAngle, endAngle, M_PIf * 1.5);

        //  if (the arc crosses the axis the min or max is where the arc intersects the axis
        //  otherwise max/min is the arc endpoint
        float zmax = cross0 ? this->getCentrePoint().Z + this->getRadius() : std::max(this->start.Z, this->end.Z);
        float xmin = cross90 ? this->getCentrePoint().X - this->getRadius() : std::min(this->start.X, this->end.X);
        float zmin = cross180 ? this->getCentrePoint().Z - this->getRadius() : std::min(this->start.Z, this->end.Z);
        float xmax = cross270 ? this->getCentrePoint().X + this->getRadius() : std::max(this->start.X, this->end.X);

        topLeft = Point(xmin, zmin);
        bottomRight = Point(xmax, zmax);
    }

    return BoundBox(topLeft, bottomRight);
}

bool Segment::crossesAxis(float startAngle, float endAngle, float axisAngle)
{
    // check of the axis angle is between the start and end angles
    // i.e. the arc crosses the axis

    float circle = M_PIf * 2;
    float referenceStartAngle = fmod((startAngle - axisAngle + circle), circle);
    float referenceEndAngle = fmod((endAngle - axisAngle + circle), circle);

    //  if refStartAngle > refEndAngle then the arc crosses the axis
    bool crosses = referenceStartAngle <= referenceEndAngle;

    if (this->bulge < 0)
    {
        //  if refStartAngle < refEndAngle then the arc crosses the axis
        crosses = referenceStartAngle >= referenceEndAngle;
    }

    return crosses;
}

float Segment::getLength()
{
    // Returns the distance between the start && end points //
    //  TODO: Arc length should be the true length not the distance between the start && endpoints?
    return this->start.distanceTo(this->end);
}

float Segment::getSagitta()
{
    // Returns the arc height, typically referred to as the sagitta //
    return this->getLength() / 2 * this->bulge;
}

float Segment::getApothem()
{
    // Returns apothem. distance from arc center to c||d midpoint //
    return sqrt(pow(this->getRadius(), 2) - pow(this->getLength() / 2, 2));
}

float Segment::getEta()
{
    // Return eta angle (half the included angle) in radians //
    return this->getAngle() / 2;
}

float Segment::getEpsilon()
{
    // Returns signless epsilon angle in radians//
    if (this->bulge == 0)
    {
        return 0;
    }

    return abs(atan(this->bulge));
}

float Segment::getPhi()
{
    // Return signless phi angle in radians //

    if (this->bulge == 0)
    {
        return 0;
    }

    return abs((M_PIf - abs(this->getAngle()) / 2) / 2);
}

float Segment::get_gamma()
{
    // Returns signless gamma angle in radians //

    if (this->bulge == 0)
    {
        return 0;
    }

    return (M_PIf - abs(this->getAngle())) / 2;
}

bool Segment::isSame(Segment seg)
{
    // Returns true is the segment is the same //

    if (this->start.isSame(seg.start))
    {
        if (this->end.isSame(seg.end))
        {
            if (this->bulge == seg.bulge)
            {
                return true;
            }
        }
    }

    return false;
}

std::vector<Point> Segment::intersect(Segment seg, bool extend = false)
{
    // Determine intersections between self && seg//
    std::vector<Point> pts;
    if (this->bulge == 0 && seg.bulge == 0)
    {
        pts = this->intersectLineLine(seg, extend);
    }
    else if (this->bulge != 0 && seg.bulge != 0)
    {
        pts = this->intersectCircleCircle(seg, extend);
    }
    else if (this->bulge != 0 || seg.bulge != 0 && this->bulge == 0 || seg.bulge == 0)
    {
        pts = this->intersectCircleLine(seg, extend);
    }

    return pts;
}

std::vector<Point> Segment::intersectLineLine(Segment seg, bool extend = false)
{
    // Determine intersections between self && seg when both are line segments//

    Point a1 = this->start;
    Point a2 = this->end;
    Point b1 = seg.start;
    Point b2 = seg.end;
    std::vector<Point> pts;

    float ua_t = (b2.X - b1.X) * (a1.Z - b1.Z) - (b2.Z - b1.Z) * (a1.X - b1.X);
    float ub_t = (a2.X - a1.X) * (a1.Z - b1.Z) - (a2.Z - a1.Z) * (a1.X - b1.X);
    float u_b = (b2.Z - b1.Z) * (a2.X - a1.X) - (b2.X - b1.X) * (a2.Z - a1.Z);

    // if ((u_b != 0)){
    float ua = ua_t / u_b;
    float ub = ub_t / u_b;
    //}

    if (((0 <= ua && ua <= 1) && (0 <= ub && ub <= 1)) || extend)
    {
        // intersect true
        Point pt = Point(a1.X + ua * (a2.X - a1.X), a1.Z + ua * (a2.Z - a1.Z));
        pts.push_back(pt);
    }

    return pts;
}

std::vector<Point> Segment::intersectCircleLine(Segment seg, bool extend = false)
{
    // Determine intersections between self && seg when one is a line segment && one is an arc segment//

    std::vector<Point> pts;
    // TODO: initialise segment using Segment() without the points and bulge
    Segment line = Segment(Point(), Point(), 0);
    Segment circle = Segment(Point(), Point(), 0);

    if (this->bulge == 0 && seg.bulge != 0)
    {
        line.start = this->start;
        line.end = this->end;
        circle.start = seg.start;
        circle.end = seg.end;
        circle.bulge = seg.bulge;
    }

    if (this->bulge != 0 && seg.bulge == 0)
    {
        line.start = seg.start;
        line.end = seg.end;
        circle.start = this->start;
        circle.end = this->end;
        circle.bulge = this->bulge;
    }

    Point c = circle.getCentrePoint();
    float r = circle.getRadius();
    Point a1 = line.start;
    Point a2 = line.end;

    if (line.getLength() == 0)
    {
        return pts;
    }

    float a = (a2.X - a1.X) * (a2.X - a1.X) + (a2.Z - a1.Z) * (a2.Z - a1.Z);
    float b = 2 * ((a2.X - a1.X) * (a1.X - c.X) + (a2.Z - a1.Z) * (a1.Z - c.Z));
    float cc = pow(c.X, 2) + pow(c.Z, 2) + pow(a1.X, 2) + pow(a1.Z, 2) - 2 * (c.X * a1.X + c.Z * a1.Z) - pow(r, 2);

    float deter = pow(b, 2) - 4 * a * cc;
    if (deter < 0)
    {
        return pts;
    }

    float e = sqrt(deter);
    float u1 = (-b + e) / (2 * a);
    float u2 = (-b - e) / (2 * a);

    Point point = a1.lerp(a2, u1);
    if (circle.pointOnSegment(point) && line.pointOnSegment(point) || extend)
    {
        pts.push_back(point);
    }

    point = a1.lerp(a2, u2);
    if (circle.pointOnSegment(point) && line.pointOnSegment(point) || extend)
    {
        pts.push_back(point);
    }

    return pts;
}

std::vector<Point> Segment::intersectCircleCircle(Segment seg, bool extend = false)
{
    // Determine intersections between self and seg when both are arc segments//

    std::vector<Point> pts;
    Point c1 = this->getCentrePoint();
    float r1 = this->getRadius();
    Point c2 = seg.getCentrePoint();
    float r2 = seg.getRadius();

    //  Determine actual distance between circle centres
    float c_dist = c1.distanceTo(c2);

    if (Utils::roundoff(c_dist, 5) >= Utils::roundoff(r1 + r2, 5))
    {
        //  too far apart to intersect or just touching
        return pts;
    }

    if (c_dist < abs(r1 - r2))
    {
        //  inside each other
        return pts;
    }

    if (c1.isSame(c2) || Utils::roundoff(c_dist, 5) == 0)
    {
        //  concentric
        return pts;
    }

    //  get the chord distance
    float a = (pow(r1, 2) - pow(r2, 2) + pow(c_dist, 2)) / (2 * c_dist);

    //  A**2 + B**2 = C**2 h**2 + a**2 = r1**2 therefore:
    float h = sqrt(pow(r1, 2) - pow(a, 2));
    Point p = c1.lerp(c2, a / c_dist);
    float b = h / c_dist;

    Point pt1 = Point(p.X - b * (c2.Z - c1.Z), p.Z + b * (c2.X - c1.X));
    if (this->pointOnSegment(pt1) && seg.pointOnSegment(pt1))
    {
        pts.push_back(pt1);
    }

    Point pt2 = Point(p.X + b * (c2.Z - c1.Z), p.Z - b * (c2.X - c1.X));
    if (this->pointOnSegment(pt2) && seg.pointOnSegment(pt2))
    {
        pts.push_back(pt2);
    }

    return pts;
}

bool Segment::pointOnSegment(Point point)
{
    // Determine if point is on segment //
    if (this->bulge == 0)
    {

        float length = getLength();
        float sp = start.distanceTo(point);
        float pe = point.distanceTo(end);

        // if the distance start > point + point > end is equal to length, point is online
        if (Utils::roundoff(length, 5) == Utils::roundoff(sp + pe, 5))
        {
            return true;
        }

        return false;
    }
    else
    {
        //  Arc
        Point c = this->getCentrePoint();
        float radius = this->getRadius();
        float sa = c.angleTo(this->start);
        float ea = c.angleTo(this->end);
        float pnt_ang = c.angleTo(point);

        //  if (the point isn't on the segment radius it's not a true intersection
        if (Utils::roundoff(c.distanceTo(point), 2) != Utils::roundoff(radius, 2))
        {
            return false;
        }

        // if the point angle matches the start or end angles the point is on the arc
        if (sa == pnt_ang || pnt_ang == ea)
        {
            return true;
        }

        // check if the pnt_ang falls between the start and end angles
        return this->crossesAxis(sa, ea, pnt_ang);
    }
}

Point Segment::closestPoint(Point point)
{
    return this->closestPointPrepared(point, this->prepareArc());
}

Segment::ArcGeometry Segment::prepareArc()
{
    ArcGeometry arc;
    if (this->bulge != 0 && (start.X != end.X || start.Z != end.Z))
    {
        arc.centre = this->getCentrePoint();
        arc.radius = this->getRadius();
        arc.direction = this->bulge > 0 ? -1 : 1;
        arc.startAngle = std::atan2(double(start.Z) - arc.centre.Z,
                                   double(start.X) - arc.centre.X);
        arc.sweep = 4 * std::atan(std::abs(double(this->bulge)));
    }
    return arc;
}

Point Segment::closestPointPrepared(const Point &point, const ArcGeometry &arc) const
{
    const Point &start = this->start;
    const Point &end = this->end;
    if ((start.X == end.X && start.Z == end.Z) ||
        (point.X == start.X && point.Z == start.Z))
    {
        return start;
    }
    if (point.X == end.X && point.Z == end.Z)
    {
        return end;
    }

    if (this->bulge == 0)
    {
        double APx = double(point.X) - start.X;
        double APz = double(point.Z) - start.Z;
        double ABx = double(end.X) - start.X;
        double ABz = double(end.Z) - start.Z;
        double t = (ABx * APx + ABz * APz) / (ABx * ABx + ABz * ABz);

        if (t <= 0)
            return start;
        if (t >= 1)
            return end;
        return Point(start.X + ABx * t, start.Z + ABz * t);
    }

    Point centre = arc.centre;
    double dx = double(point.X) - centre.X;
    double dz = double(point.Z) - centre.Z;
    double length = std::hypot(dx, dz);
    if (length == 0)
        return start;

    // Positive bulge sweeps clockwise in conventional (X, Z) coordinates.
    double direction = arc.direction;
    double startAngle = arc.startAngle;
    double circle = 2 * std::acos(-1.0);
    double progress = std::fmod(direction * (std::atan2(dz, dx) - startAngle), circle);
    if (progress < 0)
        progress += circle;
    double sweep = arc.sweep;
    if (progress > sweep)
    {
        Point startCopy = start;
        Point endCopy = end;
        return startCopy.distanceTo(point) <= endCopy.distanceTo(point) ? start : end;
    }

    double scale = arc.radius / length;
    return Point(centre.X + dx * scale, centre.Z + dz * scale);
}

float Segment::distanceToPoint(Point point)
{
    return this->closestPoint(point).distanceTo(point);
}

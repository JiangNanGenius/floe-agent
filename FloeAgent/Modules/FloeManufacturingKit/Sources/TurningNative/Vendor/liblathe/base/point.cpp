#include <limits>

#include "point.h"
#include "utils.h"

Point::Point(float x, float z) : X(x), Z(z)
{
}

Point::~Point() {}

float Point::distanceTo(Point pt)
{
    // Returns the distance between two points//
    return sqrt((pt.X - this->X) * (pt.X - this->X) + (pt.Z - this->Z) * (pt.Z - this->Z));
}

float Point::angleTo(Point pt)
{
    // Returns the angle between two points in radians //
    float dX = this->X - pt.X;
    float dZ = this->Z - pt.Z;
    float angle = fmod(atan2(-dX, dZ) + M_PIf, M_PIf * 2);
    return angle;
}

Point Point::nearest(std::vector<Point> pts)
{
    // returns nearest point from points //
    Point nearest;
    float distance = std::numeric_limits<float>::infinity();
    for (auto pt : pts)
    {
        if (this->distanceTo(pt) < distance)
        {
            distance = this->distanceTo(pt);
            nearest = pt;
        }
    }
    return nearest;
}

bool Point::isSame(Point pt)
{
    // Returns True if the coordinates are the same//
    if (Utils::roundoff(this->X, 5) == Utils::roundoff(pt.X, 5))
    {
        if (Utils::roundoff(this->Z, 5) == Utils::roundoff(pt.Z, 5))
        {
            return true;
        }
    }

    return false;
}

Point Point::sub(Point pt)
{
    // Returns a point with the difference between this and pt//
    Point p = Point(this->X - pt.X, this->Z - pt.Z);
    return p;
}

Point Point::add(Point pt)
{
    // Returns a point addition between this and pt//
    Point p = Point(this->X + pt.X, this->Z + pt.Z);
    return p;
}

Point Point::multiply(float val)
{
    // Returns a point multiplication between this and val//
    Point p = Point(this->X * val, this->Z * val);
    return p;
}

Point Point::lerp(Point pt, float t)
{
    // Returns a point linear interpolation between this and pt
    // t is parameter [0 1] for the distance between this and pt
    // e.g. t = 0.5 will return midpoint between this and pt//
    Point p = Point(this->X + (pt.X - this->X) * t, this->Z + (pt.Z - this->Z) * t);
    return p;
}

Point Point::normaliseTo(Point pt)
{
    // returns the normalised direction from this to pt//
    Point p = pt.sub(*this);
    float m = sqrt(p.X * p.X + p.Z * p.Z);
    if (m == 0)
    {
        return Point(0.0, 0.0);
    }
    return Point(p.X / m, p.Z / m);
}

Point Point::rotate(Point center, float angle)
{
    // Returns a point rotated by angle in radians about center//
    float x = center.X + (this->X - center.X) * cos(angle) - (this->Z - center.Z) * sin(angle);
    float z = center.Z + (this->X - center.X) * sin(angle) + (this->Z - center.Z) * cos(angle);
    // float x = this->X* cos(angle) - this->Z * sin(angle);
    // float z = this->X* sin(angle) + this->Z * cos(angle);
    return Point(x, z);
}

Point Point::mid(Point pt)
{
    // Returns midpoint between this and pt//
    float x = (this->X + pt.X) / 2;
    float z = (this->Z + pt.Z) / 2;
    return Point(x, z);
}

Point Point::project(float angle, float distance)
{
    // Project the point at angle in radians by distance//
    float x = Utils::roundoff(this->X - sin(angle) * distance, 5);
    float z = Utils::roundoff(this->Z + cos(angle) * distance, 5);
    return Point(x, z);
}

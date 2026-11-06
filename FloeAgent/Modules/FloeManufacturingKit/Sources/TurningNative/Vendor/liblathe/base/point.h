

#ifndef Point_H
#define Point_H

#define _USE_MATH_DEFINES
#include <math.h>
#include <vector>

#ifndef M_PIf
#define M_PIf (3.14159265358979323846)
#endif

#ifndef M_PI_2f
#define M_PI_2f (3.14159265358979323846 * 0.5)
#endif

class Point
{
public:
    Point() {};
    Point(float x, float z);

    ~Point();

    float X = 0;
    float Z = 0;
    float distanceTo(Point pt);
    float angleTo(Point pt);
    Point nearest(std::vector<Point> pts);
    bool isSame(Point pt);
    Point sub(Point pt);
    Point add(Point pt);
    Point multiply(float val);
    Point lerp(Point pt, float t);
    Point normaliseTo(Point pt);
    Point rotate(Point center, float angle);
    Point mid(Point pt);
    Point project(float angle, float distance);
};

#endif
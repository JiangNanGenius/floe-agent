#ifndef BoundBox_H
#define BoundBox_H

#include "point.h"

class BoundBox
{
public:
    BoundBox(Point pt1, Point pt2);
    ~BoundBox() {};
    float XLength();
    float ZLength();

    float XMin;
    float ZMin;
    float XMax;
    float ZMax;
};

#endif
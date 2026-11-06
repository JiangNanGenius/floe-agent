#include "boundbox.h"

BoundBox::BoundBox(Point pt1, Point pt2)
{

    this->XMin = std::min(pt1.X, pt2.X);
    this->ZMin = std::min(pt1.Z, pt2.Z);
    this->XMax = std::max(pt1.X, pt2.X);
    this->ZMax = std::max(pt1.Z, pt2.Z);
}

float BoundBox::XLength()
{
    // Return length in x direction//
    return abs(this->XMax - this->XMin);
}

float BoundBox::ZLength()
{
    // Return length in z direction//
    return abs(this->ZMax - this->ZMin);
}

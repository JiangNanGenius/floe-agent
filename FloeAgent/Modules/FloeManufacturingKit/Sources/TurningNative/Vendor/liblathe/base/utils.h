
#ifndef Utils_H
#define Utils_H

class Utils
{
public:
    Utils();
    ~Utils();

    static float roundoff(float value, int prec)
    {
        // round value to precision
        float pow_10 = pow(10, prec);
        return round(value * pow_10) / pow_10;
    }

    static bool compareFloats(float A, float B, float prec = 0.1)
    {
        // check if A and B are the same within precision
        return (fabs(A - B) < prec);
    }
};

#endif
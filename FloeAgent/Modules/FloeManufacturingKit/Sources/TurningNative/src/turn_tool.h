/*
 * turn_tool.h — R4 turningSetup: native operation selection parameters and
 * the real 2D insert shape used for defeature.
 *
 * Mechanical C++ port of the insert-shape construction in
 * liblathe/tool/tool.py (dubstar-04/LibLathe @
 * 4bac3400813f40a15e0bf22e12998453e337d96e, GPL-2.0):
 *   - get_segmentgroup_from_string_rectangle (shapes C, D, S, V)
 *   - get_segmentgroup_from_string_round     (shape R)
 *   - get_segmentgroup_from_string_triangle  (shape T)
 *   - rotate_tool_shape                      (insertRotationDegrees)
 * Only the shapes the pinned upstream actually constructs are supported;
 * everything else is rejected by the caller using supportedInsertShape().
 */
#ifndef TURN_TOOL_H
#define TURN_TOOL_H

#include <utility>
#include <vector>

#include "../Vendor/liblathe/base/segmentgroup.h"

namespace turning
{

/* Resolved top-level optional `turningSetup` (formatVersion 1, millimetres,
 * degrees). Defaults are exactly the contract's explicit defaults and match
 * the pre-R4 behaviour (clearance 3, lead angles 270/315, D 6.35 mm, no
 * rotation). */
struct TurningSetup
{
    bool faceEnabled = true;
    bool roughEnabled = true;
    bool profileEnabled = true;
    double clearanceMM = 3.0;
    double horizontalFeedMMPerMinute = 120.0;
    double verticalFeedMMPerMinute = 120.0;
    double leadinAngleDegrees = 270.0;
    double leadoutAngleDegrees = 315.0;
    bool allowGrooving = false;
    char insertShape = 'D'; /* uppercase; see supportedInsertShape() */
    double insertEdgeLengthMM = 6.35;
    double insertRotationDegrees = 0.0;
};

/* Shapes with a real builder in the pinned upstream tool.py: C, D, S, V, R, T
 * (case-insensitive at the JSON layer; stored uppercase). */
bool supportedInsertShape(char shape);

/* Included angle for a supported shape (C 80, D 55, R 90, S 90, T 60, V 35). */
float tipAngleForShape(char shape);

/* Human-readable supported set for refusal messages: "C, D, S, V, R, T". */
const char *supportedInsertShapesText();

/*
 * Build the insert segment group actually passed to
 * SegmentGroup::defeature(stock, tool, allowGrooving). `shape` must be
 * supported and `edgeLengthMM` finite positive; `rotationDegrees` must be
 * finite in [0, 360). Throws std::runtime_error otherwise. The nose radius is
 * intentionally ignored, exactly like the pinned upstream builders.
 */
SegmentGroup buildInsertShape(char shape, float edgeLengthMM, float rotationDegrees);

/*
 * The exact 2D outline of that insert as [x, z] points (tip at the origin,
 * rotation applied). Polygon shapes are emitted exactly; shape R is the exact
 * circle sampled at a fixed 2-degree step plus its closing point (181 points)
 * because the contract format is a polyline. Throws std::runtime_error when
 * the sampled outline would exceed kMaxToolProfilePoints.
 */
const size_t kMaxToolProfilePoints = 4096;
std::vector<std::pair<float, float>> toolProfileOutline(char shape, float edgeLengthMM,
                                                        float rotationDegrees);

} // namespace turning

#endif /* TURN_TOOL_H */

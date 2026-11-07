// Synthetic qualification geometry; never linked into the production App.
#import "SimulationFixtures.h"
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepTools.hxx>
#include <TopTools_FormatVersion.hxx>
#include <sstream>

NSData *FloeSimulationFixtureBoxBRep(void) {
    try {
        auto shape = BRepPrimAPI_MakeBox(100.0, 20.0, 30.0).Shape();
        std::ostringstream output;
        BRepTools::Write(shape, output, Standard_False, Standard_False,
                         TopTools_FormatVersion_VERSION_2);
        auto bytes = output.str();
        return [NSData dataWithBytes:bytes.data() length:bytes.size()];
    } catch (...) { return nil; }
}

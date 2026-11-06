// SPDX-License-Identifier: MPL-2.0
import Foundation

public extension MachineQueryRequest {
    /// Clear endpoints with an actual body collision near the middle of a turn.
    static func midpointCollision(synchronized:Bool = false) -> Self {
        let z = MachineAxis(id:"Z",kind:.linear,axis:[0,0,1],limits:[0,20])
        let c = MachineAxis(id:"C",kind:.revolute,parent:"Z",axis:[0,0,1],limits:[-1080,1080])
        let tool = MachineBody(id:"turret-tool",resourceID:"turret-upper",
                               attach:.init(axis:"C",frame:.init(originMM:[10,0,0])),shape:.init(type:.box,halfExtentsMM:[1,1,1]))
        let fixture = MachineBody(id:"fixture",frame:.init(originMM:[10,0,synchronized ? 6.5 : 5]),
                                  shape:.init(type:.box,halfExtentsMM:[0.5,0.5,0.5]))
        var request = Self(chain:.init(axes:[z,c]),bodies:[tool],fixtures:[fixture],
                           motion:synchronized ? nil : .rotary("C",from:-90,to:90),
                           motions:synchronized ? [.linear("Z",from:5,to:8),.rotary("C",from:-90,to:90)] : nil,
                           jointPositions:synchronized ? nil : ["Z":5])
        request.budget.maxRotationDegPerSample = 5
        return request
    }
}

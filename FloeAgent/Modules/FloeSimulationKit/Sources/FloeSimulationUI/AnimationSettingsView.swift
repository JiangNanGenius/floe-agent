import SwiftUI
import FloeSimulationCore
import FloeSimulationAnimation

struct SimulationAnimationSettingsView: View {
    @Bindable var model: SimulationWorkbenchModel
    private var graph: Binding<SimulationAnimationGraph> { .init(get:{ model.animationGraph },set:{ model.writeAnimationGraph($0) }) }
    var body: some View {
        Form {
            Section(simulationText("Animation","动画")) {
                SimulationNumberField(label:simulationText("Duration","时长"),value:graph.durationSeconds,unit:"s")
                Slider(value:$model.animationTimeSeconds,in:0...max(0.001,model.animationGraph.durationSeconds.isFinite ? model.animationGraph.durationSeconds : 1)).onChange(of:model.animationTimeSeconds) { model.previewAnimation() }
                Button(simulationText("Preview pose","预览姿态")) { model.previewAnimation() }
            }
            Section(simulationText("Animation layers","动画层")) {
                ForEach(graph.layers) { $layer in
                    DisclosureGroup(simulationText("Layer","图层")) {
                        SimulationNumberField(label:simulationText("Weight","权重"),value:$layer.weight)
                        Toggle(simulationText("Additive","附加混合"),isOn:$layer.additive)
                        ForEach($layer.tracks) { $track in
                            DisclosureGroup(track.targetID) {
                                TextField(simulationText("Object, bone or camera","对象、骨骼或相机"),text:$track.targetID)
                                ForEach(track.keys.indices,id:\.self) { index in
                                    DisclosureGroup("\(track.keys[index].timeSeconds.formatted()) s") {
                                        SimulationNumberField(label:simulationText("Time","时间"),value:$track.keys[index].timeSeconds,unit:"s")
                                        SimulationTransformFields(transform:$track.keys[index].transform)
                                    }
                                }
                                Button(simulationText("Add key","添加关键帧")) { let next = min(model.animationGraph.durationSeconds,(track.keys.last?.timeSeconds ?? 0)+0.1); if next > (track.keys.last?.timeSeconds ?? -1) { track.keys.append(.init(timeSeconds:next,transform:track.keys.last?.transform ?? .identity)) } }
                                Button(simulationText("Remove track","移除轨道"),role:.destructive) { layer.tracks.removeAll { $0.id == track.id } }
                            }
                        }
                        Button(simulationText("Add track","添加轨道")) { layer.tracks.append(.init(targetID:"object-\(layer.tracks.count+1)",keys:[.init(timeSeconds:0,transform:.identity)])) }
                    }
                }
                Button(simulationText("Add layer","添加图层")) { var value = model.animationGraph; value.layers.append(.init()); model.writeAnimationGraph(value) }
                Button(simulationText("Add camera track","添加相机轨道")) {
                    var value = model.animationGraph
                    value.layers.append(.init(tracks:[.init(targetID:"camera",keys:[.init(timeSeconds:0,transform:.identity),.init(timeSeconds:value.durationSeconds,transform:.init(translation:.init(1,0,0)))])]))
                    model.writeAnimationGraph(value)
                }
            }
            Section(simulationText("Skeleton and IK","骨骼与 IK")) {
                ForEach(graph.bones) { $bone in
                    DisclosureGroup(bone.id) { SimulationTransformFields(transform:$bone.restLocal) }
                }
                Button(simulationText("Add bone","添加骨骼")) { var value = model.animationGraph; value.bones.append(.init(id:"bone-\(value.bones.count+1)",parentID:value.bones.last?.id,restLocal:.init(translation:.init(0,0.5,0)))); model.writeAnimationGraph(value) }
                ForEach(model.animationGraph.ikChains.indices,id:\.self) { index in
                    SimulationVectorFields(title:simulationText("IK target","IK 目标"),value:graph.ikChains[index].targetMeters,unit:"m")
                    SimulationVectorFields(title:simulationText("IK pole","IK 极向目标"),value:graph.ikChains[index].poleMeters,unit:"m")
                    SimulationNumberField(label:simulationText("IK weight","IK 权重"),value:graph.ikChains[index].weight)
                }
                Button(simulationText("Add two-bone IK","添加双骨骼 IK")) {
                    var value = model.animationGraph
                    guard value.bones.count >= 3 else { return }
                    value.ikChains.append(.init(rootID:value.bones[0].id,middleID:value.bones[1].id,endID:value.bones[2].id,targetMeters:.init(0.5,0.8,0),poleMeters:.init(0,0,1)))
                    model.writeAnimationGraph(value)
                }.disabled(model.animationGraph.bones.count < 3)
            }
            Section(simulationText("Physics blend","物理混合")) {
                Button(simulationText("Attach current physics cache","关联当前物理缓存")) { if let result = model.result { var value = model.animationGraph; value.physicsResultID = result.id; model.writeAnimationGraph(value) } }.disabled(model.result?.backend.id != "floe.rapier" && model.result?.backend.id != "floe.particles")
                ForEach(model.animationGraph.physicsBindings.indices,id:\.self) { index in
                    TextField(simulationText("Target","目标"),text:graph.physicsBindings[index].targetID)
                    SimulationChoicePicker(title:simulationText("Control","控制方式"),selection:graph.physicsBindings[index].control)
                    SimulationNumberField(label:simulationText("Blend weight","混合权重"),value:graph.physicsBindings[index].weight)
                }
                Button(simulationText("Bind scene bodies","绑定场景物体")) {
                    var value = model.animationGraph
                    for body in model.physics.bodies where !value.physicsBindings.contains(where:{ $0.targetID == body.sourceObjectID }) { value.physicsBindings.append(.init(targetID:body.sourceObjectID,bodyID:body.id)) }
                    model.writeAnimationGraph(value)
                }.disabled(model.animationGraph.physicsResultID == nil)
                Button(simulationText("Bake and export motion","烘焙并导出运动")) { Task { await model.bakeAnimation() } }.disabled(model.baking).accessibilityIdentifier("simulation.bake")
                if model.baking {
                    ProgressView(value:model.bakeProgress?.fraction)
                    Button(model.bakeCancelling ? simulationText("Stopping","正在停止") : simulationText("Stop baking","停止烘焙")) { model.cancelBake() }.disabled(model.bakeCancelling)
                }
                if let url = model.exportURL { ShareLink(item:url) { Label(simulationText("Share motion","共享运动"),systemImage:"square.and.arrow.up") } }
            }
        }
    }
}

struct SimulationTransformFields: View {
    @Binding var transform: SimulationAnimationTransform
    private var angles: SimulationVector3 {
        let q = transform.rotation
        return .init(atan2(2*(q.w*q.x+q.y*q.z),1-2*(q.x*q.x+q.y*q.y)),asin(min(1,max(-1,2*(q.w*q.y-q.z*q.x)))),atan2(2*(q.w*q.z+q.x*q.y),1-2*(q.y*q.y+q.z*q.z))) * (180/Double.pi)
    }
    private var rotation: Binding<SimulationVector3> {
        .init(get:{ angles },set:{ angles in
            let x = angles.x*Double.pi/360, y = angles.y*Double.pi/360, z = angles.z*Double.pi/360
            transform.rotation = .init(x:sin(x)*cos(y)*cos(z)-cos(x)*sin(y)*sin(z),y:cos(x)*sin(y)*cos(z)+sin(x)*cos(y)*sin(z),z:cos(x)*cos(y)*sin(z)-sin(x)*sin(y)*cos(z),w:cos(x)*cos(y)*cos(z)+sin(x)*sin(y)*sin(z))
        })
    }
    var body: some View {
        SimulationVectorFields(title:simulationText("Translation","平移"),value:$transform.translation,unit:"m")
        SimulationVectorFields(title:simulationText("Rotation","旋转"),value:rotation,unit:"°")
        SimulationVectorFields(title:simulationText("Scale","缩放"),value:$transform.scale)
    }
}

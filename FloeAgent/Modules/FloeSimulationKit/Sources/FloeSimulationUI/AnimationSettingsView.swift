import SwiftUI
import FloeSimulationCore
import FloeSimulationAnimation
import FloeSimulationRuntime

struct SimulationAnimationSettingsView: View {
    @Bindable var model: SimulationWorkbenchModel
    @State private var pinRagdollRoot = false
    private var graph: Binding<SimulationAnimationGraph> { .init(get:{ model.animationGraph },set:{ model.writeAnimationGraph($0) }) }
    var body: some View {
        Form {
            if model.sourceAnimationGraph != nil || model.sourceAnimationMessage != nil {
                Section(simulationText("Existing model animation","模型已有动画")) {
                    if let message = model.sourceAnimationMessage { Text(message).foregroundStyle(.secondary) }
                    if model.sourceAnimationGraph != nil {
                        Button(simulationText("Import rig and active clip","导入骨骼与当前片段")) { model.importSourceAnimation() }
                            .disabled(model.baking).accessibilityIdentifier("simulation.animation.import")
                    }
                }
            }
            Section(simulationText("Animation","动画")) {
                SimulationNumberField(label:simulationText("Duration","时长"),value:graph.durationSeconds,unit:"s")
                Button(simulationText("Preview pose","预览姿态")) { model.previewAnimation() }
                if model.animationGraph.source != model.document.source {
                    Button(simulationText("Use current model","使用当前模型")) {
                        var value = model.animationGraph; value.source = model.document.source
                        value.physicsResultID = nil; value.physicsBindings = []; model.writeAnimationGraph(value)
                    }
                }
            }
            Section(simulationText("Animation layers","动画层")) {
                ForEach(graph.layers) { $layer in
                    DisclosureGroup(simulationText("Layer","图层")) {
                        SimulationNumberField(label:simulationText("Weight","权重"),value:$layer.weight)
                        Toggle(simulationText("Additive","附加混合"),isOn:$layer.additive)
                        ForEach($layer.tracks) { $track in
                            DisclosureGroup(model.sourceObjects.first { $0.id == track.targetID }?.name ?? track.targetID) {
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
                        Menu(simulationText("Add track","添加轨道")) {
                            ForEach(model.sourceObjects) { object in
                                Button(object.name) { layer.tracks.append(.init(targetID:object.id,keys:[.init(timeSeconds:0,transform:object.restTransform)])) }
                            }
                            ForEach(model.animationGraph.bones) { bone in
                                Button(bone.id) { layer.tracks.append(.init(targetID:bone.id,keys:[.init(timeSeconds:0,transform:bone.restLocal)])) }
                            }
                            Button(simulationText("Custom track","自定义轨道")) { layer.tracks.append(.init(targetID:"object-\(layer.tracks.count+1)",keys:[.init(timeSeconds:0,transform:.identity)])) }
                        }
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
            Section(simulationText("Ragdoll","布娃娃")) {
                Toggle(simulationText("Pin root","固定根骨骼"),isOn:$pinRagdollRoot)
                Button(simulationText("Generate bodies and joints","生成碰撞体与关节")) { model.createRagdoll(pinRoot:pinRagdollRoot) }
                    .disabled(model.animationGraph.bones.isEmpty || model.baking)
                Text(simulationText("Run the generated study, then attach its physics result to animate the skin.","运行生成的研究，再关联物理结果以驱动蒙皮。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(simulationText("Mesh skin and Morph","网格蒙皮与形态")) {
                ForEach(model.sourceObjects) { object in
                    Button(simulationText("Bind ","绑定 ")+object.name) { Task { await model.bindSourceMesh(object.id) } }
                        .disabled(model.animationGraph.bones.isEmpty || model.preparingSourceMesh)
                    SimulationMeshMorphEditor(model:model,object:object)
                }
                ForEach(model.animationGraph.meshBindings ?? [],id:\.sourceObjectID) { binding in
                    LabeledContent(model.sourceObjects.first { $0.id == binding.sourceObjectID }?.name ?? binding.sourceObjectID,
                                   value:"\(binding.skin.count) · \(binding.morphs.count)")
                }
                if model.preparingSourceMesh { ProgressView() }
            }
            Section(simulationText("Physics blend","物理混合")) {
                Button(simulationText("Attach current physics cache","关联当前物理缓存")) { model.attachCurrentPhysicsCache() }.disabled(model.result?.backend.id != "floe.rapier" && model.result?.backend.id != "floe.particles")
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
            }
            Section(simulationText("Export animation","导出动画")) {
                Picker(simulationText("Format","格式"),selection:$model.animationExportFormat) {
                    ForEach(model.availableAnimationExportFormats,id:\.self) { value in Text(value.simulationTitle).tag(value) }
                }
                Picker(simulationText("Frame rate","帧率"),selection:$model.animationFramesPerSecond) {
                    ForEach([24,30,60],id:\.self) { Text("\($0) fps").tag($0) }
                }
                Button(simulationText("Bake and export","烘焙并导出")) { Task { await model.bakeAnimation(format:model.animationExportFormat,framesPerSecond:model.animationFramesPerSecond) } }
                    .disabled(model.baking).accessibilityIdentifier("simulation.bake")
                if model.baking {
                    ProgressView(value:model.bakeProgress?.fraction)
                    Button(model.bakeCancelling ? simulationText("Stopping","正在停止") : simulationText("Stop baking","停止烘焙")) { model.cancelBake() }.disabled(model.bakeCancelling)
                }
                if let url = model.exportURL { ShareLink(item:url) { Label(simulationText("Share export","共享导出文件"),systemImage:"square.and.arrow.up") } }
            }
            if !model.savedAnimationExports.isEmpty {
                Section(simulationText("Saved exports","已保存导出")) {
                    ForEach(model.savedAnimationExports) { record in
                        Button { Task { await model.shareAnimationExport(record.id) } } label: {
                            LabeledContent(record.format.simulationTitle,value:"\(record.frameCount) · \(record.framesPerSecond) fps")
                        }
                    }
                }
            }
        }
    }
}

private extension SimulationAnimationExportFormat {
    var simulationTitle:String {
        switch self { case .motionJSON: simulationText("Motion data (JSON)","运动数据 (JSON)")
        case .glb: simulationText("3D animation (GLB)","三维动画 (GLB)")
        case .mp4: simulationText("Video (MP4)","视频 (MP4)") }
    }
}

private struct SimulationMeshMorphEditor:View {
    @Bindable var model:SimulationWorkbenchModel
    var object:SimulationSourceObject
    @State private var name = "Morph 1"
    @State private var vertex = 0
    @State private var offset = SimulationVector3.zero
    @State private var startWeight = 0.0
    @State private var endWeight = 1.0
    var body:some View {
        DisclosureGroup(simulationText("Edit vertex Morph","编辑顶点形变")) {
            TextField(simulationText("Name","名称"),text:$name)
            Stepper("\(simulationText("Vertex","顶点")) \(vertex)",value:$vertex,in:0...max(0,(model.sourceMeshes.first { $0.id == object.id }?.positionsMeters.count ?? 1)-1))
            SimulationVectorFields(title:simulationText("Offset","偏移"),value:$offset,unit:"m")
            SimulationNumberField(label:simulationText("Start weight","起始权重"),value:$startWeight)
            SimulationNumberField(label:simulationText("End weight","结束权重"),value:$endWeight)
            Button(simulationText("Apply Morph","应用形变")) { model.setMeshMorph(objectID:object.id,name:name,vertexIndex:vertex,offset:offset,startWeight:startWeight,endWeight:endWeight) }
                .disabled(model.baking)
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

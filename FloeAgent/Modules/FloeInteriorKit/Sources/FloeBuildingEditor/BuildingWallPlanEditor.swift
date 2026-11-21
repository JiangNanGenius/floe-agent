// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import FloeCAD
import FloeInteriorCore
import FloeBuildingRecords

/// Direct plan editing for real native walls: continuous point-to-point
/// drawing, one explicit finish action, exact length + angle, selection,
/// endpoint dragging, thickness/height and the two face finishes. The viewport
/// is fitted once per floor (or by Fit) and then stays stable while walls are
/// added or edited, so the next tap lands on the point the user saw.
@MainActor
struct BuildingWallPlanEditor: View {
    @Bindable var project: BuildingEditorProjectSession
    @Environment(\.locale) private var locale
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var snapshot: BuildingWallSnapshot?
    @State private var storeyID: UUID?
    @State private var selectedWallID: UUID?
    @State private var activeSide: InteriorWallSide?
    @State private var drawing = false
    @State private var panning = false
    @GestureState private var canvasDrag: DragGesture.Value?
    @GestureState private var pinch: MagnifyGesture.Value?
    @State private var pendingStart: [Double]?
    @State private var snapEnabled = true
    @State private var lengthText = "3000"
    @State private var angleText = "0"
    @State private var thicknessText = "200"
    @State private var heightText = "2700"
    @State private var drag: WallHandleDrag?
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    @State private var confirmingDelete = false
    @State private var viewport: WallViewport?
    @State private var planSize: CGSize = .zero

    private struct WallHandleDrag: Equatable {
        let wallID: UUID
        let end: InteriorWallEndpoint
        var point: [Double]
    }

    private func copy(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }

    private var floorWalls: [BuildingWallSnapshot.Wall] {
        (snapshot?.walls ?? []).filter { $0.storeyID == storeyID }
    }

    private var selectedWall: BuildingWallSnapshot.Wall? {
        selectedWallID.flatMap { id in snapshot?.walls.first { $0.id == id } }
    }

    private var currentStorey: BuildingWallSnapshot.Storey? {
        snapshot?.storeys.first { $0.id == storeyID } ?? snapshot?.storeys.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if snapshot != nil {
                GeometryReader { geometry in
                    let base = viewport ?? .fit(size: geometry.size, walls: floorWalls)
                    let visible = visibleViewport(base: base, size: geometry.size)
                    let current = WallPlanProjection(size: geometry.size, centre: visible.centre,
                                                     mmPerPoint: visible.mmPerPoint)
                    ZStack(alignment: .topLeading) {
                        planCanvas(projection: current)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in
                                guard !panning, pinch == nil else { return }
                                tap(current.plan(value.location), projection: current)
                            })
                            .simultaneousGesture(canvasGesture(base: base, projection: current))
                        if !panning { handleOverlay(projection: current) }
                    }
                    .coordinateSpace(name: "building.wall.viewport")
                    .clipped()
                    .onAppear {
                        planSize = geometry.size
                        if viewport == nil { viewport = .fit(size: geometry.size, walls: floorWalls) }
                    }
                    .onChange(of: geometry.size) { _, size in
                        planSize = size
                        if viewport == nil { viewport = .fit(size: size, walls: floorWalls) }
                    }
                    .simultaneousGesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            viewport = base.zoomed(by: value.magnification, size: geometry.size, anchor: value.startAnchor)
                        })
                }
                .frame(minHeight: sizeClass == .regular ? 380 : 300)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("building.walls.plan")
                .accessibilityValue(planAccessibilityValue)
                .accessibilityLabel(copy("墙体平面", "Wall plan"))
                inspector
            } else {
                ProgressView(copy("正在读取墙体…", "Reading walls…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = failure {
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(copy("关闭", "Dismiss")) { failure = nil }
                }
                .padding(10)
                .background(.bar)
            }
        }
        .task { reload() }
        .onChange(of: project.mountID) { _, _ in reload() }
        .onChange(of: project.nativeDocument.buildingChangeCount) { _, _ in
            if operation == nil { reload() }
        }
        .onDisappear { operation?.cancel(); operation = nil }
        .confirmationDialog(copy("删除这面墙？", "Delete this wall?"),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(copy("删除墙体及其门窗", "Delete wall and hosted openings"), role: .destructive) {
                guard let wall = selectedWall else { return }
                run {
                    let state = try currentWallState()
                    try await project.applyWallCommand(.deleteWall(wallID: wall.id),
                        expectedChangeCount: state.changeCount, expectedWallRevision: state.wallRevision)
                }
                selectedWallID = nil
                activeSide = nil
            }
            Button(copy("取消", "Cancel"), role: .cancel) {}
        }
    }

    private var planAccessibilityValue: String {
        let floor = currentStorey?.name ?? copy("楼层", "Floor")
        let wallCount = floorWalls.count
        let base = copy("\(floor)，\(wallCount) 面墙", "\(floor), \(wallCount) walls")
        guard let wall = selectedWall else { return base }
        let side = activeSide == nil ? "" : (activeSide == .left
            ? copy("，已选左饰面", ", left face selected")
            : copy("，已选右饰面", ", right face selected"))
        return base + copy("，已选 \(wall.name)", ", selected \(wall.name)") + side
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker(copy("楼层", "Floor"), selection: Binding(
                get: { storeyID ?? snapshot?.storeys.first?.id },
                set: { value in
                    storeyID = value
                    pendingStart = nil
                    selectedWallID = nil
                    activeSide = nil
                    viewport = nil
                    panning = false
                }
            )) {
                ForEach(snapshot?.storeys ?? []) { storey in
                    Text(storey.name).tag(Optional(storey.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(operation != nil)
            .accessibilityIdentifier("building.walls.floor")

            if drawing {
                Button(copy("完成画墙", "Finish walls")) { finishDrawing() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("building.walls.finish")
                    .accessibilityHint(copy("结束本次连续画墙，已经放置的墙保留。",
                                             "Ends this continuous run; walls already placed are kept."))
            } else {
                Button {
                    drawing = true
                    panning = false
                    pendingStart = nil
                    selectedWallID = nil
                    activeSide = nil
                } label: {
                    Label(copy("画墙", "Draw walls"), systemImage: "pencil.and.outline")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("building.walls.draw")
            }

            Toggle(isOn: $panning) { Image(systemName: "hand.draw") }
                .toggleStyle(.button)
                .accessibilityLabel(copy("平移视图", "Pan view"))
                .accessibilityIdentifier("building.walls.pan")

            Toggle(isOn: $snapEnabled) {
                Image(systemName: "dot.squareshape.split.2x2")
            }
            .toggleStyle(.button)
            .accessibilityLabel(copy("吸附", "Snap"))
            .accessibilityValue(snapEnabled ? copy("开", "On") : copy("关", "Off"))
            .accessibilityIdentifier("building.walls.snap")

            Button { fitToWindow() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(copy("适合窗口", "Fit to window"))
            .accessibilityIdentifier("building.walls.fit")

            Button { zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel(copy("放大", "Zoom in"))
                .accessibilityIdentifier("building.walls.zoom.in")
            Button { zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel(copy("缩小", "Zoom out"))
                .accessibilityIdentifier("building.walls.zoom.out")

            Spacer()
            Button {
                run {
                    let state = try currentWallState()
                    _ = try await project.undoWallChange(expectedChangeCount: state.changeCount,
                        expectedWallRevision: state.wallRevision)
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(project.busy || !project.canUndoWallChange)
            .accessibilityLabel(copy("撤销", "Undo"))
            .accessibilityIdentifier("building.walls.undo")
            Button {
                run {
                    let state = try currentWallState()
                    _ = try await project.redoWallChange(expectedChangeCount: state.changeCount,
                        expectedWallRevision: state.wallRevision)
                }
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(project.busy || !project.canRedoWallChange)
            .accessibilityLabel(copy("重做", "Redo"))
            .accessibilityIdentifier("building.walls.redo")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func planCanvas(projection: WallPlanProjection) -> some View {
        Canvas { context, size in
            drawGrid(projection: projection, context: &context)
            for wall in floorWalls {
                let a = projection.screen(wall.a), b = projection.screen(wall.b)
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let lineWidth = max(3, min(28, wall.thicknessMM / projection.mmPerPoint))
                let opacity = drag?.wallID == wall.id ? 0.28 : (wall.id == selectedWallID ? 1.0 : 0.82)
                context.stroke(path, with: .color(.primary.opacity(opacity)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                drawFinish(wall, side: .left, projection: projection, context: &context)
                drawFinish(wall, side: .right, projection: projection, context: &context)
                if wall.id == selectedWallID {
                    drawActiveSide(wall, projection: projection, context: &context)
                    drawDimension(wall, projection: projection, context: &context)
                }
            }
            if let drag, let wall = floorWalls.first(where: { $0.id == drag.wallID }) {
                let a = drag.end == .start ? drag.point : wall.a
                let b = drag.end == .start ? wall.b : drag.point
                var path = Path()
                path.move(to: projection.screen(a))
                path.addLine(to: projection.screen(b))
                context.stroke(path, with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            let previewStart = pendingStart ?? canvasDrag.map {
                snapped(projection.plan($0.startLocation), scale: projection.mmPerPoint)
            }
            if drawing, !panning, let previewStart {
                let start = projection.screen(previewStart)
                context.fill(Path(ellipseIn: CGRect(x: start.x - 7, y: start.y - 7, width: 14, height: 14)),
                             with: .color(.accentColor))
                let liveEnd = canvasDrag.map {
                    snapped(projection.plan($0.location), scale: projection.mmPerPoint, from: previewStart)
                }
                if let preview = liveEnd ?? exactPreview() {
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: projection.screen(preview))
                    context.stroke(path, with: .color(.accentColor.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    drawText(String(format: "%.0f mm", hypot(preview[0] - previewStart[0], preview[1] - previewStart[1])),
                             at: CGPoint(x: (start.x + projection.screen(preview).x) / 2,
                                         y: (start.y + projection.screen(preview).y) / 2 - 14),
                             context: &context)
                }
            }
            drawScaleRuler(size: size, projection: projection, context: &context)
        }
        .background(Color(uiColor: .systemBackground))
        .overlay {
            if floorWalls.isEmpty && !drawing {
                Text(copy("点「画墙」开始。", "Choose Draw walls to start."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func handleOverlay(projection: WallPlanProjection) -> some View {
        if let wall = selectedWall, wall.storeyID == storeyID, !drawing {
            let a = drag.flatMap { $0.wallID == wall.id && $0.end == .start ? $0.point : nil } ?? wall.a
            let b = drag.flatMap { $0.wallID == wall.id && $0.end == .end ? $0.point : nil } ?? wall.b
            handle(at: projection.screen(a), end: .start, wall: wall, projection: projection)
            handle(at: projection.screen(b), end: .end, wall: wall, projection: projection)
        }
    }

    private func handle(at point: CGPoint, end: InteriorWallEndpoint, wall: BuildingWallSnapshot.Wall,
                        projection: WallPlanProjection) -> some View {
        let origin = end == .start ? wall.a : wall.b
        return Circle()
            .fill(Color(uiColor: .systemBackground))
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 19, height: 19)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(point)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("building.wall.viewport")).onChanged { value in
                let point = draggedEndpoint(origin, translation: value.translation, excluding: wall.id, projection: projection)
                drag = WallHandleDrag(wallID: wall.id, end: end, point: point)
            }.onEnded { value in
                guard drag?.wallID == wall.id, drag?.end == end else { return }
                self.drag = nil
                let point = draggedEndpoint(origin, translation: value.translation, excluding: wall.id, projection: projection)
                guard point != origin else { return }
                run {
                    let state = try currentWallState()
                    try await project.applyWallCommand(
                        .moveEndpoint(wallID: wall.id, end: end, point: point),
                        expectedChangeCount: state.changeCount,
                        expectedWallRevision: state.wallRevision
                    )
                }
            })
            .accessibilityLabel(end == .start ? copy("起点", "Start point") : copy("终点", "End point"))
            .accessibilityIdentifier("building.walls.handle." + end.rawValue)
    }

    @ViewBuilder
    private var inspector: some View {
        VStack(spacing: 0) {
            if drawing {
                drawingInspector
                Divider()
            } else if let wall = selectedWall {
                wallInspector(wall)
            } else {
                Text(copy("点选一面墙可修改厚度、高度和两侧饰面；拖动端点可直接改长度。",
                          "Select a wall to edit thickness, height and both face finishes; drag an endpoint to change its length."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
    }

    private var drawingInspector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Label(pendingStart == nil ? copy("点取起点", "Tap the start") : copy("点取下一点", "Tap the next point"),
                      systemImage: "pencil.tip")
                    .font(.callout)
                numericField(copy("长度 mm", "Length mm"), text: $lengthText, id: "building.walls.length")
                numericField(copy("角度°", "Angle°"), text: $angleText, id: "building.walls.angle")
                Button(copy("按长度放置", "Place exact length")) {
                    guard let start = pendingStart else { return }
                    guard let length = Double(lengthText), let angle = Double(angleText),
                          let endpoint = InteriorWallPlanGeometry.exactEndpoint(
                            start: start, lengthMM: length, angleDegrees: angle) else {
                        failure = copy("请输入有效长度和角度。", "Enter a valid length and angle.")
                        return
                    }
                    addWall(from: start, to: endpoint)
                }
                .disabled(pendingStart == nil)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("building.walls.placeExact")
                numericField(copy("墙厚", "Thickness"), text: $thicknessText, id: "building.walls.new.thickness")
                numericField(copy("墙高", "Height"), text: $heightText, id: "building.walls.new.height")
                Text(copy("继续点取会从当前端点续画；“完成画墙”结束本次绘制。",
                          "Each further tap continues from the last point. Finish walls ends this run."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .accessibilityIdentifier("building.walls.drawing.panel")
    }

    private func wallInspector(_ wall: BuildingWallSnapshot.Wall) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(wall.name).font(.headline)
                Text(String(format: copy("长度 %.0f mm", "Length %.0f mm"),
                            hypot(wall.b[0] - wall.a[0], wall.b[1] - wall.a[1])))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                numericField(copy("墙厚", "Thickness"), text: $thicknessText, id: "building.walls.thickness", commit: { value in
                    updateWall(wall, thickness: value, height: nil, name: nil)
                })
                numericField(copy("墙高", "Height"), text: $heightText, id: "building.walls.height", commit: { value in
                    updateWall(wall, thickness: nil, height: value, name: nil)
                })
                sideButton(wall, side: .left)
                sideButton(wall, side: .right)
                Button {
                    run {
                        let state = try currentWallState()
                        try await project.applyWallCommand(.swapFinishes(wallID: wall.id),
                            expectedChangeCount: state.changeCount,
                            expectedWallRevision: state.wallRevision)
                    }
                } label: {
                    Label(copy("对调饰面", "Swap finishes"), systemImage: "arrow.left.arrow.right")
                }
                .disabled(project.busy)
                .accessibilityIdentifier("building.walls.swapFinishes")
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(copy("删除", "Delete"), systemImage: "trash")
                }
                .accessibilityIdentifier("building.walls.delete")
                Button(copy("完成", "Done")) { selectedWallID = nil; activeSide = nil }
                    .accessibilityIdentifier("building.walls.deselect")
            }
            .padding(10)
        }
        .accessibilityIdentifier("building.walls.properties")
        .onAppear {
            thicknessText = String(format: "%.0f", wall.thicknessMM)
            heightText = String(format: "%.0f", wall.heightMM)
        }
        .onChange(of: wall) { _, value in
            thicknessText = String(format: "%.0f", value.thicknessMM)
            heightText = String(format: "%.0f", value.heightMM)
        }
    }

    private func sideButton(_ wall: BuildingWallSnapshot.Wall, side: InteriorWallSide) -> some View {
        let selected = activeSide == side
        let finishID = side == .left ? wall.leftFinishID : wall.rightFinishID
        return Menu {
            Button(copy("查看这一面", "Show this face")) { activeSide = side }
            Divider()
            Button(copy("无饰面", "No finish")) { setFinish(wall, side: side, id: nil) }
            ForEach(snapshot?.finishCatalog ?? []) { finish in
                Button {
                    setFinish(wall, side: side, id: finish.id)
                } label: {
                    Label(finish.name(chinese: locale.language.languageCode?.identifier == "zh"),
                          systemImage: finishID == finish.id ? "checkmark" : "square")
                }
            }
        } label: {
            Label((side == .left ? copy("左饰面", "Left face") : copy("右饰面", "Right face"))
                    + ": " + finishMenuSummary(finishID),
                  systemImage: selected ? "rectangle.lefthalf.inset.filled" : "rectangle.split.2x1")
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
        .disabled(project.busy)
        .accessibilityIdentifier("building.walls.finish." + side.rawValue)
        .accessibilityValue(selected ? copy("已选", "Selected") : copy("未选", "Not selected"))
    }

    private func numericField(_ title: String, text: Binding<String>, id: String,
                              commit: ((Double) -> Void)? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(id)
                .onSubmit {
                    guard let value = Double(text.wrappedValue) else { return }
                    commit?(value)
                }
            if let commit {
                Button {
                    guard let value = Double(text.wrappedValue) else { return }
                    commit(value)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copy("应用", "Apply"))
                .accessibilityIdentifier(id + ".apply")
            }
        }
    }

    private func finishMenuSummary(_ id: String?) -> String {
        guard let id, let finish = InteriorWallFinishCatalog.finish(id: id) else {
            return copy("无饰面", "No finish")
        }
        return finish.name(chinese: locale.language.languageCode?.identifier == "zh")
    }

    private func drawFinish(_ wall: BuildingWallSnapshot.Wall, side: InteriorWallSide,
                            projection: WallPlanProjection, context: inout GraphicsContext) {
        guard let hex = side == .left ? wall.leftFinishColorHex : wall.rightFinishColorHex else { return }
        drawStripe(wall, side: side, hex: hex, width: 5, projection: projection, context: &context)
    }

    /// The selected face is shown as a wider translucent stripe even when it
    /// has no finish yet. This is the only persistent visual cue that the
    /// left/right assignment the menu will change is the side the user meant.
    private func drawActiveSide(_ wall: BuildingWallSnapshot.Wall,
                                projection: WallPlanProjection, context: inout GraphicsContext) {
        guard let activeSide else { return }
        drawStripe(wall, side: activeSide, hex: "007AFF", width: 14, opacity: 0.35,
                   projection: projection, context: &context)
        let midpoint = projection.screen([
            (wall.a[0] + wall.b[0]) / 2,
            (wall.a[1] + wall.b[1]) / 2,
        ])
        drawText(activeSide == .left ? copy("左饰面", "Left face") : copy("右饰面", "Right face"),
                 at: CGPoint(x: midpoint.x, y: midpoint.y + 30), context: &context)
    }

    private func drawStripe(_ wall: BuildingWallSnapshot.Wall, side: InteriorWallSide, hex: String,
                            width: CGFloat, opacity: Double = 1,
                            projection: WallPlanProjection, context: inout GraphicsContext) {
        let segment = InteriorWallPlanSegment(a: wall.a, b: wall.b, thicknessMM: wall.thicknessMM)
        let offset = (wall.thicknessMM / 2 + 35) * (side == .left ? 1 : -1)
        guard let stripe = InteriorWallPlanGeometry.offsetSegment(segment, by: offset) else { return }
        var path = Path()
        path.move(to: projection.screen(stripe.a))
        path.addLine(to: projection.screen(stripe.b))
        context.stroke(path, with: .color(Color(hex: hex).opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: width > 8 ? [] : [7, 4]))
    }

    private func drawDimension(_ wall: BuildingWallSnapshot.Wall, projection: WallPlanProjection,
                               context: inout GraphicsContext) {
        let a = projection.screen(wall.a), b = projection.screen(wall.b)
        drawText(String(format: "%.0f mm", hypot(wall.b[0] - wall.a[0], wall.b[1] - wall.a[1])),
                 at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 18), context: &context)
    }

    private func drawText(_ value: String, at point: CGPoint, context: inout GraphicsContext) {
        context.draw(Text(value).font(.caption2).foregroundStyle(.secondary), at: point)
    }

    private func fitToWindow() {
        viewport = .fit(size: planSize, walls: floorWalls)
    }

    private func zoom(by factor: Double) {
        let base = viewport ?? .fit(size: planSize, walls: floorWalls)
        viewport = base.zoomed(by: factor)
    }

    private func tap(_ point: [Double], projection: WallPlanProjection) {
        guard !project.busy, operation == nil else { return }
        if drawing {
            let snappedPoint = snapped(point, scale: projection.mmPerPoint, from: pendingStart)
            guard let start = pendingStart else {
                pendingStart = snappedPoint
                return
            }
            guard hypot(snappedPoint[0] - start[0], snappedPoint[1] - start[1]) >= 1 else { return }
            addWall(from: start, to: snappedPoint)
            return
        }
        if let wall = hitWall(point, scale: projection.mmPerPoint) {
            selectedWallID = wall.id
            activeSide = side(of: point, wall: wall)
            thicknessText = String(format: "%.0f", wall.thicknessMM)
            heightText = String(format: "%.0f", wall.heightMM)
        } else {
            selectedWallID = nil
            activeSide = nil
        }
    }

    /// Which face the tap was nearest. The authored direction a→b defines the
    /// left normal; a tap exactly on the centre line leaves the side unset.
    private func side(of point: [Double], wall: BuildingWallSnapshot.Wall) -> InteriorWallSide? {
        let dx = wall.b[0] - wall.a[0], dy = wall.b[1] - wall.a[1]
        let cross = dx * (point[1] - wall.a[1]) - dy * (point[0] - wall.a[0])
        let length = hypot(dx, dy)
        guard length > 0.000_001, abs(cross) / length > 20 else { return nil }
        return cross > 0 ? .left : .right
    }

    private func hitWall(_ point: [Double], scale: Double) -> BuildingWallSnapshot.Wall? {
        let segments = floorWalls.map {
            InteriorWallPlanSegment(a: $0.a, b: $0.b, thicknessMM: $0.thicknessMM)
        }
        guard let index = InteriorWallPlanGeometry.hitTest(point, segments: segments,
                                                           minimumToleranceMM: 12 * scale) else { return nil }
        return floorWalls[index]
    }

    private func snapped(_ point: [Double], scale: Double, from start: [Double]? = nil,
                         excluding wallID: UUID? = nil) -> [Double] {
        guard snapEnabled else { return InteriorWallPlanGeometry.chainPoint(point) }
        let segments = floorWalls.filter { $0.id != wallID }.map {
            InteriorWallPlanSegment(a: $0.a, b: $0.b, thicknessMM: $0.thicknessMM)
        }
        // Existing corners and walls win over grid and orthogonal guides.
        let target = InteriorWallPlanGeometry.snapped(point, segments: segments, gridMM: 0,
            endpointToleranceMM: min(450, 14 * scale), axisToleranceMM: min(300, 9 * scale))
        if target != point { return target }
        var grid = InteriorWallPlanGeometry.snapped(point, segments: [], gridMM: 50)
        if let start {
            let dx = abs(point[0] - start[0]), dy = abs(point[1] - start[1])
            let tolerance = min(250, 9 * scale)
            if dy <= tolerance, dx > tolerance { grid[1] = start[1] }
            if dx <= tolerance, dy > tolerance { grid[0] = start[0] }
        }
        return grid
    }

    private func draggedEndpoint(_ origin: [Double], translation: CGSize, excluding wallID: UUID,
                                 projection: WallPlanProjection) -> [Double] {
        let point = [origin[0] + translation.width * projection.mmPerPoint,
                     origin[1] - translation.height * projection.mmPerPoint]
        return snapped(point, scale: projection.mmPerPoint, excluding: wallID)
    }

    private func visibleViewport(base: WallViewport, size: CGSize) -> WallViewport {
        if let pinch { return base.zoomed(by: pinch.magnification, size: size, anchor: pinch.startAnchor) }
        if panning, let canvasDrag { return base.panned(by: canvasDrag.translation) }
        return base
    }

    private func canvasGesture(base: WallViewport, projection: WallPlanProjection) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("building.wall.viewport"))
            .updating($canvasDrag) { value, state, _ in
                if panning || drawing { state = value }
            }
            .onEnded { value in
                guard pinch == nil else { return }
                if panning {
                    viewport = base.panned(by: value.translation)
                } else if drawing, operation == nil, !project.busy {
                    let start = pendingStart ?? snapped(projection.plan(value.startLocation), scale: projection.mmPerPoint)
                    let end = snapped(projection.plan(value.location), scale: projection.mmPerPoint, from: start)
                    guard hypot(end[0] - start[0], end[1] - start[1]) >= 1 else { return }
                    addWall(from: start, to: end)
                }
            }
    }

    private func gridInterval(at scale: Double) -> Double {
        let target = scale * 36
        let magnitude = pow(10, floor(log10(target)))
        return [magnitude, 2 * magnitude, 5 * magnitude, 10 * magnitude].first { $0 >= target } ?? target
    }

    private func drawScaleRuler(size: CGSize, projection: WallPlanProjection, context: inout GraphicsContext) {
        let distance = gridInterval(at: projection.mmPerPoint)
        let width = distance / projection.mmPerPoint
        let right = size.width - 18
        let left = right - width
        let y = size.height - 16
        var ruler = Path()
        ruler.move(to: CGPoint(x: left, y: y - 3))
        ruler.addLine(to: CGPoint(x: left, y: y))
        ruler.addLine(to: CGPoint(x: right, y: y))
        ruler.addLine(to: CGPoint(x: right, y: y - 3))
        context.stroke(ruler, with: .color(.secondary), lineWidth: 1)
        let title = distance >= 1_000 ? String(format: "%g m", distance / 1_000) : String(format: "%g mm", distance)
        drawText(title, at: CGPoint(x: (left + right) / 2, y: y - 10), context: &context)
    }

    private func drawGrid(projection: WallPlanProjection, context: inout GraphicsContext) {
        let interval = gridInterval(at: projection.mmPerPoint)
        let topLeft = projection.plan(.zero)
        let bottomRight = projection.plan(CGPoint(x: projection.size.width, y: projection.size.height))
        var grid = Path()
        for x in stride(from: ceil(topLeft[0] / interval) * interval, through: bottomRight[0], by: interval) {
            let x = projection.screen([x, 0]).x
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: projection.size.height))
        }
        for y in stride(from: ceil(bottomRight[1] / interval) * interval, through: topLeft[1], by: interval) {
            let y = projection.screen([0, y]).y
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: projection.size.width, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.17)), lineWidth: 0.5)
    }

    private func exactPreview() -> [Double]? {
        guard let start = pendingStart, let length = Double(lengthText), let angle = Double(angleText) else { return nil }
        return InteriorWallPlanGeometry.exactEndpoint(start: start, lengthMM: length, angleDegrees: angle)
    }

    private func addWall(from start: [Double], to end: [Double]) {
        guard let thickness = Double(thicknessText), let height = Double(heightText) else {
            failure = copy("请输入有效墙厚和墙高。", "Enter a valid wall thickness and height.")
            return
        }
        let floor = currentStorey
        run {
            let state = try currentWallState()
            _ = try await project.applyWallCommand(
                .addWall(storeyID: floor?.id, a: start, b: end,
                         thicknessMM: thickness, heightMM: height, name: nil),
                expectedChangeCount: state.changeCount,
                expectedWallRevision: state.wallRevision
            )
            if drawing, storeyID == floor?.id { pendingStart = end }
            reload()
        }
    }

    private func updateWall(_ wall: BuildingWallSnapshot.Wall, thickness: Double?, height: Double?, name: String?) {
        run {
            let state = try currentWallState()
            _ = try await project.applyWallCommand(
                .updateWall(wallID: wall.id, thicknessMM: thickness, heightMM: height, name: name),
                expectedChangeCount: state.changeCount,
                expectedWallRevision: state.wallRevision
            )
            reload()
        }
    }

    private func setFinish(_ wall: BuildingWallSnapshot.Wall, side: InteriorWallSide, id: String?) {
        activeSide = side
        run {
            let state = try currentWallState()
            _ = try await project.applyWallCommand(
                .setFinish(wallID: wall.id, side: side, finishID: id),
                expectedChangeCount: state.changeCount,
                expectedWallRevision: state.wallRevision
            )
            reload()
        }
    }

    private func finishDrawing() {
        drawing = false
        panning = false
        pendingStart = nil
        drag = nil
    }

    private func currentWallState() throws -> (changeCount: Int, wallRevision: Int) {
        guard let snapshot else { throw BuildingEditorProjectError.closed }
        return (snapshot.changeCount, snapshot.wallRevision)
    }

    private func reload() {
        do {
            let value = try project.wallSnapshot()
            snapshot = value
            if storeyID == nil || !value.storeys.contains(where: { $0.id == storeyID }) {
                storeyID = value.storeys.first?.id
                viewport = nil
            }
            if let selectedWallID, !value.walls.contains(where: { $0.id == selectedWallID }) {
                self.selectedWallID = nil
                activeSide = nil
            }
            if let floor = value.storeys.first(where: { $0.id == storeyID }),
               Double(heightText) == nil || heightText == "2700" {
                heightText = String(format: "%.0f", floor.heightMM)
            }
            if viewport == nil, planSize.width > 0, planSize.height > 0 {
                viewport = .fit(size: planSize, walls: value.walls.filter { $0.storeyID == storeyID })
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        failure = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do {
                try await work()
                reload()
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
                reload()
            }
        }
    }
}

/// Stable viewport: only the centre and scale are stored. Adding a wall never
/// changes them; Fit (or a floor change) recomputes them deliberately.
struct WallViewport: Equatable {
    var centre: [Double]
    var mmPerPoint: Double

    static func fit(size: CGSize, walls: [BuildingWallSnapshot.Wall]) -> WallViewport {
        let points = walls.flatMap { [$0.a, $0.b] }
        let xs = points.map { $0[0] }, ys = points.map { $0[1] }
        let minX = xs.min() ?? -5000, maxX = xs.max() ?? 5000
        let minY = ys.min() ?? -4000, maxY = ys.max() ?? 4000
        let width = max(size.width, 1), height = max(size.height, 1)
        let scale = max(4, max((maxX - minX + 3000) / max(1, width - 48),
                               (maxY - minY + 3000) / max(1, height - 48)))
        return WallViewport(centre: [(minX + maxX) / 2, (minY + maxY) / 2], mmPerPoint: scale)
    }

    func panned(by translation: CGSize) -> WallViewport {
        WallViewport(centre: [centre[0] - translation.width * mmPerPoint,
                              centre[1] + translation.height * mmPerPoint], mmPerPoint: mmPerPoint)
    }

    func zoomed(by factor: Double, size: CGSize = .zero, anchor: UnitPoint = .center) -> WallViewport {
        let next = max(1, min(2000, mmPerPoint / max(0.2, min(5, factor.isFinite ? factor : 1))))
        let delta = mmPerPoint - next
        return WallViewport(centre: [centre[0] + (anchor.x - 0.5) * size.width * delta,
                                     centre[1] - (anchor.y - 0.5) * size.height * delta], mmPerPoint: next)
    }
}

private struct WallPlanProjection: Equatable {
    let size: CGSize
    let centre: [Double]
    let mmPerPoint: Double

    func screen(_ point: [Double]) -> CGPoint {
        CGPoint(x: size.width / 2 + (point[0] - centre[0]) / mmPerPoint,
                y: size.height / 2 - (point[1] - centre[1]) / mmPerPoint)
    }

    func plan(_ point: CGPoint) -> [Double] {
        [centre[0] + (point.x - size.width / 2) * mmPerPoint,
         centre[1] - (point.y - size.height / 2) * mmPerPoint]
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        if cleaned.count == 6 {
            self.init(.sRGB,
                      red: Double((value >> 16) & 0xff) / 255,
                      green: Double((value >> 8) & 0xff) / 255,
                      blue: Double(value & 0xff) / 255,
                      opacity: 1)
        } else {
            self = .gray
        }
    }
}
#endif

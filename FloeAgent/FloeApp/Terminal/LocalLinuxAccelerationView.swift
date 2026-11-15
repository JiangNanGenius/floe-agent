// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct LocalLinuxAccelerationView: View {
    let owner: LocalLinuxAccelerationOwner
    let display: LocalLinuxDisplayOwner
    @Environment(\.dismiss) private var dismiss
    @State private var softwareBlender = false
    @State private var screen: ScreenPresentation?

    private struct ScreenPresentation: Identifiable {
        let id = "local-linux-screen"
        let owner: LocalLinuxDisplayOwner
    }
    private var inventory: LinuxAccelerationInventory? {
        owner.inventoryEnvironmentID == display.environmentID ? owner.inventory : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { screen = ScreenPresentation(owner: display) } label: {
                        Label(t("打开屏幕", "Open screen"), systemImage: "display")
                    }
                    Button { run(.graphics) } label: {
                        Label(t("查看图形设备", "Inspect graphics device"), systemImage: "cpu")
                    }
                    .disabled(owner.isBusy || inventory?.graphics.inspectorInstalled != true)
                    Button {
                        if let id = display.environmentID {
                            screen = ScreenPresentation(owner: display)
                            Task {
                                await display.startDisplay()
                                await owner.diagnose(.openGL, environmentID: id)
                            }
                        }
                    } label: {
                        Label(t("查看 OpenGL（GLX）", "Inspect OpenGL (GLX)"), systemImage: "paintbrush")
                    }
                    .disabled(owner.isBusy || inventory?.graphics.glxInspectorInstalled != true)
                    Button { run(.headlessOpenGL) } label: {
                        Label(t("检查无窗口 EGL", "Check headless EGL"), systemImage: "rectangle.dashed")
                    }
                    .disabled(owner.isBusy || inventory?.graphics.eglInspectorInstalled != true || inventory?.graphics.eglLibraryInstalled == false)
                } header: { Text(t("图形", "Graphics")) }
                  footer: { Text(t("OpenGL 使用当前项目屏幕；无窗口 EGL 不需要屏幕。", "OpenGL uses the current project screen; headless EGL does not.")) }

                Section {
                    Button { run(.video) } label: {
                        Label(t("查看支持格式", "View supported formats"), systemImage: "film")
                    }
                    .disabled(owner.isBusy || inventory?.video.clientInstalled != true)
                    if inventory?.video.clientInstalled == false {
                        updateComponentNotice
                    }
                } header: { Text(t("视频编解码", "Video codecs")) }

                Section {
                    HStack {
                        Button(t("自动", "Automatic")) { mode("auto") }
                        Spacer()
                        Button(t("开启", "On")) { mode("on") }
                        Spacer()
                        Button(t("关闭", "Off")) { mode("off") }
                    }
                    .disabled(owner.isBusy || inventory?.compute.runnerInstalled != true)
                    Button { run(.compute) } label: {
                        Label(t("运行计算检查", "Run compute check"), systemImage: "checkmark.circle")
                    }
                    .disabled(owner.isBusy || inventory?.compute.probeInstalled != true || inventory?.compute.providerInstalled != true)
                    if inventory?.compute.runnerInstalled == false { updateComponentNotice }
                } header: { Text(t("计算加速", "Compute acceleration")) }
                  footer: { Text(t("设置将用于新启动的程序。", "Applies to newly started programs.")) }

                Section {
                    Button { run(.openCL) } label: {
                        Label(t("查看 OpenCL 状态", "Check OpenCL status"), systemImage: "list.bullet.rectangle")
                    }
                    .disabled(owner.isBusy || inventory?.compute.openCLProbeInstalled != true)
                    Button { run(.openCLProbe) } label: {
                        Label(t("运行 OpenCL 计算检查", "Run OpenCL compute check"), systemImage: "checkmark.seal")
                    }
                    .disabled(owner.isBusy || inventory?.compute.openCLProbeInstalled != true)
                    if inventory?.compute.openCLProbeInstalled == false { updateComponentNotice }
                } header: { Text("OpenCL") }
                  footer: { Text(t("可查看选中的 CPU 或 GPU。运行计算需要在这个 Linux 环境中安装 OpenCL 驱动。", "Check which CPU or GPU is selected. Running a computation requires an OpenCL driver in this Linux environment.")) }

                Section {
                    Button { run(.blender) } label: {
                        Label(t("查看 Blender 支持情况", "Check Blender support"), systemImage: "info.circle")
                    }
                    .disabled(owner.isBusy || inventory?.blender.launcherInstalled != true)
                    Toggle(t("使用软件图形", "Use software graphics"), isOn: $softwareBlender)
                        .disabled(owner.launching || owner.blenderRunning)
                    Button {
                        screen = ScreenPresentation(owner: display)
                        Task { await owner.launchBlender(display: display, software: softwareBlender) }
                    } label: {
                        Label(t("打开 Blender", "Open Blender"), systemImage: "cube")
                    }
                    .disabled(owner.launching || owner.blenderRunning || inventory?.blender.launcherInstalled != true || inventory?.blender.applicationInstalled != true)
                    if owner.blenderRunning, owner.activeEnvironmentID == display.environmentID {
                        Label(t("Blender 正在运行", "Blender is running"), systemImage: "play.circle")
                        Button(role: .destructive) {
                            Task { await owner.stopBlender(environmentID: display.environmentID) }
                        } label: { Label(t("停止 Blender", "Stop Blender"), systemImage: "stop.circle") }
                    }
                    if inventory?.blender.applicationInstalled == false {
                        Text(t("请先在当前 Linux 环境安装 Blender。", "Install Blender in this Linux environment first."))
                            .foregroundStyle(.secondary)
                    }
                    if inventory?.blender.launcherInstalled == false { updateComponentNotice }
                } header: { Text("Blender") }

                Section {
                    Button {
                        if let id = display.environmentID {
                            Task { await owner.installTools(environmentID: id) }
                        }
                    } label: {
                        Label(t("安装加速工具", "Install Acceleration Tools"), systemImage: "shippingbox.and.arrow.backward")
                    }
                    .disabled(owner.isBusy || owner.installing || display.environmentID == nil)
                    if owner.installing { ProgressView(t("正在安装…", "Installing…")) }
                } header: { Text(t("组件", "Components")) }
                  footer: { Text(t("可离线安装到当前 Linux 环境。", "Install offline in the current Linux environment.")) }

                if owner.launching || (owner.isBusy && !owner.installing) {
                    Section { ProgressView(t("正在处理…", "Working…")) }
                }
                if let message = owner.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                Section {
                    DisclosureGroup(t("详情", "Details")) {
                        if !owner.details.isEmpty {
                            Text(owner.details).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if !owner.blenderOutput.isEmpty {
                            Text(owner.blenderOutput).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text("floe-accel --help\nfloe-accel graphics info\nfloe-accel graphics egl\nfloe-accel video list --json\nfloe-accel compute opencl status\nfloe-accel compute opencl probe --device any --size 1024\nfloe-accel compute run -- python3 script.py\nfloe-accel blender --help")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(t("图形与加速", "Graphics and acceleration"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("完成", "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let id = display.environmentID { Task { await owner.refresh(environmentID: id) } }
                    } label: { Label(t("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(owner.isBusy)
                }
            }
        }
        .accessibilityIdentifier("terminal.acceleration.sheet")
        .task(id: display.environmentID) {
            if let id = display.environmentID { await owner.refresh(environmentID: id) }
        }
        .onDisappear { owner.cancelQuery() }
        .sheet(item: $screen) { presentation in LocalLinuxDisplayView(owner: presentation.owner) }
    }

    private var updateComponentNotice: some View {
        Text(t("请更新 Linux 组件。", "Update the Linux component."))
            .foregroundStyle(.secondary)
    }
    private func run(_ diagnostic: LocalLinuxAccelerationOwner.Diagnostic) {
        if let id = display.environmentID { Task { await owner.diagnose(diagnostic, environmentID: id) } }
    }
    private func mode(_ value: String) {
        if let id = display.environmentID { Task { await owner.setComputeMode(value, environmentID: id) } }
    }
    private func t(_ chinese: String, _ english: String) -> String { IDELanguageRunText.t(chinese, english) }
}
#endif

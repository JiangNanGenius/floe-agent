# Simulation qualification host

这是 FloeSimulationKit 的独立原生 iPad/iPhone 宿主，用于检查模块集成。它不修改 Floe App 的导航、版本、签名和分发状态。

宿主加载明确的资格样例，并能保存和重开本宿主的研究。物理、静力、导热、Netgen 网格、MFEM 静电与压力声学由同一套模块执行。线框只用于该宿主显示；实际 App 的 CAD Metal 显示接合使用独立入口和检查，不由本宿主代验。

先按[模块说明](../../Modules/FloeSimulationKit/README.md)构建三个原生组件并执行只读摘要检查，再生成工程：

```sh
xcodegen generate --spec FloeAgent/Qualification/Simulation/project.yml --project FloeAgent/Qualification/Simulation
```

代码编译可使用 `generic/platform=iOS Simulator`，不启动设备。共享主机上通过现有原生构建锁运行，并使用单独的内置 SSD DerivedData 目录、6 个编译任务。

需要实际交互检查时，仅使用 `FloeAgent/scripts/select_test_simulator.py --canonical` 返回的复用 iPad，并持有其 `--with-lock` 锁。保留设备应用与数据，不创建、克隆、抹除模拟器，不使用用户物理 iPhone。源码编译、宿主交互和完整 App 验收分别说明。

界面入口包括研究列表、运行/停止、结果场/探针、时间轴、已保存结果、CSV 导出，以及动画图层、骨骼/IK、物理混合、运动烘焙。高级求解器尚未连接时显示真实状态。

`SimulationNativeCodeChecks` 是独立组件测试方案，使用空 XCTest 宿主，原生库只在测试包链接一次；`Fixtures` 的 OCCT 长方体生成器不进入生产 App。两个定向用例分别检查真实 B-rep → 带标签网格 → 静电 → 保存/CSV，以及通过实际 `FloeCADDocument` 创建几何后保存、重开、移动的源模型与边界身份。后者复用 CAD 的持久化 B-rep 档案，覆盖单实体和多零件曲面路径，并确认真实几何修改仍改变身份。这些检查只证明对应原生调用和代码链路，不能替代主 App 界面或真机验收。运行该方案必须使用上述 canonical 设备与锁，并在不再需要时关闭本任务启动的设备。

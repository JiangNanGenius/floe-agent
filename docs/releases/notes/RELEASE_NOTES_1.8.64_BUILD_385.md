# Floe Agent 1.8.64（385）

## 简体中文

- Linux 虚拟机在持续读写磁盘时也能推进 CPU 任务，减少多个 vCPU 同时完成工作时的重复唤醒。
- Linux 图形更新透传 Apple GPU 型号和硬件类型。Vulkan 渲染和 BLAS 按驱动与设备能力选择加速路径。
- 建筑平面支持直接拖画墙线、端点吸附和平移缩放。同一工程可切换平面与三维，也可另存为独立副本。

## English

- Linux keeps scheduling CPU work during sustained disk activity and coalesces redundant wakeups when several vCPUs complete work together.
- The Linux graphics update reports the Apple GPU model and hardware device type. Vulkan and BLAS select acceleration using driver and device capabilities.
- Draw walls by dragging, snap endpoints, and pan or zoom the floor plan. Switch between plan and 3D in one project or use Save As to create a separate copy.

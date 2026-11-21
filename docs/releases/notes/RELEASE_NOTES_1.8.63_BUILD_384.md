# Floe Agent 1.8.63（384）

## 简体中文

- Linux 虚拟机在持续读写磁盘时也能及时执行其他工作。已用并发磁盘读取、共享文件访问和 CPU 运算覆盖这一场景。
- 分批处理虚拟盘读写，并缩减 ARM64 取指和内存写入中的重复工作。
- 建筑平面支持直接拖画墙线、端点吸附和平移缩放。同一工程可切换平面与三维，另存为可创建独立副本。

## English

- The Linux VM can continue scheduling guest CPU work during sustained virtual disk activity. Coverage includes concurrent disk reads, shared file access, and CPU work.
- Virtual disk transfers are batched, and the ARM64 interpreter does less repeated work when fetching instructions and writing memory.
- Draw walls by dragging, snap endpoints, and pan or zoom the floor plan. Switch between plan and 3D in one project and use Save As to create a separate copy.

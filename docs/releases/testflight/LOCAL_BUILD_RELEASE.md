# Local build and TestFlight delivery

Use this path for an explicitly authorized expedited release. Keep the exact-source local verification results and list the independent checks omitted for that release. This path does not claim a full CI pass.

1. Inspect the installed development Xcode and SDK; use `DEVELOPER_DIR` per command. Build the full device App locally with six compiler jobs and task-specific internal-SSD DerivedData.
2. Finish relevant tests, freeze and commit App source, and perform the final incremental device build on that exact commit. Check App and extension versions.
3. Run `FloeAgent/scripts/package_local_device.py --products <Release-iphoneos> --source <full SHA> --qualification <actual checks and omissions>`. It saves the raw device App first, normalizes the distribution bundle, verifies matching symbols and writes a hashed transport archive under `Local/Artifacts/build<number>`.
4. Create an immutable version tag at that SHA. Upload `local-device.zip` to a draft transport release. Dispatch `release-unsigned-ipa.yml` with that tag and `local_artifact_sha256`, with `publish`, `lean_release`, and `direct_testflight` all false. The reusable workflow verifies provenance, signs and uploads the supplied App without recompiling it.
5. Independently read Apple status. An upload receipt alone is insufficient: require `VALID`, unexpired, the intended existing group and beta availability. External review submission and approval are separate states.
6. Save the final signed IPA, symbols, hashes and distribution evidence before removing transport staging and completed task build caches. Never delete source, credentials, user Simulator data, unrelated work or the necessary rollback artifact.

Public TestFlight, GitHub prerelease and Feather require their own authorized distribution steps; do not publish the private transport archive or signing materials. Use the verified unsigned developer IPA for Feather.

## 中文

经用户授权的快速发布采用“本地完整设备构建与相关测试 → 固定源码 → 保存可恢复产物 → 云端仅签名上传 → Apple 状态与既有测试组核验”。不重复编译已经验证的同源产物。记录实际检查与省略项目，不把本地通过写成完整 CI 通过。

公测送审与审核批准分开记录。保留签名包、符号、哈希、日志及必要回滚版本后，清理本任务的一次性构建缓存和中转文件；不删除模拟器数据及无关任务文件。

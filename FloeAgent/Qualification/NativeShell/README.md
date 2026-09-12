# Native shell qualification

This minimal iOS App runs the production Objective-C bridge, pinned ios_system
frameworks and Floe's source-built dash. The Swift tool adapter and full-App
integration are separately covered by LocalShellRuntimeTests in cloud CI.

Build dash with `scripts/build_dash_ios.sh`, generate this project with XcodeGen,
and build/install FloeShellSmoke on a dedicated iOS Simulator. Read Documents
using `xcrun simctl get_app_container <simulator> dev.floe.shell-smoke data`.

`shell-results.json` must contain nine records in order [2,3,1,0,4,5,6,7,8]:
scoped env, no env leak, stdin/output cap with exit 7, loop/pipeline, three-stage
pipeline, unknown command (127), cancellation (status 3/exit 130), subsequent
execution, and timeout (status 2/exit 130). Every `workerStopped` must be true.
`shell-interactive-results.json` must report opened=true, stdout containing
received:interactive, workerStopped=true and passed=true.

Before cooperative cancellation, the infinite-loop case did not finish the
Swift caller while dash kept running. Samples and source inspection identified
unsafe caller-thread invocation of the global SIGINT handler by ios_kill.
No strong isolation or cancellation of every blocking native command is claimed.

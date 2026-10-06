# Durable execution checkpoints

Run `bash FloeAgent/Qualification/ExecutionDiagnostics/run.sh` from the repository.
This compiles the actual recorder with Swift 6 and verifies process-reopen retention,
concurrent bounded writes, the restricted schema, and recovery from malformed data.
The temporary executable and journal are removed after the run.

The App starts the recorder at launch and exports `execution_trace` independently
of MetricKit and the live log buffer. It retains at most 64 checkpoints for each
of the previous and current processes. Shell execution records negotiation, send,
reply wait, interruption and completion/failure. Service start/stop record control
exchange boundaries. Routine liveness polling and output chunks are not persisted.
Commands, arguments, paths and output are intentionally absent.

An unfinished checkpoint identifies the last observed boundary, not the cause of
termination. Atomic writes can still be lost if the operating system or storage
fails; persistence failures are exposed in the report. This focused test does not
verify the full App, feedback transport, or physical-device crash behavior.

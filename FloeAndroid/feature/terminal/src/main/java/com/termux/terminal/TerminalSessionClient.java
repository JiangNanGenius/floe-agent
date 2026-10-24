// PATCHED COPY of com.termux.terminal.TerminalSessionClient from
// termux/termux-app v0.118.3 (commit 5b657c6adf4304e5198951ce815fe0205dcac29c),
// Apache License 2.0 per the repository LICENSE.md exception for the
// terminal-emulator library (derived from jackpal/Android-Terminal-Emulator,
// Apache 2.0). See licenses/ and PROVENANCE-TERMINUX.md for the exact
// upstream hashes and the one patch applied:
//
//   PATCH-1 (process-ownership exclusion, job-dda32d23d55e4460): the seven
//   callback methods whose signature names the {@code TerminalSession}
//   class are REMOVED, because Floe deliberately does NOT vendor
//   TerminalSession (the Termux process/exec owner: JNI, TermExtraData,
//   shell lifecycle). Floe feeds the emulator over its own external PTY
//   sessions (the ORIGINAL resolved Linux engine + ShellSessionCenter),
//   so adopting TerminalSession would introduce a competing process
//   lifecycle that the G04 architecture forbids. Every remaining member is
//   byte-equal to upstream; {@code TerminalEmulator}/{@code Logger} call
//   exactly these members (getTerminalCursorStyle,
//   onTerminalCursorStateChange, log*) and nothing else.
//
// Upstream SHA-256 of the replaced file:
// 853c3816ea1fc827895cea8191628482e1845e888a33d6c7da7e7ddac63af1b9
package com.termux.terminal;

/**
 * The interface for communication between {@link TerminalEmulator} and its client. It is used to
 * send callbacks to the client when the terminal changes or for sending other back data to the
 * client like logs.
 */
public interface TerminalSessionClient {

    void onTerminalCursorStateChange(boolean state);

    Integer getTerminalCursorStyle();

    void logError(String tag, String message);

    void logWarn(String tag, String message);

    void logInfo(String tag, String message);

    void logDebug(String tag, String message);

    void logVerbose(String tag, String message);

    void logStackTraceWithMessage(String tag, String message, Exception e);

    void logStackTrace(String tag, Exception e);

}

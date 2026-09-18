// Desktop test stub for the pinned ios_system engine headers.
//
// FloeAgent/scripts/tests/feedback_shell_bridge_host.mm compiles the real
// FloeShellBridge.mm against this header and links the stub implementations
// below. It is a host-side harness for gate/readiness/descriptor ownership
// behavior, NOT an iOS or engine qualification: the stub engine is scripted
// (see the host), not ios_system.
#ifndef FLOE_HARNESS_IOS_SYSTEM_H
#define FLOE_HARNESS_IOS_SYSTEM_H

#include <stdbool.h>
#include <stdio.h>
#include <sys/types.h>
#include <pthread.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#else
typedef void NSString;
typedef void NSURL;
typedef void NSArray;
#endif

void initializeEnvironment(void);
extern bool joinMainThread;
void ios_setenv(const char *name, const char *value, int overwrite);
NSArray<NSString *> *environmentAsArray(void);
bool ios_setMiniRoot(NSString *root);
void ios_setDirectoryURL(NSURL *url);
void ios_setStreams(FILE *input, FILE *output, FILE *error);
void ios_switchSession(const char *session);
void ios_setContext(const char *session);
pid_t ios_fork(void);
void ios_releaseThreadId(pid_t processID);
void ios_storeThreadId(pthread_t thread);
int ios_system(const char *command);
int ios_getCommandStatus(void);
void ios_closeSession(const char *session);
void ios_setWindowSize(int columns, int rows, const char *session);
NSString *ios_getLogicalPWD(void *context);
void replaceCommand(NSString *name, NSString *command, bool freeExisting);

extern FILE *thread_stdin;
extern FILE *thread_stdout;
extern FILE *thread_stderr;
extern void *thread_context;

#endif

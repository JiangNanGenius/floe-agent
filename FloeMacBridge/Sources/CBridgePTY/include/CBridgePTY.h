#pragma once
#include <sys/types.h>
pid_t floe_spawn_pty(int *master, const char *cwd, char *const argv[], char *const envp[], unsigned short columns, unsigned short rows);
int floe_resize_pty(int master, unsigned short columns, unsigned short rows);

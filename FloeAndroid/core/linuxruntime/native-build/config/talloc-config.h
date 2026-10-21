/* Hand-written config.h for cross-building talloc 2.4.2 with zig cc
 * targeting aarch64-linux-musl (musl 1.2.5 as bundled with zig 0.14.1).
 * Feature set: full modern POSIX/Linux userland; excluded are glibc-only
 * extensions musl lacks (closefrom, getpeereid, getprogname,
 * get_current_dir_name, memset_s, setproctitle, BSD headers, crypt.h).
 * Static link: dlopen family intentionally left undefined (musl static
 * dlopen is a stub; talloc does not need it).
 */
#ifndef TALLOC_CROSS_CONFIG_H
#define TALLOC_CROSS_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_SYSMACROS_H 1
#define HAVE_SYS_AUXV_H 1
#define HAVE_MALLOC_H 1
#define HAVE_BOOL 1
#define HAVE_INTPTR_T 1
#define HAVE_UINTPTR_T 1
#define HAVE_PTRDIFF_T 1

#define HAVE_ASPRINTF 1
#define HAVE_VASPRINTF 1
#define HAVE_DPRINTF 1
#define HAVE_VDPRINTF 1
#define HAVE_C99_VSNPRINTF 1
#define HAVE_VSNPRINTF 1
#define HAVE_SNPRINTF 1
#define HAVE_STRERROR 1
#define HAVE_STRERROR_R 1
#define HAVE_STRDUP 1
#define HAVE_STRNDUP 1
#define HAVE_STRNLEN 1
#define HAVE_STRSEP 1
#define HAVE_STRCASESTR 1
#define HAVE_STRTOK_R 1
#define HAVE_STRTOLL 1
#define HAVE_STRTOULL 1
#define HAVE_STRLCPY 1
#define HAVE_STRLCAT 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMSET 1
#define HAVE_BZERO 1
#define HAVE_MEMALIGN 1
#define HAVE_MEMMEM 1
#define HAVE_MKDTEMP 1
#define HAVE_PREAD 1
#define HAVE_PWRITE 1
#define HAVE_POLL 1
#define HAVE_USLEEP 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_MKTIME 1
#define HAVE_TIMEGM 1
#define HAVE_WORKING_STRPTIME 1
#define HAVE_UTIME 1
#define HAVE_UTIMES 1
#define HAVE_CHOWN 1
#define HAVE_LCHOWN 1
#define HAVE_CHROOT 1
#define HAVE_INITGROUPS 1
#define HAVE_DUP2 1
#define HAVE_FDATASYNC 1
#define HAVE_FTRUNCATE 1
#define HAVE_LINK 1
#define HAVE_SYMLINK 1
#define HAVE_READLINK 1
#define HAVE_REALPATH 1
#define HAVE_SOCKETPAIR 1
#define HAVE_CONNECT 1
#define HAVE_INET_ATON 1
#define HAVE_INET_NTOA 1
#define HAVE_INET_NTOP 1
#define HAVE_INET_PTON 1
#define HAVE_GETHOSTBYNAME 1
#define HAVE_GETIFADDRS 1
#define HAVE_FREEIFADDRS 1
#define HAVE_GETAUXVAL 1
#define HAVE_SETENV 1
#define HAVE_UNSETENV 1
#define HAVE_SYSLOG 1
#define HAVE_VSYSLOG 1
#define HAVE_PTHREAD 1
#define HAVE___THREAD 1
#define HAVE_VA_COPY 1
#define HAVE___VA_COPY 1
#define HAVE_FUNCTION_MACRO 1
#define HAVE_VISIBILITY_ATTR 1
#define HAVE_CONSTRUCTOR_ATTRIBUTE 1
#define HAVE_FALLTHROUGH_ATTRIBUTE 1
#define HAVE_ERRNO_DECL 1
#define HAVE_DECL_EWOULDBLOCK 1
#define HAVE_STRUCT_TIMESPEC 1
#define HAVE_COPY_FILE_RANGE 1
#define HAVE_DLFCN_H 1
#define HAVE_DLOPEN 1
#define HAVE_DLSYM 1
#define HAVE_DLCLOSE 1
#define HAVE_DLERROR 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_SYSCALL_H 1
#define LIBREPLACE_NETWORK_CHECKS 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETDB_H 1
#define HAVE_NET_IF_H 1
#define HAVE_UNIXSOCKET 1
#define HAVE_SYS_UN_H 1
#define HAVE_SOCKLEN_T 1
#define HAVE_SA_FAMILY_T 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_IFADDRS 1
#define HAVE_STRUCT_ADDRINFO 1
#define HAVE_IFADDRS_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_UIO_H 1
#define STRERROR_R_XSI_NOT_GNU 1

#endif /* TALLOC_CROSS_CONFIG_H */

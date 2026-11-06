/* config.h.  Generated from config.h.in by configure.  */
/* config.h.in.  Generated from configure.ac by autoheader.  */


#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H


/* debug define */
/* #undef ABORTFP */

/* Define if building universal (internal helper macro) */
/* #undef AC_APPLE_UNIVERSAL_BUILD */

/* Define to 1 if using 'alloca.c'. */
/* #undef C_ALLOCA */

/* alot of debug output */
/* #undef DEBUG */

/* allow to compute a more accurate replaygain value */
/* #undef DECODE_ON_THE_FLY */

/* double is faster than float on Alpha */
/* #undef FLOAT */

/* Define to 1 if you have 'alloca', as a function or macro. */
#define HAVE_ALLOCA 1

/* Define to 1 if <alloca.h> works. */
#define HAVE_ALLOCA_H 1

/* Define to 1 if you have the <dlfcn.h> header file. */
#define HAVE_DLFCN_H 1

/* we link against libefence */
/* #undef HAVE_EFENCE */

/* Define to 1 if you have the <errno.h> header file. */
#define HAVE_ERRNO_H 1

/* Define to 1 if you have the <fcntl.h> header file. */
#define HAVE_FCNTL_H 1

/* Define to 1 if you have the `gettimeofday' function. */
#define HAVE_GETTIMEOFDAY 1

/* Define if you have the iconv() function and it works. */
#define HAVE_ICONV 1

/* add ieee754_float32_t type */
/* #undef HAVE_IEEE754_FLOAT32_T */
#ifndef HAVE_IEEE754_FLOAT32_T
	typedef float ieee754_float32_t;
#endif

/* add ieee754_float64_t type */
/* #undef HAVE_IEEE754_FLOAT64_T */
#ifndef HAVE_IEEE754_FLOAT64_T
	typedef double ieee754_float64_t;
#endif

/* system has 80 bit floats */
/* #undef HAVE_IEEE854_FLOAT80 */

/* add ieee854_float80_t type */
/* #undef HAVE_IEEE854_FLOAT80_T */
#ifndef HAVE_IEEE854_FLOAT80_T
	typedef long double ieee854_float80_t;
#endif

/* add int16_t type */
#define HAVE_INT16_T 1
#ifndef HAVE_INT16_T
	typedef short int16_t;
#endif

/* add int32_t type */
#define HAVE_INT32_T 1
#ifndef HAVE_INT32_T
#define A_INT32_T int
	typedef A_INT32_T int32_t;
#endif

/* add int64_t type */
#define HAVE_INT64_T 1
#ifndef HAVE_INT64_T
#define A_INT64_T long
	typedef A_INT64_T int64_t;
#endif

/* add int8_t type */
#define HAVE_INT8_T 1
#ifndef HAVE_INT8_T
	typedef char int8_t;
#endif

/* Define to 1 if you have the <inttypes.h> header file. */
#define HAVE_INTTYPES_H 1

/* Define to 1 if you have the <langinfo.h> header file. */
#define HAVE_LANGINFO_H 1

/* Define to 1 if you have the <limits.h> header file. */
#define HAVE_LIMITS_H 1

/* Define to 1 if you have the <linux/soundcard.h> header file. */
/* #undef HAVE_LINUX_SOUNDCARD_H */

/* Define to 1 if the type `long double' works and has more range or precision
   than `double'. */
/* #undef HAVE_LONG_DOUBLE */

/* Define to 1 if the type `long double' works and has more range or precision
   than `double'. */
/* #undef HAVE_LONG_DOUBLE_WIDER */

/* Define to 1 if you have the <minix/config.h> header file. */
/* #undef HAVE_MINIX_CONFIG_H */

/* set to 1 if you have libmpg123 */
/* #undef HAVE_MPG123 */

/* have nasm */
/* #undef HAVE_NASM */

/* Define to 1 if you have the <ncurses/termcap.h> header file. */
/* #undef HAVE_NCURSES_TERMCAP_H */

/* Define to 1 if you have the `nl_langinfo' function. */
#define HAVE_NL_LANGINFO 1

/* Define to 1 if you have the `socket' function. */
#define HAVE_SOCKET 1

/* Define to 1 if you have the <stdint.h> header file. */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdio.h> header file. */
#define HAVE_STDIO_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

/* Define to 1 if you have the <strings.h> header file. */
#define HAVE_STRINGS_H 1

/* Define to 1 if you have the <string.h> header file. */
#define HAVE_STRING_H 1

/* Define to 1 if you have the `strtol' function. */
#define HAVE_STRTOL 1

/* Define to 1 if you have the <sys/soundcard.h> header file. */
/* #undef HAVE_SYS_SOUNDCARD_H */

/* Define to 1 if you have the <sys/stat.h> header file. */
#define HAVE_SYS_STAT_H 1

/* Define to 1 if you have the <sys/time.h> header file. */
#define HAVE_SYS_TIME_H 1

/* Define to 1 if you have the <sys/types.h> header file. */
#define HAVE_SYS_TYPES_H 1

/* have termcap */
#define HAVE_TERMCAP 1

/* Define to 1 if you have the <termcap.h> header file. */
#define HAVE_TERMCAP_H 1

/* add uint16_t type */
#define HAVE_UINT16_T 1
#ifndef HAVE_UINT16_T
	typedef unsigned short uint16_t;
#endif

/* add uint32_t type */
#define HAVE_UINT32_T 1
#ifndef HAVE_UINT32_T
#define A_UINT32_T unsigned int
	typedef A_UINT32_T uint32_t;
#endif

/* add uint64_t type */
#define HAVE_UINT64_T 1
#ifndef HAVE_UINT64_T
#define A_UINT64_T unsigned long
	typedef A_UINT64_T uint64_t;
#endif

/* add uint8_t type */
#define HAVE_UINT8_T 1
#ifndef HAVE_UINT8_T
	typedef unsigned char uint8_t;
#endif

/* Define to 1 if you have the <unistd.h> header file. */
#define HAVE_UNISTD_H 1

/* Define to 1 if you have the <wchar.h> header file. */
#define HAVE_WCHAR_H 1

/* Define if SSE intrinsics work. */
/* #undef HAVE_XMMINTRIN_H */

/* Define as const if the declaration of iconv() needs const. */
#define ICONV_CONST 

/* check if system supports IPV6 */
/* #undef IPV6 */

/* requested by Frank, seems to be temporary needed for a smooth transition */
#define LAME_LIBRARY_BUILD 1

/* set to 1 if you have libsndfile */
/* #undef LIBSNDFILE */

/* Define to the sub-directory where libtool stores uninstalled libraries. */
#define LT_OBJDIR ".libs/"

/* use MMX version of choose_table */
/* #undef MMX_choose_table */

/* build without hooks for analyzer */
/* #undef NOANALYSIS */

/* Name of package */
#define PACKAGE "lame"

/* Define to the address where bug reports for this package should be sent. */
#define PACKAGE_BUGREPORT "lame-dev@lists.sf.net"

/* Define to the full name of this package. */
#define PACKAGE_NAME "lame"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "lame 3.101"

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME "lame"

/* Define to the home page for this package. */
#define PACKAGE_URL ""

/* Define to the version of this package. */
#define PACKAGE_VERSION "3.101"

/* The size of `double', as computed by sizeof. */
#define SIZEOF_DOUBLE 8

/* The size of `float', as computed by sizeof. */
#define SIZEOF_FLOAT 4

/* The size of `int', as computed by sizeof. */
#define SIZEOF_INT 4

/* The size of `long', as computed by sizeof. */
#define SIZEOF_LONG 8

/* The size of `long double', as computed by sizeof. */
/* #undef SIZEOF_LONG_DOUBLE */

/* The size of `long long', as computed by sizeof. */
#define SIZEOF_LONG_LONG 8

/* The size of `short', as computed by sizeof. */
#define SIZEOF_SHORT 2

/* The size of `unsigned int', as computed by sizeof. */
#define SIZEOF_UNSIGNED_INT 4

/* The size of `unsigned long', as computed by sizeof. */
#define SIZEOF_UNSIGNED_LONG 8

/* The size of `unsigned long long', as computed by sizeof. */
#define SIZEOF_UNSIGNED_LONG_LONG 8

/* The size of `unsigned short', as computed by sizeof. */
#define SIZEOF_UNSIGNED_SHORT 2

/* If using the C implementation of alloca, define if you know the
   direction of stack growth for your system; otherwise it will be
   automatically deduced at runtime.
	STACK_DIRECTION > 0 => grows toward higher addresses
	STACK_DIRECTION < 0 => grows toward lower addresses
	STACK_DIRECTION = 0 => direction of growth unknown */
/* #undef STACK_DIRECTION */

/* Define to 1 if all of the C90 standard headers exist (not just the ones
   required in a freestanding environment). This macro is provided for
   backward compatibility; new code need not use it. */
#define STDC_HEADERS 1

/* IEEE754 compatible machine */
#define TAKEHIRO_IEEE754_HACK 0

/* Define to 1 if you can safely include both <sys/time.h> and <time.h>. This
   macro is obsolete. */
#define TIME_WITH_SYS_TIME 1

/* faster log implementation with less but enough precission */
/* #undef USE_FAST_LOG */

/* Enable extensions on AIX 3, Interix.  */
#ifndef _ALL_SOURCE
# define _ALL_SOURCE 1
#endif
/* Enable general extensions on macOS.  */
#ifndef _DARWIN_C_SOURCE
# define _DARWIN_C_SOURCE 1
#endif
/* Enable general extensions on Solaris.  */
#ifndef __EXTENSIONS__
# define __EXTENSIONS__ 1
#endif
/* Enable GNU extensions on systems that have them.  */
#ifndef _GNU_SOURCE
# define _GNU_SOURCE 1
#endif
/* Enable X/Open compliant socket functions that do not require linking
   with -lxnet on HP-UX 11.11.  */
#ifndef _HPUX_ALT_XOPEN_SOCKET_API
# define _HPUX_ALT_XOPEN_SOCKET_API 1
#endif
/* Identify the host operating system as Minix.
   This macro does not affect the system headers' behavior.
   A future release of Autoconf may stop defining this macro.  */
#ifndef _MINIX
/* # undef _MINIX */
#endif
/* Enable general extensions on NetBSD.
   Enable NetBSD compatibility extensions on Minix.  */
#ifndef _NETBSD_SOURCE
# define _NETBSD_SOURCE 1
#endif
/* Enable OpenBSD compatibility extensions on NetBSD.
   Oddly enough, this does nothing on OpenBSD.  */
#ifndef _OPENBSD_SOURCE
# define _OPENBSD_SOURCE 1
#endif
/* Define to 1 if needed for POSIX-compatible behavior.  */
#ifndef _POSIX_SOURCE
/* # undef _POSIX_SOURCE */
#endif
/* Define to 2 if needed for POSIX-compatible behavior.  */
#ifndef _POSIX_1_SOURCE
/* # undef _POSIX_1_SOURCE */
#endif
/* Enable POSIX-compatible threading on Solaris.  */
#ifndef _POSIX_PTHREAD_SEMANTICS
# define _POSIX_PTHREAD_SEMANTICS 1
#endif
/* Enable extensions specified by ISO/IEC TS 18661-5:2014.  */
#ifndef __STDC_WANT_IEC_60559_ATTRIBS_EXT__
# define __STDC_WANT_IEC_60559_ATTRIBS_EXT__ 1
#endif
/* Enable extensions specified by ISO/IEC TS 18661-1:2014.  */
#ifndef __STDC_WANT_IEC_60559_BFP_EXT__
# define __STDC_WANT_IEC_60559_BFP_EXT__ 1
#endif
/* Enable extensions specified by ISO/IEC TS 18661-2:2015.  */
#ifndef __STDC_WANT_IEC_60559_DFP_EXT__
# define __STDC_WANT_IEC_60559_DFP_EXT__ 1
#endif
/* Enable extensions specified by ISO/IEC TS 18661-4:2015.  */
#ifndef __STDC_WANT_IEC_60559_FUNCS_EXT__
# define __STDC_WANT_IEC_60559_FUNCS_EXT__ 1
#endif
/* Enable extensions specified by ISO/IEC TS 18661-3:2015.  */
#ifndef __STDC_WANT_IEC_60559_TYPES_EXT__
# define __STDC_WANT_IEC_60559_TYPES_EXT__ 1
#endif
/* Enable extensions specified by ISO/IEC TR 24731-2:2010.  */
#ifndef __STDC_WANT_LIB_EXT2__
# define __STDC_WANT_LIB_EXT2__ 1
#endif
/* Enable extensions specified by ISO/IEC 24747:2009.  */
#ifndef __STDC_WANT_MATH_SPEC_FUNCS__
# define __STDC_WANT_MATH_SPEC_FUNCS__ 1
#endif
/* Enable extensions on HP NonStop.  */
#ifndef _TANDEM_SOURCE
# define _TANDEM_SOURCE 1
#endif
/* Enable X/Open extensions.  Define to 500 only if necessary
   to make mbstate_t available.  */
#ifndef _XOPEN_SOURCE
/* # undef _XOPEN_SOURCE */
#endif


/* Version number of package */
#define VERSION "3.101"

/* Define if using the dmalloc debugging malloc package */
/* #undef WITH_DMALLOC */

/* Define WORDS_BIGENDIAN to 1 if your processor stores words with the most
   significant byte first (like Motorola and SPARC, unlike Intel). */
#if defined AC_APPLE_UNIVERSAL_BUILD
# if defined __BIG_ENDIAN__
#  define WORDS_BIGENDIAN 1
# endif
#else
# ifndef WORDS_BIGENDIAN
/* #  undef WORDS_BIGENDIAN */
# endif
#endif

/* Number of bits in a file offset, on hosts where this is settable. */
/* #undef _FILE_OFFSET_BITS */

/* Define for large files, on AIX-style hosts. */
/* #undef _LARGE_FILES */

/* we're on DEC Alpha */
/* #undef __DECALPHA__ */

/* work around a glibc bug */
/* #undef __NO_MATH_INLINES */

/* Define to empty if `const' does not conform to ANSI C. */
/* #undef const */

/* Define to `__inline__' or `__inline' if that's what the C compiler
   calls it, or to nothing if 'inline' is not supported under any name.  */
#ifndef __cplusplus
/* #undef inline */
#endif

/* Define to `unsigned int' if <sys/types.h> does not define. */
/* #undef size_t */

#endif /* LAME_CONFIG_H */

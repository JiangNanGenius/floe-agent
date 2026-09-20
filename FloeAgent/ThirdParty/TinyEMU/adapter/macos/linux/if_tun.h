/* Minimal stub of <linux/if_tun.h> for macOS local smoke builds of
 * TinyEMU 2019-12-21 (build-flag-only via -I; pristine sources untouched).
 * macOS has no /dev/net/tun: tap_open() fails cleanly at runtime, which is
 * acceptable because the qualification path uses slirp user networking.
 */
#ifndef TINYEMU_MACOS_LINUX_IF_TUN_H
#define TINYEMU_MACOS_LINUX_IF_TUN_H
#define IFF_TAP     0x0002
#define IFF_NO_PI   0x1000
#define TUNSETIFF   0x400454ca
#endif

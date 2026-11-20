/*
 *  shim.h  --  system zlib, for SwiftPM builds.
 *
 *  Mirrors Sources/Support/smolcord-Bridging-Header.h, which serves the Xcode
 *  build. Both exist because inflateInit2 is a macro that takes an address,
 *  and such macros do not import into Swift cleanly.
 *
 *  This copy lives outside Sources/ on purpose: the Xcode target globs
 *  Sources/, and a stray module.modulemap there confuses it.
 */

#ifndef SMOLCORD_CZLIB_SHIM_H
#define SMOLCORD_CZLIB_SHIM_H

#include <zlib.h>
#include <string.h>

/// Initialise a stream for inflating a zlib-wrapped stream.
///
/// windowBits 15 means "expect a zlib header". Discord's `zlib-stream`
/// transport opens with one, then never closes the stream: every gateway
/// message is terminated by a Z_SYNC_FLUSH marker instead.
static inline int smol_inflate_init(z_streamp strm) {
    memset(strm, 0, sizeof(z_stream));
    return inflateInit2_(strm, 15, ZLIB_VERSION, (int)sizeof(z_stream));
}

static inline const char *smol_zlib_version(void) {
    return zlibVersion();
}

#endif /* SMOLCORD_CZLIB_SHIM_H */

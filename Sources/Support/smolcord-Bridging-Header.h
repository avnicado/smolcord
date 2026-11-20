//
//  smolcord-Bridging-Header.h
//
//  Exposes system zlib to Swift.
//
//  iOS ships libz (link libz.tbd) and zlib.h is in the SDK, so streaming
//  inflate needs no third-party code. We cannot ship zstd without vendoring a
//  C library, and zlib-stream is what we use anyway.
//
//  inflateInit2 is a macro, and macros that take addresses do not import into
//  Swift cleanly. The shims below wrap it so the Swift side sees plain
//  functions.
//

#ifndef smolcord_Bridging_Header_h
#define smolcord_Bridging_Header_h

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

/// zlib's own version string, for logging a mismatch.
static inline const char *smol_zlib_version(void) {
    return zlibVersion();
}

#endif /* smolcord_Bridging_Header_h */

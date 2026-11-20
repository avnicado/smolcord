//
//  GatewayOpcode.swift
//
//  Only the opcodes smolcord uses. Voice, streams and call opcodes are omitted
//  on purpose: unused protocol surface is unused attack surface, and every
//  event we can refuse to understand is an event we do not pay for.
//

import Foundation

public enum GatewayOpcode: Int {
    case dispatch            = 0
    case heartbeat           = 1
    case identify            = 2
    case presenceUpdate      = 3
    case resume              = 6
    case reconnect           = 7
    case requestMembers      = 8
    case invalidSession      = 9
    case hello               = 10
    case heartbeatACK        = 11

    /// Lever 2. Bulk guild subscribe/unsubscribe.
    ///
    /// Measured effect with every flag false: guild presence stops, guild
    /// messages do not. See Identify.unsubscribeAllGuildsPayload for the
    /// numbers. Still worth sending; it is not the firehose killer the
    /// community docs suggest.
    case bulkGuildSubscribe  = 37
}

/// Close codes that matter to the reconnect decision.
///
/// Discord's rule: codes 1000 and 1001 invalidate the session, so we never send
/// them when we intend to resume. Any other code, or a dropped TCP connection,
/// keeps the session alive for a few minutes.
public enum GatewayCloseCode {
    public static let unknownError          : UInt16 = 4000
    public static let unknownOpcode         : UInt16 = 4001
    public static let decodeError           : UInt16 = 4002
    public static let notAuthenticated      : UInt16 = 4003
    public static let authenticationFailed  : UInt16 = 4004
    public static let alreadyAuthenticated  : UInt16 = 4005
    public static let invalidSequence       : UInt16 = 4007
    public static let rateLimited           : UInt16 = 4008
    public static let sessionTimedOut       : UInt16 = 4009
    public static let invalidShard          : UInt16 = 4010
    public static let shardingRequired      : UInt16 = 4011
    public static let invalidAPIVersion     : UInt16 = 4012
    public static let invalidIntents        : UInt16 = 4013
    public static let disallowedIntents     : UInt16 = 4014

    /// Codes where reconnecting cannot help. Stop and tell the user.
    public static let fatal: Set<UInt16> = [
        authenticationFailed,
        invalidAPIVersion,
        invalidIntents,
        disallowedIntents,
        invalidShard,
        shardingRequired,
    ]

    /// Codes where the session is gone but a fresh IDENTIFY will work.
    public static let reidentify: Set<UInt16> = [
        invalidSequence,
        sessionTimedOut,
        notAuthenticated,
        alreadyAuthenticated,
    ]

    public static func describe(_ code: UInt16) -> String {
        switch code {
        case 0:                    return "no close frame"
        case 1000:                 return "normal closure"
        case 1001:                 return "going away"
        case unknownError:         return "unknown error"
        case unknownOpcode:        return "unknown opcode sent"
        case decodeError:          return "decode error"
        case notAuthenticated:     return "not authenticated"
        case authenticationFailed: return "authentication failed; the token is invalid"
        case alreadyAuthenticated: return "already authenticated"
        case invalidSequence:      return "invalid sequence; must re-identify"
        case rateLimited:          return "rate limited"
        case sessionTimedOut:      return "session timed out"
        case invalidAPIVersion:    return "invalid API version"
        case invalidIntents:       return "invalid intents"
        case disallowedIntents:    return "disallowed intents"
        default:                   return "close code \(code)"
        }
    }
}

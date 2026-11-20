//
//  GatewayCapabilities.swift
//
//  The `capabilities` bitfield sent in IDENTIFY. This is lever 1 of four in
//  the data budget: it shrinks READY at the server, before a byte is sent.
//
//  IMPORTANT -- do not hand-pick a minimal value.
//
//  A capabilities value no real client sends is an anti-spam fingerprint.
//  The reference implementation carries an explicit comment that it mirrors the
//  official client's value for exactly this reason. We match it. The official
//  value already includes every large win, so there is nothing to gain by
//  deviating and an account to lose.
//
//  Re-check `official` against Capabilities.default() in dolfies/discord.py-self
//  whenever the client version string in Identify.swift is bumped. Discord
//  changes this value over time.
//

import Foundation

public struct GatewayCapabilities: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Drop `notes` from READY.
    public static let lazyUserNotes = GatewayCapabilities(rawValue: 1 << 0)

    /// Disable implicit relationship presence updates. Fewer PRESENCE_UPDATE
    /// events for people we never message.
    public static let noAffineUserIDs = GatewayCapabilities(rawValue: 1 << 1)

    /// `read_state` becomes a versioned object, cacheable across identifies.
    public static let versionedReadStates = GatewayCapabilities(rawValue: 1 << 2)

    /// Same, for `user_guild_settings`.
    public static let versionedUserGuildSettings = GatewayCapabilities(rawValue: 1 << 3)

    /// Dehydrate READY: every user object is hoisted into one `users` array and
    /// referenced by id elsewhere. The single biggest reduction available.
    public static let dedupeUserObjects = GatewayCapabilities(rawValue: 1 << 4)

    /// Split READY and READY_SUPPLEMENTAL. Requires `dedupeUserObjects`, so the
    /// raw value carries both bits.
    public static let prioritizedReadyPayload = GatewayCapabilities(rawValue: 1 << 5 | 1 << 4)

    public static let multipleGuildExperimentPopulations = GatewayCapabilities(rawValue: 1 << 6)
    public static let nonChannelReadStates = GatewayCapabilities(rawValue: 1 << 7)
    public static let authTokenRefresh = GatewayCapabilities(rawValue: 1 << 8)

    /// Remove `user_settings` from READY and stop USER_SETTINGS_UPDATE.
    public static let userSettingsProto = GatewayCapabilities(rawValue: 1 << 9)

    /// Enables the `client_state.guild_versions` cache. Lever 3.
    public static let clientStateV2 = GatewayCapabilities(rawValue: 1 << 10)

    public static let passiveGuildUpdate = GatewayCapabilities(rawValue: 1 << 11)
    public static let autoCallConnect = GatewayCapabilities(rawValue: 1 << 12)
    public static let debounceMessageReactions = GatewayCapabilities(rawValue: 1 << 13)
    public static let passiveGuildUpdateV2 = GatewayCapabilities(rawValue: 1 << 14)

    /// The value the official client sends. Use this one.
    public static let official: GatewayCapabilities = [
        .lazyUserNotes,
        .versionedReadStates,
        .versionedUserGuildSettings,
        .dedupeUserObjects,
        .prioritizedReadyPayload,
        .multipleGuildExperimentPopulations,
        .nonChannelReadStates,
        .authTokenRefresh,
        .userSettingsProto,
        .clientStateV2,
        .autoCallConnect,
        .passiveGuildUpdateV2,
    ]

    /// Sanity check for the value above. 22525 at the time of writing.
    public static let expectedOfficialRawValue = 22525
}

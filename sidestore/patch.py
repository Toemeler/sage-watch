#!/usr/bin/env python3
"""Patch Andris73's watch-companion SideStore so it can install Sage (iPhone + watch,
with HealthKit) on a free Apple ID, and keep the watch app alive across refreshes.

Run from the SideStore checkout root, after the submodules are checked out:
    python3 patch.py

Every edit is an exact text replacement that must match exactly once, so a changed
upstream file stops the build here instead of producing a silently different app.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(".").resolve()
SIGN = ROOT / "Dependencies/SideSign/Sources"
MUX = ROOT / "Dependencies/minimuxer"
APP = ROOT / "SideStore"


def rep(path, old, new, count=1):
    p = pathlib.Path(path)
    text = p.read_text()
    found = text.count(old)
    if found != count:
        sys.exit(f"patch.py: expected {count} match(es) in {p}, found {found}:\n{old}")
    p.write_text(text.replace(old, new))
    print(f"patched {p.relative_to(ROOT)}")


def rep_ws(path, old, new):
    """Like rep(), but blank lines in `old` also match lines holding only spaces/tabs."""
    p = pathlib.Path(path)
    text = p.read_text()
    body, tail = (old[:-1], "\n") if old.endswith("\n") else (old, "")
    pattern = "\n".join("[ \t]*" if not line.strip() else re.escape(line) for line in body.split("\n")) + tail
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        sys.exit(f"patch.py: expected 1 match in {p}, found {len(matches)}:\n{old}")
    p.write_text(re.sub(pattern, lambda _m: new, text))
    print(f"patched {p.relative_to(ROOT)}")


def append(path, extra):
    p = pathlib.Path(path)
    p.write_text(p.read_text().rstrip("\n") + "\n" + extra)
    print(f"extended {p.relative_to(ROOT)}")


# ---------------------------------------------------------------------------
# 1. SideSign: ask Apple for HealthKit (App ID capability HK421J6T7P)
# ---------------------------------------------------------------------------
feature = SIGN / "Models/Feature.swift"
rep(feature,
    "        case .inAppPurchase:                   self = .inAppPurchase\n",
    "        case .inAppPurchase:                   self = .inAppPurchase\n"
    "        case .healthKit:                       self = .healthKit\n")
rep(feature,
    '    static let inAppPurchase: Feature                   = "inAppPurchase"\n',
    '    static let inAppPurchase: Feature                   = "inAppPurchase"\n'
    '    static let healthKit: Feature                       = "HK421J6T7P"\n')
rep(feature,
    "    static let freeFeatures: Set<Feature> = [\n        .appGroups,\n        .interAppAudio\n    ]",
    "    static let freeFeatures: Set<Feature> = [\n        .appGroups,\n        .interAppAudio,\n        .healthKit\n    ]")
rep(feature,
    "        .increasedDebuggingMemoryLimit\n    ]\n}",
    "        .increasedDebuggingMemoryLimit,\n        .healthKit\n    ]\n}")

rep(SIGN / "Models/Entitlement.swift",
    "    static let freeEntitlements: Set<Entitlement> = [\n        .appGroups,\n        .interAppAudio,\n",
    "    static let freeEntitlements: Set<Entitlement> = [\n        .appGroups,\n        .interAppAudio,\n        .healthKit,\n")

# ---------------------------------------------------------------------------
# 2. SideSign: Apple ID sign-in (HTTP 503 since 2026-11-20).
#    GSA's edge rejects "macOS;" as the OS name in X-MMe-Client-Info; akd/Xcode
#    send "Mac OS X;". Fix it where the header is written, whatever the source.
# ---------------------------------------------------------------------------
append(SIGN / "Models/AnisetteData.swift", '''
public extension AnisetteData {
    /// GSA answers HTTP 503 when X-MMe-Client-Info names the OS "macOS" (since 2026-11-20);
    /// Apple's own clients send "Mac OS X".
    static func gsaSafeClientInfo(_ value: String) -> String {
        value.replacingOccurrences(of: "<macOS;", with: "<Mac OS X;")
    }

    var gsaClientInfo: String {
        AnisetteData.gsaSafeClientInfo(clientInfo)
    }
}
''')
rep(SIGN / "Models/AnisetteData.swift",
    "            $0.clientInfo = self.clientInfo\n",
    "            $0.clientInfo = self.gsaClientInfo\n")
rep(SIGN / "DeveloperPortal/Authentication.swift",
    '"X-MMe-Client-Info": anisetteData.clientInfo,',
    '"X-MMe-Client-Info": anisetteData.gsaClientInfo,')
rep(SIGN / "DeveloperPortal/Authentication.swift",
    '"X-MMe-Client-Info": a.clientInfo,',
    '"X-MMe-Client-Info": a.gsaClientInfo,')
rep(SIGN / "DeveloperPortal/DeveloperPortalAPI.swift",
    '"X-MMe-Client-Info": a.clientInfo,',
    '"X-MMe-Client-Info": a.gsaClientInfo,')
rep(SIGN / "DeveloperPortal/DeveloperPortalAPI.swift",
    'headers["X-MMe-Client-Info"] = a.clientInfo',
    'headers["X-MMe-Client-Info"] = a.gsaClientInfo')
rep(SIGN / "Anisette/AnisetteDataManager.swift",
    "        let clientInfo = headers?.clientInfo ?? Constants.Anisette.defaultClientInfo\n",
    "        let clientInfo = AnisetteData.gsaSafeClientInfo(headers?.clientInfo ?? Constants.Anisette.defaultClientInfo)\n")

# ---------------------------------------------------------------------------
# 3. SideStore provisioning
#    a) Bundles inside Watch/ (the watch app AND its extensions, e.g. Sage's
#       complication widget) run on the watch: watchOS profiles + watch registered.
#    b) Feature update: watchOS platform first for watch bundles (Xcode/isideload
#       recipe), then plain, then without HealthKit if Apple refuses it, so an
#       install never fails only because a capability was refused.
# ---------------------------------------------------------------------------
fetch = APP / "Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift"
rep(fetch,
    "        let profileDeviceType: ALTDeviceType = targetAppBundle.isWatchApp ? .appleWatch : DeveloperPortalProxy.currentDeviceType\n",
    "        let profileDeviceType: ALTDeviceType = targetAppBundle.sageRunsOnWatch ? .appleWatch : DeveloperPortalProxy.currentDeviceType\n")
rep(fetch,
    "        if targetAppBundle.isWatchApp {\n            await self.registerPairedWatches(team: team)\n        }\n",
    "        if targetAppBundle.sageRunsOnWatch {\n            await self.registerPairedWatches(team: team)\n        }\n")
rep_ws(fetch,
    """        // set for requesting and send request
        var appID = appID
        appID.features = targetFeatures

        do {
            let updated = try await DeveloperPortalProxy.shared.updateAppID(appID, team: team)
            self.verboseLog("[FetchProvisioningProfiles] Updated features for App ID \\(updated.bundleIdentifier).")
            return updated
        } catch {
            self.debugLog("[FetchProvisioningProfiles] Failed to update features for App ID \\(appID.bundleIdentifier). \\(error.localizedDescription)")
            throw error
        }
""",
    """        // set for requesting and send request
        var appID = appID
        appID.features = targetFeatures

        // Sage patch: watch bundles are updated with DTDK_Platform=watchos first (what Xcode
        // and isideload send), then plainly; if Apple refuses HealthKit for this team, the
        // install carries on without it instead of failing.
        var attempts: [(label: String, features: [ALTFeature: String])] = []
        if targetAppBundle.sageRunsOnWatch {
            var watchFeatures = targetFeatures
            watchFeatures[ALTFeature("DTDK_Platform")] = "watchos"
            attempts.append((label: "watchOS", features: watchFeatures))
        }
        attempts.append((label: "plain", features: targetFeatures))
        if targetFeatures[ALTFeature.healthKit] != nil {
            var withoutHealthKit = targetFeatures
            withoutHealthKit.removeValue(forKey: ALTFeature.healthKit)
            attempts.append((label: "without HealthKit", features: withoutHealthKit))
        }

        var lastError: Error? = nil
        for attempt in attempts {
            appID.features = attempt.features
            do {
                let updated = try await DeveloperPortalProxy.shared.updateAppID(appID, team: team)
                self.debugLog("[FetchProvisioningProfiles] Updated features (\\(attempt.label)) for App ID \\(updated.bundleIdentifier): \\(attempt.features.keys.map { $0.rawValue }.sorted())")
                return updated
            } catch {
                lastError = error
                self.debugLog("[FetchProvisioningProfiles] Feature update (\\(attempt.label)) failed for App ID \\(appID.bundleIdentifier). \\(error.localizedDescription)")
            }
        }
        throw lastError ?? (OperationError.invalidParameters("Feature update failed for \\(appID.bundleIdentifier)") as Error)
""")
append(fetch, '''
// Sage patch: anything nested in an app's Watch/ folder (the watch app and its own
// extensions, such as a complication widget) is installed on the watch.
extension ALTApplication {
    var sageRunsOnWatch: Bool {
        if isWatchApp { return true }
        let parts = fileURL.standardizedFileURL.pathComponents
        guard let index = parts.lastIndex(of: "Watch"), index >= 1, index + 1 < parts.count else { return false }
        return parts[index - 1].lowercased().hasSuffix(".app") && parts[index + 1].lowercased().hasSuffix(".app")
    }
}
''')

# ---------------------------------------------------------------------------
# 4. Refresh renews the watch app too. The watch keeps its own profile store, so
#    a refresh that only installs profiles on the iPhone lets the watch app expire
#    after 7 days. Push the watch bundles' new profiles to the watch's misagent.
#    Best effort: a missing/asleep watch never fails the iPhone refresh.
# ---------------------------------------------------------------------------
refresh = APP / "Core/Operations/PipelineOperations/RefreshAppOperation.swift"
# after the iPhone's own profiles are handled, so a slow or absent watch never delays them
rep(refresh,
    "            self.setProgress(85)\n",
    "            await self.sageRenewWatchProfiles(appBundle: appBundle, profiles: profiles)\n"
    "            self.setProgress(85)\n")
rep(refresh,
    "        self.setProgress(80)\n",
    "        await self.sageRenewWatchProfiles(appBundle: appBundle, profiles: profiles)\n"
    "        self.setProgress(80)\n")
append(refresh, '''
extension RefreshAppOperation {
    // Sage patch: renew the watch app's provisioning profiles on the paired watch.
    func sageRenewWatchProfiles(appBundle: ALTApplication, profiles: [String: ALTProvisioningProfile]) async {
        var watchIDs = Set<String>()
        for watchApp in appBundle.watchApps {
            watchIDs.insert(watchApp.bundleIdentifier)
            for watchExtension in watchApp.appExtensions {
                watchIDs.insert(watchExtension.bundleIdentifier)
            }
        }
        guard !watchIDs.isEmpty else { return }
        let watchProfiles = profiles
            .filter { watchIDs.contains($0.key) || watchIDs.contains($0.value.bundleIdentifier) }
            .sorted { $0.key < $1.key }
            .map { $0.value.data }
        guard !watchProfiles.isEmpty else {
            self.debugLog("[RefreshAppOperation] No watch profiles among \\(Array(profiles.keys)) for \\(Array(watchIDs))")
            return
        }
        do {
            try await installWatchProvisioningProfiles(watchProfiles) { [weak self] line in
                self?.debugLog("[RefreshAppOperation][watch] \\(line)")
            }
            self.debugLog("[RefreshAppOperation] Renewed \\(watchProfiles.count) profile(s) on the watch")
        } catch {
            self.debugLog("[RefreshAppOperation] Could not renew watch profiles (refresh continues): \\(error)")
        }
    }
}
''')

rep(APP / "Core/DeviceApi/MinimuxerWrapper.swift",
    "/// Issue #229: UDIDs of watches paired to this phone.",
    """/// Sage patch: install provisioning profiles on the paired watch (renews the watch app on refresh).
func installWatchProvisioningProfiles(_ profiles: [Data], progress: (@Sendable (String) -> Void)? = nil) async throws {
    #if targetEnvironment(simulator)
    debugLog("[SideStore] installWatchProvisioningProfiles() is no-op on simulator")
    #else
    debugLog("[SideStore] installWatchProvisioningProfiles() invoked for \\(profiles.count) profile(s)")
    try await withRemotePairingRetry {
        try await minimuxer.core.installWatchProvisioningProfiles(profiles, progress: progress)
    }
    #endif
}

/// Issue #229: UDIDs of watches paired to this phone.""")

# ---------------------------------------------------------------------------
# 5. minimuxer: watch profile install + reuse of the watch pairing record
# ---------------------------------------------------------------------------
sig = "    func installWatchApps(_ watchAppURLs: [URL], progress: (@Sendable (String) -> Void)?) async throws\n"
new_req = sig + "    func installWatchProvisioningProfiles(_ profiles: [Data], progress: (@Sendable (String) -> Void)?) async throws\n"
rep(MUX / "DeviceGateway/DeviceGatewayAPI.swift", sig, new_req)
rep(MUX / "Sources/MinimuxerApi.swift", sig, new_req)
rep(MUX / "DeviceGateway/DeviceGatewayAPI.swift",
    """        throw DeviceGatewayError(.unsupportedOperation, reason: "installWatchApps")
    }
""",
    """        throw DeviceGatewayError(.unsupportedOperation, reason: "installWatchApps")
    }

    func installWatchProvisioningProfiles(_ profiles: [Data], progress: (@Sendable (String) -> Void)?) async throws {
        throw DeviceGatewayError(.unsupportedOperation, reason: "installWatchProvisioningProfiles")
    }
""")
rep(MUX / "Sources/MinimuxerImpl.swift",
    """            try await self.gateway.installWatchApps(watchAppURLs, progress: progress)
        }
    }
""",
    """            try await self.gateway.installWatchApps(watchAppURLs, progress: progress)
        }
    }

    func installWatchProvisioningProfiles(_ profiles: [Data], progress: (@Sendable (String) -> Void)?) async throws {
        try await matchingPriority{
            try await self.gateway.installWatchProvisioningProfiles(profiles, progress: progress)
        }
    }
""")

watch = MUX / "DeviceGateway/idevice/IdeviceGateway+WatchCompanion.swift"
rep(watch,
    "    private func openWatchLockdownSession(step: (String) -> Void, result: inout WatchCompanionSpikeResult) throws -> WatchLockdownSession {\n",
    "    private func openWatchLockdownSession(step: (String) -> Void, result: inout WatchCompanionSpikeResult, allowPairing: Bool = true) throws -> WatchLockdownSession {\n")
rep(watch,
    "        let (hostID, systemBUID) = Self.watchHostIdentity(phonePairing: pairingDataDict)\n",
    """        // Sage patch: reuse the record from the last successful pairing, so the watch
        // asks for Trust only once and a background refresh can never block on a prompt.
        let pairingKey = "sidestore.watch.pairing." + (udids.first ?? "default")
        if let saved = UserDefaults.standard.data(forKey: pairingKey) {
            var savedPairing: OpaquePointer? = nil
            let loadErr = saved.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> UnsafeMutablePointer<IdeviceFfiError>? in
                idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(saved.count), &savedPairing)
            }
            if let loadErr {
                safeFreeError(loadErr)
                step("9a: saved watch pairing unreadable; pairing again")
            } else if let savedPairing {
                if let err = lockdownd_start_session(lockdown, savedPairing) {
                    let msg = getErrorMessage(from: err)
                    safeFreeError(err)
                    idevice_pairing_file_free(savedPairing)
                    step("9a: saved watch pairing rejected (\\(msg)); pairing again")
                } else {
                    result.paired = true
                    result.sessionStarted = true
                    step("11: SESSION STARTED with saved pairing (no Trust prompt)")
                    lockdownOwned = false
                    return WatchLockdownSession(lockdown: lockdown, pairing: savedPairing, legacy: false, connectedHost: host)
                }
            }
        }
        guard allowPairing else {
            throw IdeviceGatewayError(.serviceError, reason: "The watch has not trusted SideStore yet. Reinstall the app in SideStore with the watch nearby and tap Trust on the watch.")
        }

        let (hostID, systemBUID) = Self.watchHostIdentity(phonePairing: pairingDataDict)
""")
rep(watch,
    '        step("11: SESSION STARTED — watch lockdown fully reachable")\n',
    '''        step("11: SESSION STARTED — watch lockdown fully reachable")
        var pairBytes: UnsafeMutablePointer<UInt8>? = nil
        var pairSize: UInt = 0
        if idevice_pairing_file_serialize(watchPairing, &pairBytes, &pairSize) == nil, let pairBytes {
            UserDefaults.standard.set(Data(bytes: pairBytes, count: Int(pairSize)), forKey: pairingKey)
            idevice_data_free(pairBytes, pairSize)
            step("11a: saved watch pairing for next time")
        }
''')
rep(watch,
    "    // MARK: - Spike (diagnostic)\n",
    """    /// Sage patch: install provisioning profiles on the paired watch through its misagent,
    /// so a refresh renews the watch app's 7-day profile. Never pairs, so it never waits
    /// for a Trust prompt.
    public func installWatchProvisioningProfiles(_ profiles: [Data], progress: (@Sendable (String) -> Void)?) async throws {
        guard !profiles.isEmpty else { return }
        try await runOnBigStackThread("watch-profiles") {
            try self.syncInstallWatchProvisioningProfiles(profiles, progress: progress)
        }
    }

    private func syncInstallWatchProvisioningProfiles(_ profiles: [Data], progress: (@Sendable (String) -> Void)?) throws {
        var scratch = WatchCompanionSpikeResult()
        func step(_ s: String) {
            progress?(s)
            debugLog("[WatchProfiles] \\(s)")
        }

        let session = try openWatchLockdownSession(step: step, result: &scratch, allowPairing: false)
        defer {
            session.free()
            stopForwarding(Self.watchLockdownPort, step: step)
        }

        for (index, profile) in profiles.enumerated() {
            let (dev, remotePort) = try openWatchService("com.apple.misagent", session: session, step: step)
            defer {
                idevice_free(dev)
                stopForwarding(remotePort, step: step)
            }
            try sendPrefixedPlist(dev, ["MessageType": "Install", "Profile": profile, "ProfileType": "Provisioning"])
            let response = try readPrefixedPlist(dev)
            let status = (response["Status"] as? NSNumber)?.intValue ?? -1
            guard status == 0 else {
                throw IdeviceGatewayError(.serviceError, reason: "Watch refused profile \\(index + 1): \\(response)")
            }
            step("P: profile \\(index + 1)/\\(profiles.count) installed on the watch")
        }
    }

    // MARK: - Spike (diagnostic)
""")

print("all patches applied")

import Foundation
import Darwin

/// Pending desktop↔device origin conflict for one C6. Shown in the device page
/// until the user keeps the device document or explicitly overrides from Mac.
public struct C6SyncOriginConflict: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case homeAssistant, printer }
    public var kind: Kind
    public var message: String
    public var inputKey: String
    public init(kind: Kind, message: String, inputKey: String) {
        self.kind = kind; self.message = message; self.inputKey = inputKey
    }
}

/// Desktop additions and device-owned local cards share one configuration.
/// Removing a desktop image card never deletes an independently configured source.
public enum C6ConfigurationSync {
    /// Periodic reads adopt device-side edits until the desktop input changes.
    /// The restart-safe input checkpoint is persisted without any credentials.
    public static func shouldApplySelection(inputKey: String, lastSyncedInputKey: String?) -> Bool {
        lastSyncedInputKey != inputKey
    }
    /// Adopting a web-edited HA endpoint must not authorize pictures cached from
    /// the desktop's different server, even if the entity IDs happen to match.
    public static func canRetainMediaOrigin(previous: C6StandaloneConfiguration?,
                                            current: C6StandaloneConfiguration,
                                            originMatches: Bool) -> Bool {
        guard originMatches, let previous else { return false }
        return previous.ha.host == current.ha.host && previous.ha.port == current.ha.port
            && previous.ha.tls == current.ha.tls
    }
    /// A desktop edit alone is not proof that cached pictures belong to the
    /// device's HA server. Only a validated, enabled exact endpoint may authorize
    /// media after a merge; unrelated theme changes can preserve another origin.
    public static func canAuthorizeMediaOrigin(selection: C6StandaloneConfiguration?,
                                              current: C6StandaloneConfiguration) -> Bool {
        guard let selection, selection.ha.enabled, current.ha.enabled,
              !selection.ha.host.isEmpty, !current.ha.host.isEmpty else { return false }
        return selection.ha.host == current.ha.host && selection.ha.port == current.ha.port
            && selection.ha.tls == current.ha.tls
    }
    /// Web-only printers keep their local source; desktop media is only valid
    /// for an explicitly selected printer with the same account/source mapping.
    public static func mediaSourceMatches(_ printer: C6PrinterConfiguration,
                                           selected: C6PrinterConfiguration) -> Bool {
        guard printer.enabled, selected.enabled, printer.identity == selected.identity,
              printer.source == selected.source else { return false }
        if printer.sourceFormlabs { return printer.formClientID == selected.formClientID }
        if printer.sourceHA {
            return printer.statusEntity == selected.statusEntity && printer.taskEntity == selected.taskEntity
                && printer.imageEntity == selected.imageEntity && printer.taskCoverEntity == selected.taskCoverEntity
        }
        return printer.host == selected.host
    }
    /// Match URLSession's standard URL semantics, including reverse proxies using port 80.
    public static func homeAssistantEndpoint(_ value: String) -> (host: String, port: Int, tls: Bool)? {
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        let tls = scheme == "https", port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return (host, port, tls)
    }
    /// A firmware instance has one HA subscription origin. Combining different
    /// origins would bind existing entity IDs to a new server or send the wrong
    /// token. The caller must stop before sending credentials when this is true.
    public static func hasHomeAssistantOriginConflict(selection: C6StandaloneConfiguration,
                                                     remote: C6StandaloneConfiguration) -> Bool {
        guard selection.ha.enabled, !remote.ha.host.isEmpty,
              remote.ha.enabled || !remote.ha.entities.isEmpty || remote.printers.contains(where: \.sourceHA)
        else { return false }
        return selection.ha.host != remote.ha.host || selection.ha.port != remote.ha.port
            || selection.ha.tls != remote.ha.tls
    }
    private static func samePrinterOrigin(_ selected: C6PrinterConfiguration,
                                          in selection: C6StandaloneConfiguration,
                                          _ previous: C6PrinterConfiguration,
                                          in remote: C6StandaloneConfiguration) -> Bool {
        guard selected.identity == previous.identity, selected.source == previous.source else { return false }
        if selected.sourceFormlabs { return selected.formClientID == previous.formClientID }
        if selected.sourceHA {
            return selection.ha.host == remote.ha.host && selection.ha.port == remote.ha.port
                && selection.ha.tls == remote.ha.tls
        }
        return selected.host == previous.host
    }
    public static func hasPrinterOriginConflict(selection: C6StandaloneConfiguration,
                                               remote: C6StandaloneConfiguration) -> Bool {
        selection.printers.contains { selected in
            guard let existing = remote.printers.first(where: { $0.identity == selected.identity }) else { return false }
            return !samePrinterOrigin(selected, in: selection, existing, in: remote)
        }
    }
    private static func selectedPrinterEquivalent(_ a: C6PrinterConfiguration,
                                                  _ b: C6PrinterConfiguration) -> Bool {
        var a = a, b = b
        // These values belong to the local card manager, not desktop source input.
        a.rotate = true; b.rotate = true
        a.cardStyle = .standard; b.cardStyle = .standard
        a.accessCodeSet = false; b.accessCodeSet = false
        a.formCredentialsSet = false; b.formCredentialsSet = false
        return a == b
    }
    private static func sameHAOrigin(_ a: C6HAConfiguration, _ b: C6HAConfiguration) -> Bool {
        a.host == b.host && a.port == b.port && a.tls == b.tls
    }
    /// Only changed data-source selections, with unchanged endpoint metadata
    /// retained for exact printer-origin checks. This is not a PUT document.
    public static func changedSelection(_ selection: C6StandaloneConfiguration,
                                        since previousSelection: C6StandaloneConfiguration?) -> C6StandaloneConfiguration {
        guard let previous = previousSelection else { return selection }
        var changed = selection
        changed.clock = selection.clock && !previous.clock
        changed.printers = selection.printers.filter { printer in
            guard let prior = previous.printers.first(where: { $0.identity == printer.identity }) else { return true }
            return !selectedPrinterEquivalent(printer, prior)
        }
        let completeHAChange = !previous.ha.enabled || !sameHAOrigin(selection.ha, previous.ha)
        changed.ha.entities = selection.ha.entities.filter { entity in
            completeHAChange || previous.ha.entities.first(where: { $0.id == entity.id }) != entity
        }
        changed.ha.enabled = selection.ha.enabled && (completeHAChange || !changed.ha.entities.isEmpty)
        if !changed.ha.enabled { changed.ha.entities = [] }
        changed.weather = selection.weather && (!previous.weather || selection.latitude != previous.latitude
            || selection.longitude != previous.longitude || selection.weatherCity != previous.weatherCity
            || selection.weatherMinutes != previous.weatherMinutes)
        return changed
    }
    private static func applyPrinterChange<Value: Equatable>(_ key: WritableKeyPath<C6PrinterConfiguration, Value>,
                                                             selected: C6PrinterConfiguration,
                                                             previous: C6PrinterConfiguration,
                                                             into result: inout C6PrinterConfiguration) {
        if selected[keyPath: key] != previous[keyPath: key] { result[keyPath: key] = selected[keyPath: key] }
    }
    /// Restart-safe ownership: unchanged desktop fields never undo a web edit,
    /// and a single field edit does not replace the rest of a local printer card.
    public static func applyingChanges(_ selection: C6StandaloneConfiguration,
                                       since previousSelection: C6StandaloneConfiguration?,
                                       into remote: C6StandaloneConfiguration) -> C6StandaloneConfiguration {
        let delta = changedSelection(selection, since: previousSelection)
        guard !hasHomeAssistantOriginConflict(selection: delta, remote: remote),
              !hasPrinterOriginConflict(selection: delta, remote: remote) else { return remote }
        guard let previous = previousSelection else { return merging(selection, into: remote) }
        var result = remote
        if selection.brightness != previous.brightness { result.brightness = selection.brightness }
        if selection.saturationPercent != previous.saturationPercent { result.saturationPercent = selection.saturationPercent }
        if selection.contrastPercent != previous.contrastPercent { result.contrastPercent = selection.contrastPercent }
        if selection.theme != previous.theme { result.theme = selection.theme }
        if delta.clock { result.clock = true }
        if delta.weather {
            result.weather = true
            if !previous.weather || selection.latitude != previous.latitude { result.latitude = selection.latitude }
            if !previous.weather || selection.longitude != previous.longitude { result.longitude = selection.longitude }
            if !previous.weather || selection.weatherCity != previous.weatherCity { result.weatherCity = selection.weatherCity }
            if !previous.weather || selection.weatherMinutes != previous.weatherMinutes { result.weatherMinutes = selection.weatherMinutes }
        }
        if delta.ha.enabled {
            if !sameHAOrigin(selection.ha, remote.ha) { result.ha.tokenSet = false }
            result.ha.enabled = true
            result.ha.host = selection.ha.host; result.ha.port = selection.ha.port; result.ha.tls = selection.ha.tls
            for entity in delta.ha.entities {
                if let index = result.ha.entities.firstIndex(where: { $0.id == entity.id }) { result.ha.entities[index] = entity }
                else { result.ha.entities.append(entity) }
            }
        }
        for selected in delta.printers {
            guard let prior = previous.printers.first(where: { $0.identity == selected.identity }),
                  let index = result.printers.firstIndex(where: { $0.identity == selected.identity }) else {
                if let index = result.printers.firstIndex(where: { $0.identity == selected.identity }) {
                    // Newly selected in the desktop, but already independently
                    // configured on-device: preserve its local style/rotation.
                    var item = selected
                    item.rotate = result.printers[index].rotate; item.cardStyle = result.printers[index].cardStyle
                    item.accessCodeSet = result.printers[index].accessCodeSet
                    item.formCredentialsSet = result.printers[index].formCredentialsSet
                    result.printers[index] = item
                } else {
                    var item = selected; item.accessCodeSet = false; item.formCredentialsSet = false
                    result.printers.append(item)
                }
                continue
            }
            var item = result.printers[index]
            for key in [\C6PrinterConfiguration.enabled, \.trustLAN, \.sourceHA, \.sourceFormlabs,
                        \.showLayers, \.showMaterial, \.showStatus, \.showProgress, \.showTask,
                        \.showRemaining, \.showImage, \.showNozzle, \.showBed, \.showError,
                        \.brandAccent, \.liveImage] {
                applyPrinterChange(key, selected: selected, previous: prior, into: &item)
            }
            for key in [\C6PrinterConfiguration.host, \.serial, \.name, \.certificate, \.formClientID,
                        \.statusEntity, \.progressEntity, \.taskEntity, \.remainingEntity, \.imageEntity,
                        \.nozzleEntity, \.bedEntity, \.errorEntity, \.endTimeEntity, \.taskCoverEntity] {
                applyPrinterChange(key, selected: selected, previous: prior, into: &item)
            }
            applyPrinterChange(\.timeMode, selected: selected, previous: prior, into: &item)
            result.printers[index] = item
        }
        return result
    }
    /// Explicit user choice after an origin conflict banner: desktop data-source
    /// origins replace the device document. Automatic sync keeps using the safer
    /// `applyingChanges` path that refuses to cross origins without confirmation.
    public static func overridingOrigins(_ selection: C6StandaloneConfiguration,
                                         into remote: C6StandaloneConfiguration) -> C6StandaloneConfiguration {
        var result = remote
        result.brightness = selection.brightness
        result.saturationPercent = selection.saturationPercent
        result.contrastPercent = selection.contrastPercent
        result.theme = selection.theme
        result.clock = remote.clock || selection.clock
        if selection.ha.enabled {
            result.ha = selection.ha
            result.ha.tokenSet = false
            result.ha.entities = selection.ha.entities
        }
        if selection.weather {
            result.weather = true
            result.latitude = selection.latitude
            result.longitude = selection.longitude
            result.weatherCity = selection.weatherCity
            result.weatherMinutes = selection.weatherMinutes
        }
        for selected in selection.printers {
            var item = selected
            item.accessCodeSet = false
            item.formCredentialsSet = false
            if let index = result.printers.firstIndex(where: { $0.identity == item.identity }) {
                item.rotate = result.printers[index].rotate
                item.cardStyle = result.printers[index].cardStyle
                result.printers[index] = item
            } else {
                result.printers.append(item)
            }
        }
        // After an HA origin change, drop leftover HA printers that the desktop did not select.
        if selection.ha.enabled, hasHomeAssistantOriginConflict(selection: selection, remote: remote) {
            result.printers.removeAll { printer in
                printer.sourceHA && !selection.printers.contains(where: { $0.identity == printer.identity })
            }
        }
        return result
    }

    public static func merging(_ selection: C6StandaloneConfiguration,
                               into remote: C6StandaloneConfiguration) -> C6StandaloneConfiguration {
        // The caller checks this before preparing credentials. Returning the
        // remote document also ensures read-only planning cannot cross origins.
        guard !hasHomeAssistantOriginConflict(selection: selection, remote: remote) else { return remote }
        var result = remote
        result.brightness = selection.brightness
        result.saturationPercent = selection.saturationPercent
        result.contrastPercent = selection.contrastPercent
        result.theme = selection.theme
        result.clock = remote.clock || selection.clock
        // Clock style, animation and timezone are always owned by the firmware.
        if selection.ha.enabled {
            let keepsToken = remote.ha.host == selection.ha.host && remote.ha.port == selection.ha.port
                && remote.ha.tls == selection.ha.tls && remote.ha.tokenSet
            result.ha = selection.ha
            result.ha.tokenSet = keepsToken
            var entities = remote.ha.entities
            for entity in selection.ha.entities {
                if let index = entities.firstIndex(where: { $0.id == entity.id }) { entities[index] = entity }
                else { entities.append(entity) }
            }
            result.ha.entities = entities
        }
        if selection.weather {
            result.weather = true
            result.latitude = selection.latitude; result.longitude = selection.longitude
            result.weatherCity = selection.weatherCity; result.weatherMinutes = selection.weatherMinutes
        }
        for selected in selection.printers {
            var p = selected
            if let index = remote.printers.firstIndex(where: { $0.identity == p.identity }) {
                let previous = remote.printers[index]
                if samePrinterOrigin(p, in: selection, previous, in: remote) {
                    p.rotate = previous.rotate; p.cardStyle = previous.cardStyle
                    p.accessCodeSet = !p.sourceHA && !p.sourceFormlabs && previous.accessCodeSet
                    p.formCredentialsSet = p.sourceFormlabs && previous.formCredentialsSet
                } else {
                    p.accessCodeSet = false; p.formCredentialsSet = false
                }
                result.printers[index] = p
            } else {
                p.accessCodeSet = false; p.formCredentialsSet = false
                result.printers.append(p)
            }
        }
        // Do not truncate to device capacity. isValid/save reject an oversized
        // merged configuration atomically, preserving the existing device data.
        return result
    }
    public static func equivalent(_ a: C6StandaloneConfiguration, _ b: C6StandaloneConfiguration) -> Bool {
        var a = a, b = b
        a.revision = 0; b.revision = 0
        a.ha.tokenSet = false; b.ha.tokenSet = false
        for i in a.printers.indices { a.printers[i].accessCodeSet = false; a.printers[i].formCredentialsSet = false }
        for i in b.printers.indices { b.printers[i].accessCodeSet = false; b.printers[i].formCredentialsSet = false }
        return a == b
    }
    /// mDNS/server names are resolved locally; credentials are never sent to public IPs.
    public static func localIPv4(_ host: String) async throws -> String {
        if C6StandaloneConfiguration.privateIP(host) { return host }
        return try await Task.detached(priority: .utility) {
            var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
            var addresses: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &addresses) == 0 else { throw C6StandaloneError.address }
            defer { if let addresses { freeaddrinfo(addresses) } }
            var cursor = addresses
            while let entry = cursor {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let candidate = String(cString: text)
                    if C6StandaloneConfiguration.privateIP(candidate) { return candidate }
                }
                cursor = entry.pointee.ai_next
            }
            throw C6StandaloneError.address
        }.value
    }
}

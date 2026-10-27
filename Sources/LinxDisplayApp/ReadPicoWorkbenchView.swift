import AppKit
import SwiftUI
import LinxDisplayCore

/// The same device workspace can live in the main device detail or in a standalone
/// diagnostic window. The parent owns navigation when the workspace is embedded.
struct ReadPicoWorkbenchView: View {
    let embedded: Bool
    let initialEndpoint: String
    let initialSection: String
    let section: ReadPicoDeviceSection
    let appModel: AppModel?
    let deviceID: UUID?
    let settingsHeader: AnyView?
    let onConfigureModule: ((CanvasModule) -> Void)?
    let onEndpointVerified: ((String) -> Void)?
    let onBusyChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var firmwareBusy = false
    @State private var contentBusy = false
    @State private var showsReadingNotes = true
    @State private var notesSyncRequestID: UUID?
    @State private var notesSyncBusy = false
    @StateObject private var drafts: ReadPicoDraftGuard
    private let ownsDraftGuard: Bool
    private var busy: Bool { firmwareBusy || contentBusy || notesSyncBusy }
    private var showsManager: Bool { section.managerSection != nil && (section != .notes || !showsReadingNotes) }

    init(embedded: Bool = false, initialEndpoint: String = "", initialSection: String = "books",
         section: ReadPicoDeviceSection? = nil, appModel: AppModel? = nil, deviceID: UUID? = nil,
         draftGuard: ReadPicoDraftGuard? = nil, settingsHeader: AnyView? = nil,
         onConfigureModule: ((CanvasModule) -> Void)? = nil, onEndpointVerified: ((String) -> Void)? = nil,
         onBusyChange: ((Bool) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.embedded = embedded
        self.initialEndpoint = initialEndpoint
        self.initialSection = initialSection
        self.section = section ?? (initialSection == "canvas" ? .information : initialSection == "connection" ? .settings
                                   : ReadPicoDeviceSection(rawValue: initialSection) ?? .books)
        self.settingsHeader = settingsHeader
        self.onConfigureModule = onConfigureModule
        self.appModel = appModel
        self.deviceID = deviceID
        self.onEndpointVerified = onEndpointVerified
        self.onBusyChange = onBusyChange
        self.onClose = onClose
        ownsDraftGuard = draftGuard == nil
        _drafts = StateObject(wrappedValue: draftGuard ?? ReadPicoDraftGuard())
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack {
                    Label("小纸 Pico", systemImage: "book.closed").font(.title2.weight(.semibold))
                    Spacer()
                    Button("关闭") { drafts.request(title: "关闭设备管理前保存修改？") {
                        if let onClose { onClose() } else { dismiss() }
                    } }.keyboardShortcut(.cancelAction)
                        .disabled(busy)
                }.padding(20)
                Divider()
            }
            if section == .notes {
                Picker("笔记类型", selection: $showsReadingNotes) {
                    Text("书内划线与批注").tag(true)
                    Text("独立文本笔记").tag(false)
                }.pickerStyle(.segmented).frame(maxWidth: 360).padding(16).disabled(busy)
                Divider()
            }
            ZStack(alignment: .topLeading) {
                // Keep transient input and the TF browser alive when another
                // reader section is selected. Navigation never recreates its session.
                manager
                    .opacity(showsManager ? 1 : 0)
                    .allowsHitTesting(showsManager)
                    .accessibilityHidden(!showsManager)
                switch section {
                case .books, .fonts, .apps, .drawings, .settings: EmptyView()
                case .notes:
                    if showsReadingNotes {
                        VStack(spacing: 0) {
                            ReadPicoUSBConnectionPanel(drafts: drafts, compact: true,
                                onSync: { notesSyncRequestID = UUID() }, syncDisabled: notesSyncBusy,
                                syncRequiresUSB: true)
                                .padding(.horizontal, 20).padding(.top, 12)
                            ReadPicoReadingNotesView(deviceID: deviceID, mountedCardRoot: drafts.model.store?.rootURL,
                                transferBusy: firmwareBusy || contentBusy,
                                destinations: appModel?.readingExcerptDestinations ?? [],
                                syncRequestID: notesSyncRequestID, showsSyncButton: false,
                                syncFailure: drafts.model.isError ? drafts.model.message : drafts.model.cardError ? drafts.model.cardMessage : nil,
                                onBusyChange: { value in
                                    notesSyncBusy = value
                                    drafts.externalBusy = value || firmwareBusy || contentBusy
                                },
                                onLibraryChanged: { appModel?.refreshReadingExcerpts(force: true) })
                        }
                    }
                case .information:
                    if let appModel, let deviceID {
                        ReadPicoLingxiBoardView(model: appModel, deviceID: deviceID, drafts: drafts, onConfigureModule: onConfigureModule)
                    } else {
                        ContentUnavailableView("请从设备侧栏打开灵犀画板", systemImage: "rectangle.on.rectangle")
                    }
                case .lockScreen:
                    ReadPicoLockScreenView(drafts: drafts, deviceID: deviceID)
                case .firmware: firmware
                }
            }
        }.frame(minWidth: embedded ? 0 : 880, idealWidth: embedded ? nil : 1020,
                maxWidth: .infinity, minHeight: embedded ? 0 : 720,
                idealHeight: embedded ? nil : 820, maxHeight: .infinity)
            .interactiveDismissDisabled(busy || drafts.blocksDismissal)
            .onAppear {
                drafts.model.transportPreference = appModel?.settings.devices.first { $0.id == deviceID }?.settings.readPico?.transportPreference ?? .automatic
            }
            .onChange(of: drafts.model.transportPreference) { _, preference in
                if let deviceID { appModel?.updateReadPicoTransportPreference(deviceID: deviceID, preference: preference) }
            }
            .onChange(of: busy) { _, value in
                drafts.externalBusy = value
                onBusyChange?(value)
            }
            .onChange(of: section) { _, _ in notesSyncRequestID = nil; NSApp.keyWindow?.makeFirstResponder(nil) }
            .onChange(of: showsReadingNotes) { _, value in if !value { notesSyncRequestID = nil } }
            .onChange(of: drafts.model.waitingForUSBVolume) { _, waiting in
                if !waiting, drafts.model.store == nil { notesSyncRequestID = nil }
            }
            .modifier(ReadPicoDraftProtection(drafts: drafts, enabled: ownsDraftGuard))
    }

    private var manager: some View {
        ReadPicoManagerView(initialHost: initialEndpoint, initialSection: initialSection,
                            externalSection: section.managerSection ?? "books",
                            onBusyChange: { value in
                                contentBusy = value
                                drafts.externalBusy = value || firmwareBusy || notesSyncBusy
                            }, draftGuard: drafts,
                            embedded: embedded, onEndpointVerified: onEndpointVerified,
                            automaticUSBPreparation: appModel?.settings.devices.first { $0.id == deviceID }?.settings.readPico?.automaticUSBPreparation ?? true,
                            onAutomaticUSBPreparationChange: { enabled in
                                if let deviceID { appModel?.updateReadPicoAutomaticUSBPreparation(deviceID: deviceID, enabled: enabled) }
                            }, settingsHeader: settingsHeader, fileManagementVisible: showsManager && [.books, .fonts, .notes, .apps, .drawings].contains(section))
    }

    private var firmware: some View {
        ScrollView {
            ReadPicoFirmwareView(onBusyChange: { value in
                firmwareBusy = value
                drafts.externalBusy = value || contentBusy || notesSyncBusy
            }).padding(embedded ? 16 : 20)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

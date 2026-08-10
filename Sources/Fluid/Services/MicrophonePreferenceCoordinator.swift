import Combine
import Foundation

@MainActor
protocol AudioDeviceManaging {
    var isClamshellClosed: Bool { get }
    func listInputDevices() -> [AudioDevice.Device]
    func defaultInputDevice() -> AudioDevice.Device?
    func isInputDeviceUsable(_ device: AudioDevice.Device) -> Bool
}

extension AudioDeviceManaging {
    var isClamshellClosed: Bool { false }
    func isInputDeviceUsable(_: AudioDevice.Device) -> Bool { true }
}

struct CoreAudioDeviceManager: AudioDeviceManaging {
    var isClamshellClosed: Bool {
        ClamshellState.isClosed
    }

    func listInputDevices() -> [AudioDevice.Device] {
        AudioDevice.listInputDevices()
    }

    func defaultInputDevice() -> AudioDevice.Device? {
        AudioDevice.getDefaultInputDevice()
    }

    func isInputDeviceUsable(_ device: AudioDevice.Device) -> Bool {
        AudioDevice.isInputDeviceAlive(device)
    }
}

@MainActor
final class MicrophonePreferenceCoordinator: ObservableObject {
    private let settings: SettingsStore
    private let devices: any AudioDeviceManaging
    private var lastResolvedInputUID: String?
    private var lastResolvedInputName: String?
    private var hasConfirmedActiveSelection = false
    private var lastConfirmedInputUID: String?
    private var lastConfirmedInputName: String?
    @Published private(set) var confirmedActiveInputUID: String?
    private var startupNoticeTask: Task<Void, Never>?
    private var startupNoticeEligibilityEnabled = false
    private var didPresentStartupNotice = false
    private var startupNoticePresentedUID: String?
    private var startupNoticePresentedName: String?

    init(
        settings: SettingsStore? = nil,
        devices: (any AudioDeviceManaging)? = nil
    ) {
        self.settings = settings ?? .shared
        self.devices = devices ?? CoreAudioDeviceManager()
    }

    var needsMicrophonePriorityMigration: Bool {
        self.settings.microphoneSelectionMigrationVersion < SettingsStore.microphonePriorityMigrationVersion
    }

    func migrateMicrophonePriorityIfNeeded() {
        guard self.needsMicrophonePriorityMigration else { return }
        let inputs = self.devices.listInputDevices()
        let defaultInputUID = self.devices.defaultInputDevice()?.uid
        self.migrateMicrophonePriorityIfNeeded(
            availableInputs: inputs,
            defaultInputUID: defaultInputUID
        )
    }

    func migrateMicrophonePriorityIfNeeded(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) {
        guard self.needsMicrophonePriorityMigration else {
            self.settings.reconcileMicrophonePriority(with: availableInputs)
            return
        }
        let migrationVersion = self.settings.microphoneSelectionMigrationVersion
        let clamshellClosed = self.devices.isClamshellClosed
        let usableInputs = availableInputs.filter {
            self.isInputDeviceAvailable($0, clamshellClosed: clamshellClosed)
        }
        let preferredInput = usableInputs.first { input in
            input.uid == self.settings.preferredInputDeviceUID
        }
        let enumeratedPreferredInput = availableInputs.first { input in
            input.uid == self.settings.preferredInputDeviceUID
        }
        let defaultInput = defaultInputUID.flatMap { uid in
            usableInputs.first { $0.uid == uid }
        }
        let migrationInputs = defaultInput.map { input in
            [input] + availableInputs.filter { $0.uid != input.uid }
        } ?? availableInputs
        let previousMode = self.settings.storedMicSelectionModeForMigration
        if migrationVersion >= 2,
           let preferredUID = self.settings.preferredInputDeviceUID,
           preferredUID.isEmpty == false
        {
            let preferredName = preferredInput?.name ?? "Previously selected microphone"
            self.settings.recordInputDeviceSelection(preferredUID, name: preferredName)
            self.settings.reconcileMicrophonePriority(with: migrationInputs)
            self.settings.microphoneSelectionMode = .manual
            self.settings.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
            return
        }
        let preserveDisconnectedManualSelection =
            migrationVersion == 0 && previousMode == .manual
        let preserveDisconnectedVersionOneExternal =
            migrationVersion == 1 &&
            enumeratedPreferredInput?.isBuiltIn != true &&
            Self.isLikelyBuiltInMicrophoneUID(self.settings.preferredInputDeviceUID) == false
        if preferredInput == nil,
           preserveDisconnectedManualSelection || preserveDisconnectedVersionOneExternal,
           let preferredUID = self.settings.preferredInputDeviceUID,
           preferredUID.isEmpty == false
        {
            self.settings.recordInputDeviceSelection(
                preferredUID,
                name: "Previously selected microphone"
            )
            self.settings.reconcileMicrophonePriority(with: migrationInputs)
            self.settings.microphoneSelectionMode = .manual
            self.settings.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
            return
        }
        let selectedInput: AudioDevice.Device?
        if migrationVersion == 0,
           previousMode == .manual
        {
            selectedInput = preferredInput
                ?? defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        } else if migrationVersion == 0 {
            selectedInput = defaultInput
                ?? preferredInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        } else if migrationVersion == 1,
                  let preferredInput,
                  preferredInput.isBuiltIn,
                  defaultInput?.uid != preferredInput.uid
        {
            // Repair only the known v1 built-in-first migration. Runtime priority
            // resolution itself never ranks a device by transport type.
            selectedInput = defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        } else {
            selectedInput = preferredInput
                ?? defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        }
        guard let selectedInput else {
            self.settings.reconcileMicrophonePriority(with: migrationInputs)
            return
        }

        self.settings.recordInputDeviceSelection(selectedInput.uid, name: selectedInput.name)
        self.settings.reconcileMicrophonePriority(with: migrationInputs)
        self.settings.microphoneSelectionMode = .manual
        self.settings.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
        DebugLogger.shared.info(
            "Migrated FluidVoice microphone priority with '\(selectedInput.name)' first",
            source: "MicrophonePreferenceCoordinator"
        )
    }

    @discardableResult
    func reconcileMicrophoneSelection(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) -> AudioDevice.Device? {
        self.migrateMicrophonePriorityIfNeeded(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID
        )
        let selectedInput = self.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID
        )
        self.lastResolvedInputUID = selectedInput?.uid
        self.lastResolvedInputName = selectedInput?.name
        if self.startupNoticeEligibilityEnabled {
            self.scheduleStartupNoticeAfterSelectionSettles()
        }
        if let confirmedActiveInputUID,
           availableInputs.contains(where: { device in
               device.uid == confirmedActiveInputUID && self.isInputDeviceAvailable(device)
           }) == false
        {
            self.confirmedActiveInputUID = nil
        }
        return selectedInput
    }

    func confirmActiveSelection(uid: String?, name: String?) {
        let previousUID = self.lastConfirmedInputUID
        let previousName = self.lastConfirmedInputName
        self.lastConfirmedInputUID = uid
        self.lastConfirmedInputName = name ?? previousName
        self.confirmedActiveInputUID = uid

        guard self.hasConfirmedActiveSelection else {
            self.hasConfirmedActiveSelection = true
            DebugLogger.shared.debug(
                "Confirmed active microphone as '\(name ?? "none")'",
                source: "MicrophonePreferenceCoordinator"
            )
            if let startupNoticePresentedUID = self.startupNoticePresentedUID,
               uid != startupNoticePresentedUID
            {
                MicrophoneChangeOverlayController.shared.show(
                    MicrophoneChangeNotice(
                        previousName: self.startupNoticePresentedName,
                        currentName: name,
                        presentation: .activeChange
                    )
                )
            }
            return
        }
        guard uid != previousUID else { return }

        let notice = MicrophoneChangeNotice(
            previousName: previousName,
            currentName: name,
            presentation: .activeChange
        )
        DebugLogger.shared.info(
            "Active microphone changed from '\(notice.previousName ?? "none")' " +
                "to '\(notice.currentName ?? "none")' after first PCM",
            source: "MicrophonePreferenceCoordinator"
        )
        MicrophoneChangeOverlayController.shared.show(notice)
    }

    func markActiveSelectionUnavailable() {
        guard self.hasConfirmedActiveSelection,
              self.lastConfirmedInputUID != nil
        else { return }

        let previousName = self.lastConfirmedInputName
        self.confirmedActiveInputUID = nil
        self.lastConfirmedInputUID = nil
        self.lastConfirmedInputName = nil
        MicrophoneChangeOverlayController.shared.show(
            MicrophoneChangeNotice(
                previousName: previousName,
                currentName: nil,
                presentation: .activeChange
            )
        )
    }

    func scheduleStartupNoticeIfEligible(
        microphoneAuthorized: Bool,
        launchAllowsPresentation: Bool
    ) {
        guard microphoneAuthorized,
              launchAllowsPresentation,
              self.settings.shouldShowOnboarding == false,
              self.lastResolvedInputUID != nil,
              self.lastResolvedInputName != nil
        else { return }

        self.startupNoticeEligibilityEnabled = true
        self.scheduleStartupNoticeAfterSelectionSettles()
    }

    private func scheduleStartupNoticeAfterSelectionSettles() {
        guard self.startupNoticeEligibilityEnabled,
              self.didPresentStartupNotice == false,
              self.lastResolvedInputUID != nil,
              self.lastResolvedInputName != nil
        else { return }

        let expectedUID = self.lastResolvedInputUID
        self.startupNoticeTask?.cancel()
        self.startupNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.settings.shouldShowOnboarding == false,
                  self.lastResolvedInputUID == expectedUID,
                  let currentName = self.lastResolvedInputName
            else { return }
            self.startupNoticeTask = nil
            self.didPresentStartupNotice = true
            self.startupNoticePresentedUID = expectedUID
            self.startupNoticePresentedName = currentName
            MicrophoneChangeOverlayController.shared.show(
                MicrophoneChangeNotice(
                    previousName: nil,
                    currentName: currentName,
                    presentation: .startupSelection
                )
            )
        }
    }

    func inputDeviceForCapture() -> AudioDevice.Device? {
        self.inputDeviceForCapture(
            availableInputs: self.devices.listInputDevices(),
            defaultInputUID: self.devices.defaultInputDevice()?.uid
        )
    }

    func inputDeviceForCapture(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String? = nil,
        excluding excludedUIDs: Set<String> = []
    ) -> AudioDevice.Device? {
        let clamshellClosed = self.devices.isClamshellClosed
        let usableInputs = availableInputs.filter { device in
            excludedUIDs.contains(device.uid) == false &&
                self.isInputDeviceAvailable(device, clamshellClosed: clamshellClosed)
        }
        guard usableInputs.isEmpty == false else { return nil }

        for entry in self.settings.microphonePriority {
            if let input = usableInputs.first(where: { $0.uid == entry.uid }) {
                return input
            }
        }

        if let preferredUID = self.settings.preferredInputDeviceUID,
           let preferredInput = usableInputs.first(where: { $0.uid == preferredUID })
        {
            return preferredInput
        }

        return self.fallbackInput(
            from: usableInputs,
            defaultInputUID: defaultInputUID
        )
    }

    func isInputDeviceAvailable(_ device: AudioDevice.Device) -> Bool {
        self.isInputDeviceAvailable(
            device,
            clamshellClosed: self.devices.isClamshellClosed
        )
    }

    func movePriority(fromOffsets: IndexSet, toOffset: Int) {
        self.settings.reorderMicrophonePriority(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    private func fallbackInput(
        from inputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) -> AudioDevice.Device? {
        guard inputs.isEmpty == false else { return nil }
        if let defaultInput = self.device(uid: defaultInputUID, in: inputs) {
            return defaultInput
        }
        return inputs.first
    }

    private func device(
        uid: String?,
        in inputs: [AudioDevice.Device]
    ) -> AudioDevice.Device? {
        guard let uid else { return nil }
        return inputs.first { $0.uid == uid }
    }

    private static func isLikelyBuiltInMicrophoneUID(_ uid: String?) -> Bool {
        guard let uid else { return false }
        let normalized = uid.lowercased()
        return normalized.contains("builtin") ||
            normalized.contains("built-in") ||
            normalized.contains("internal")
    }

    private func isInputDeviceAvailable(
        _ device: AudioDevice.Device,
        clamshellClosed: Bool
    ) -> Bool {
        guard self.settings.suppressedMicrophoneUIDs.contains(device.uid) == false else { return false }
        guard clamshellClosed == false || device.isBuiltIn == false else { return false }
        return self.devices.isInputDeviceUsable(device)
    }
}

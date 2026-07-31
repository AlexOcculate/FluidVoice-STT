enum AudioCaptureIdlePolicy {
    static func shouldPrewarmCapture(experimentalDirectAudioCaptureEnabled: Bool) -> Bool {
        experimentalDirectAudioCaptureEnabled
    }

    static func shouldEnforceSystemPreferredInput(
        experimentalDirectAudioCaptureEnabled: Bool
    ) -> Bool {
        experimentalDirectAudioCaptureEnabled == false
    }

    static func shouldRecoverEngineConfigurationChange(
        isRunning: Bool,
        isStarting: Bool
    ) -> Bool {
        isRunning || isStarting
    }
}

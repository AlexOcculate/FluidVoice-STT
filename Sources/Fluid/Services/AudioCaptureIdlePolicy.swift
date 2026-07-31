enum AudioCaptureIdlePolicy {
    static func shouldPrewarmCapture(experimentalDirectAudioCaptureEnabled: Bool) -> Bool {
        experimentalDirectAudioCaptureEnabled
    }

    static func shouldRecoverEngineConfigurationChange(
        isRunning: Bool,
        isStarting: Bool
    ) -> Bool {
        isRunning || isStarting
    }
}

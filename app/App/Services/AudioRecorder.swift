import AVFoundation
import Foundation

@MainActor final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var hasAudibleSamples = false
    private var meterTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    var onInterruption: (() -> Void)?
    var onLevel: ((Double) -> Void)?
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "NutritionTrackerAudio", isDirectory: true)
    }
    static func cleanOrphans() { try? FileManager.default.removeItem(at: directory) }
    func start() async throws {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw AudioError.permission }
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true)
            let url = Self.directory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(
                    "wav")
            fileURL = url
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ])
            self.recorder = recorder
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            hasAudibleSamples = false
            guard recorder.record(forDuration: 300) else { throw AudioError.recording }
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onInterruption?() }
            }
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    if recorder.peakPower(forChannel: 0) > -55 { self.hasAudibleSamples = true }
                    self.onLevel?(
                        min(1, max(0, pow(10, Double(recorder.averagePower(forChannel: 0)) / 35))))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            cleanup()
            throw error
        }
    }
    func stop() throws -> Data {
        guard let recorder, let url = fileURL else { throw AudioError.recording }
        recorder.updateMeters()
        hasAudibleSamples = hasAudibleSamples || recorder.peakPower(forChannel: 0) > -55
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard hasAudibleSamples else {
            cleanup()
            throw AudioError.silent
        }
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else {
                cleanup()
                throw AudioError.silent
            }
            return data
        } catch {
            cleanup()
            throw error
        }
    }
    func cleanup() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        onLevel?(0)
    }
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in self?.onInterruption?() }
    }
    enum AudioError: Error { case permission, silent, recording }
}

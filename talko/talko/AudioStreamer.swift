import AVFoundation

final class AudioStreamer: NSObject {
    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?

    var onAudioBuffer: ((String) -> Void)?

    func start(preserveCurrentSession: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        if !preserveCurrentSession {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        try session.setPreferredSampleRate(16000)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("AudioStreamer input format:", inputFormat.sampleRate, inputFormat.channelCount)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioStreamer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)"]
            )
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioStreamer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create target format"])
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        let bufferSize: AVAudioFrameCount = 1024

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            if buffer.frameLength == 0 { return }
            guard buffer.format.sampleRate > 0, targetFormat.sampleRate > 0 else { return }

            let outputFrames = ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
            let capacity = max(1, AVAudioFrameCount(outputFrames))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || error != nil { return }
            if converted.frameLength == 0 { return }
            guard let ch = converted.floatChannelData else { return }

            let frames = Int(converted.frameLength)
            let len = frames * MemoryLayout<Int16>.size
            var data = Data(count: len)
            data.withUnsafeMutableBytes { rawBuffer in
                let out = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<frames {
                    let sample = max(-1.0 as Float, min(1.0 as Float, ch[0][i]))
                    let scaled = Int16(max(-32768, min(32767, Int((Double(sample) * 32767.0).rounded()))))
                    out[i] = scaled.littleEndian
                }
            }
            self.onAudioBuffer?(data.base64EncodedString())
        }

        try audioEngine.start()
        print("AudioStreamer started")
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // 不在这里 setActive(false)，避免打断系统其他音频（TTS）
    }
}

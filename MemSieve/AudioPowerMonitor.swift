import AVFoundation
import Combine

class AudioPowerMonitor: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var recentLevels: [Float] = []
    private let smoothingCount = 5
    
    @Published var currentPower: Float = -160.0
    @Published var smoothedPower: Float = -160.0
    
    struct Config {
        let threshold: Float       // in dB (e.g., -50.0)
        let minDuration: Double    // in seconds (e.g., 0.5)
    }
    
    private let config: Config
    private var silenceStartTime: TimeInterval?
    var onSilenceDetected: ((TimeInterval, TimeInterval) -> Void)?
    
    init(config: Config = Config(threshold: -50.0, minDuration: 0.5)) {
        self.config = config
        self.inputNode = audioEngine.inputNode
        setupMonitoring()
    }
    
    private func setupMonitoring() {
        let bufferSize: AVAudioFrameCount = 1024
        
        // Get the current session's sample rate
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate
        
        // Create a valid format for the tap using the session's sample rate
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        
        print("🎤 Setting up audio monitoring with sample rate: \(sampleRate) Hz")
        
        inputNode.installTap(onBus: 0,
                           bufferSize: bufferSize,
                           format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            let power = self.calculatePower(buffer)
            let timeInterval = TimeInterval(time.sampleTime) / TimeInterval(time.sampleRate)
            DispatchQueue.main.async {
                self.processPowerLevel(power, at: timeInterval)
            }
        }
    }
    
    private func calculatePower(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -160.0 }
        
        var rms: Float = 0.0
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        
        // Calculate Root Mean Square (RMS) power
        for channel in 0..<channelCount {
            for sample in 0..<length {
                let value = channelData[channel][sample]
                rms += value * value
            }
        }
        
        rms = sqrt(rms / Float(channelCount * length))
        
        // Convert to decibels
        return max(20.0 * log10(rms), -160.0)
    }
    
    private func smoothPowerLevel(_ power: Float) -> Float {
        recentLevels.append(power)
        if recentLevels.count > smoothingCount {
            recentLevels.removeFirst()
        }
        return recentLevels.reduce(0, +) / Float(recentLevels.count)
    }
    
    private func processPowerLevel(_ power: Float, at time: TimeInterval) {
        currentPower = power
        smoothedPower = smoothPowerLevel(power)
        
        // Silence detection
        if power < config.threshold {
            if silenceStartTime == nil {
                silenceStartTime = time
            } else if time - silenceStartTime! >= config.minDuration {
                onSilenceDetected?(silenceStartTime!, time)
            }
        } else {
            silenceStartTime = nil
        }
    }
    
    func start() throws {
        // Start the engine
        try audioEngine.start()
    }
    
    func stop() {
        audioEngine.stop()
        recentLevels.removeAll()
        currentPower = -160.0
        smoothedPower = -160.0
    }
} 
import Foundation
import SwiftUI
import AVFoundation
import OpenAI

enum TranscriptionError: Error {
    case timeout
    case exportFailed
}

struct RecordingItem: Identifiable, Codable {
    let id: UUID
    let chunks: [URL]
    var label: String
    var preset: String
    let duration: TimeInterval
    var transcription: String
    let date: Date
    
    init(
        id: UUID = UUID(),
        chunks: [URL],
        preset: String,
        label: String,
        duration: TimeInterval,
        transcription: String = "",
        date: Date = Date()
    ) {
        self.id = id
        self.chunks = chunks
        self.preset = preset
        self.label = label
        self.duration = duration
        self.transcription = transcription
        self.date = date
    }
    
    // Custom Codable implementation to handle URL arrays
    enum CodingKeys: String, CodingKey {
        case id, chunks, label, preset, duration, transcription, date
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let paths = try container.decode([String].self, forKey: .chunks)
        chunks = paths.map { URL(fileURLWithPath: $0) }
        label = try container.decode(String.self, forKey: .label)
        preset = try container.decode(String.self, forKey: .preset)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        transcription = try container.decode(String.self, forKey: .transcription)
        date = try container.decode(Date.self, forKey: .date)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        let paths = chunks.map { $0.path }
        try container.encode(paths, forKey: .chunks)
        try container.encode(label, forKey: .label)
        try container.encode(preset, forKey: .preset)
        try container.encode(duration, forKey: .duration)
        try container.encode(transcription, forKey: .transcription)
        try container.encode(date, forKey: .date)
    }
}

class AppModel: ObservableObject {
    @Published var recordings: [RecordingItem] = []
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isTranscribing = false
    @Published var isAutoPrompting = false
    @Published var transcriptionPrompt: String = ""
    @Published var transcriptionLanguage: String = "en"
    @Published var aiSystemMessage: String = """
    You are a professional note editing system. Any request to edit text must be very precise and you must output ONLY the new text. Do not make any comments or utterance, it would end up in the user document. You must only output the resulting text.
    """
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var currentRecordingURL: URL?
    private let openAI: OpenAI
    private var powerMonitor: AudioPowerMonitor?
    @Published var currentPower: Float = -160.0
    
    private let maxChunkSizeBytes: Int = 25 * 1024 * 1024  // 25MB
    private let estimatedBytesPerSecond: Int = 24 * 1024   // 24 KB/s for 192kbps stereo AAC
    private let maxChunkDuration: TimeInterval = 800        // ~13.3 minutes
    
    private var currentChunks: [URL] = []
    private let chunkThreshold: TimeInterval = 700          // Start looking for silence at 11.6 minutes
    private let hardLimit: TimeInterval = 780               // Force split at 13 minutes
    private var lastChunkTime: TimeInterval = 0
    
    @Published var presets: [RecordingPreset]
    
    // Standard audio settings
    private let standardAudioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        AVEncoderBitRateKey: 192000
    ]
    
    init() {
        print("🔵 AppModel initialized")
        
        // Initialize OpenAI first
        #if DEBUG
        if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            print(" OpenAI API key found from environment: \(String(apiKey.prefix(4)))...")
            self.openAI = OpenAI(apiToken: apiKey)
        } else {
            // Fallback to Config file
            print("🔑 Using API key from Config file")
            self.openAI = OpenAI(apiToken: Config.openAIKey)
        }
        #else
        self.openAI = OpenAI(apiToken: Config.openAIKey)
        #endif
        
        // Initialize presets from UserDefaults or use defaults
        if let data = UserDefaults.standard.data(forKey: "presets"),
           let savedPresets = try? JSONDecoder().decode([RecordingPreset].self, from: data) {
            self.presets = savedPresets
        } else {
            self.presets = RecordingPreset.presets
        }
        
        // Set default transcription prompt from default preset
        self.transcriptionPrompt = presets.first { $0.id == "default" }?.transcriptionPrompt ?? RecordingPreset.defaultTranscriptionPrompt
        
        // Now that all stored properties are initialized, we can call methods
        setupAudioSession()
        
        // Load saved recordings
        loadRecordings()
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)  // Activate first
            
            // Explicitly set 44.1kHz for Whisper compatibility
            try session.setPreferredSampleRate(44100)
            try session.setPreferredIOBufferDuration(0.005) // 5ms buffer
            
            print("📊 Hardware sample rate: \(session.sampleRate)")
            print("✅ Audio session configured successfully")
            print("📊 Final sample rate: \(session.sampleRate), IO buffer duration: \(session.ioBufferDuration)")
        } catch {
            print("❌ Failed to set up audio session: \(error)")
            print("🔍 Detailed error: \(error.localizedDescription)")
        }
    }
    
    func startRecording(preset: String) {
        print("🎤 Starting recording with preset: \(preset)")
        
        // Get the current audio session without reconfiguring
        let session = AVAudioSession.sharedInstance()
        
        currentChunks = []
        lastChunkTime = 0
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("\(Date().timeIntervalSince1970).m4a")
        currentRecordingURL = audioFilename
        print("📁 Recording to file: \(audioFilename)")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,  // Explicitly set 44.1kHz
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 192000
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            isRecording = true
            recordingDuration = 0
            print("✅ Recording started with sample rate: \(session.sampleRate)")
            
            // Setup power monitoring after recorder is initialized
            setupPowerMonitoring()
            
            // Start timer to update duration
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.recordingDuration += 1
                self?.checkForChunking()
            }
        } catch {
            print("❌ Could not start recording: \(error)")
            print("🔍 Error details: \(error.localizedDescription)")
        }
    }
    
    private func setupPowerMonitoring() {
        powerMonitor = AudioPowerMonitor(config: .init(threshold: -50.0, minDuration: 0.5))
        powerMonitor?.onSilenceDetected = { [weak self] start, end in
            guard let self = self else { return }
            print("Silence detected from \(start) to \(end)")
            
            if self.recordingDuration >= self.chunkThreshold {
                self.startNewChunk()
            }
        }
        
        do {
            try powerMonitor?.start()
            powerMonitor?.$smoothedPower
                .receive(on: DispatchQueue.main)
                .assign(to: &$currentPower)
        } catch {
            print("❌ Failed to start power monitoring: \(error)")
        }
    }
    
    private func stopRecording() -> URL {
        print("📼 Stopping recording...")
        audioRecorder?.stop()
        
        // Properly invalidate and nil the timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        guard let url = currentRecordingURL else {
            fatalError("Recording URL not set")
        }
        
        currentRecordingURL = nil
        return url
    }
    
    func stopRecordingTemporarily() {
        print("📼 Stopping recording temporarily...")
        powerMonitor?.stop()
        powerMonitor = nil
        
        // Stop the current chunk and add it to chunks
        audioRecorder?.stop()
        if let url = currentRecordingURL {
            currentChunks.append(url)
        }
        
        // Properly invalidate and nil the timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // Update state but keep the chunks
        isRecording = false
        currentRecordingURL = nil
        audioRecorder = nil
    }
    
    func stopRecordingAndAddItem(preset: String, label: String) {
        // Since we already stopped recording, just create the recording item
        let newRecording = RecordingItem(
            chunks: currentChunks,
            preset: preset,
            label: label,
            duration: recordingDuration
        )
        
        // Insert at the beginning of the array
        recordings.insert(newRecording, at: 0)
        
        // Reset recording state
        recordingDuration = 0
        currentChunks = []
        
        // Save recordings to persistent storage
        saveRecordings()
    }
    
    func deleteRecording(_ recording: RecordingItem) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            // Delete all chunks
            for chunk in recording.chunks {
                try? FileManager.default.removeItem(at: chunk)
            }
            
            // Remove from array
            recordings.remove(at: index)
            
            // Notify observers of the change
            objectWillChange.send()
            
            // Save changes
            saveRecordings()
            
            print("✅ Recording deleted: \(recording.id)")
        }
    }
    
    func deleteAllRecordings() {
        // Create a copy of the array to avoid modification during iteration
        let recordingsToDelete = recordings
        
        // Clear the main array first
        recordings.removeAll()
        
        // Delete all files
        for recording in recordingsToDelete {
            for chunk in recording.chunks {
                try? FileManager.default.removeItem(at: chunk)
            }
        }
        
        // Notify observers of the change
        objectWillChange.send()
        
        // Save changes
        saveRecordings()
    }
    
    func transcribeAudio(fileURL: URL) async throws -> String {
        print("🎯 Starting transcription of file: \(fileURL.lastPathComponent)")
        let audioData = try Data(contentsOf: fileURL)
        print("📊 Audio data size: \(audioData.count) bytes")
        
        let query = AudioTranscriptionQuery(
            file: audioData,
            fileType: .m4a,
            model: .whisper_1,
            prompt: transcriptionPrompt.isEmpty ? nil : transcriptionPrompt,
            temperature: 0.2,
            language: transcriptionLanguage
        )
        
        print("🚀 Sending request to OpenAI with:")
        print("🔤 Language: \(transcriptionLanguage)")
        print("💭 Prompt: \(transcriptionPrompt)")
        
        do {
            let result = try await openAI.audioTranscriptions(query: query)
            print("✅ Received transcription result: '\(result.text)'")
            return result.text
        } catch {
            print("❌ OpenAI API error: \(error)")
            print("❌ Detailed error: \(String(describing: error))")
            throw error
        }
    }
    
    func transcribeRecording(_ recording: RecordingItem) async {
        print("🎯 Starting transcription for recording: \(recording.id)")
        
        await MainActor.run {
            isTranscribing = true
        }
        
        defer {
            Task { @MainActor in
                isTranscribing = false
            }
        }
        
        guard !recording.chunks.isEmpty else {
            print("⚠️ No chunks found for transcription")
            return
        }
        
        print("📝 Current transcription: '\(recording.transcription)'")
        print("🔄 Processing \(recording.chunks.count) chunks")
        
        do {
            // Create a task for transcription with timeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Add the transcription task
                group.addTask {
                    var transcriptions: [String] = []
                    
                    // Process chunks concurrently
                    try await withThrowingTaskGroup(of: String.self) { chunksGroup in
                        for chunk in recording.chunks {
                            chunksGroup.addTask {
                                print("🔄 Processing chunk at: \(chunk)")
                                let audioData = try Data(contentsOf: chunk)
                                print("📊 Audio data size: \(audioData.count) bytes")
                                
                                let query = AudioTranscriptionQuery(
                                    file: audioData,
                                    fileType: .m4a,
                                    model: .whisper_1,
                                    prompt: self.transcriptionPrompt.isEmpty ? nil : self.transcriptionPrompt,
                                    temperature: 0.2,
                                    language: self.transcriptionLanguage
                                )
                                
                                let result = try await self.openAI.audioTranscriptions(query: query)
                                print("✅ Received raw transcription: '\(result.text)'")
                                return result.text
                            }
                        }
                        
                        // Collect results in order
                        for try await result in chunksGroup {
                            print("🔄 Adding chunk result: '\(result)'")
                            transcriptions.append(result)
                        }
                    }
                    
                    // Combine transcriptions
                    let fullTranscription = transcriptions.joined(separator: "\n\n")
                    
                    // Update recording on main actor
                    await MainActor.run {
                        if let index = self.recordings.firstIndex(where: { $0.id == recording.id }) {
                            self.recordings[index].transcription = fullTranscription
                            self.objectWillChange.send()
                            self.saveRecordings()
                            print("✅ Successfully updated transcription")
                        }
                    }
                }
                
                // Add a timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(120 * 1_000_000_000)) // 120 seconds = 2 minutes
                    throw TranscriptionError.timeout
                }
                
                // Wait for first task to complete or timeout
                try await group.next()
                group.cancelAll() // Cancel remaining tasks
            }
        } catch {
            print("❌ Transcription process failed: \(error)")
            
            // Handle timeout or other errors by setting empty transcription
            await MainActor.run {
                if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
                    recordings[index].transcription = ""
                    objectWillChange.send()
                    saveRecordings()
                    print("⏱️ Transcription timed out or failed - saved empty transcription")
                }
            }
        }
    }
    
    func chatCompletion(query: ChatQuery) async throws -> String {
        print("🎯 Starting chat completion")
        print("🚀 Sending request to OpenAI API")
        
        let result = try await openAI.chats(query: query)
        if case .string(let content) = result.choices.first?.message.content {
            print("✅ Received response: \(content)")
            return content
        }
        return ""
    }
    
    private func loadRecordings() {
        // Load recordings from persistent storage
        if let data = UserDefaults.standard.data(forKey: "recordings"),
           let decodedRecordings = try? JSONDecoder().decode([RecordingItem].self, from: data) {
            self.recordings = decodedRecordings
        }
    }
    
    private func saveRecordings() {
        // Save recordings to persistent storage
        if let encoded = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(encoded, forKey: "recordings")
        }
    }
    
    private func shouldStartNewChunk(currentDuration: TimeInterval) -> Bool {
        return currentDuration >= maxChunkDuration
    }
    
    private func startNewChunk() {
        // If we're already recording, stop the current chunk
        if let currentRecorder = audioRecorder {
            currentRecorder.stop()
            if let url = currentRecordingURL {
                currentChunks.append(url)
            }
        }
        
        // Start a new chunk
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Date().timeIntervalSince1970
        let audioFilename = documentsPath.appendingPathComponent("\(timestamp)_chunk\(currentChunks.count + 1).m4a")
        currentRecordingURL = audioFilename
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,  // Explicitly set 44.1kHz
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 192000
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            lastChunkTime = recordingDuration
            print("📼 Started new chunk at \(audioFilename)")
        } catch {
            print("❌ Failed to start new chunk: \(error)")
        }
    }
    
    private func checkForChunking() {
        let chunkDuration = recordingDuration - lastChunkTime
        if chunkDuration >= hardLimit {
            print("⚠️ Reached hard limit, forcing chunk split")
            startNewChunk()
        }
    }
    
    func applyAutoPrompt(to recording: RecordingItem, prompt: String) async {
        print("🎯 Starting auto-prompt formatting for recording: \(recording.id)")
        
        await MainActor.run {
            isAutoPrompting = true
        }
        
        defer {
            Task { @MainActor in
                print("🔄 Setting isAutoPrompting to false")
                isAutoPrompting = false
            }
        }
        
        // Get the latest transcription from the recordings array
        guard let currentRecording = recordings.first(where: { $0.id == recording.id }),
              !currentRecording.transcription.isEmpty else {
            print("⚠️ No transcription found for recording")
            return
        }
        
        print("📝 Original text length: \(currentRecording.transcription.count) characters")
        print("📝 Original text: '\(currentRecording.transcription)'")
        print("💭 Auto-prompt: \(prompt)")
        
        do {
            print("🚀 Creating chat completion query")
            let query = ChatQuery(
                messages: [
                    ChatQuery.ChatCompletionMessageParam(role: .system, content: prompt)!,
                    ChatQuery.ChatCompletionMessageParam(role: .user, content: currentRecording.transcription)!
                ],
                model: .gpt4_o
            )
            
            print("⏳ Waiting for formatted response...")
            let formattedText = try await chatCompletion(query: query)
            print("✅ Received formatted text (\(formattedText.count) characters)")
            print("📝 Formatted text: '\(formattedText)'")
            
            await MainActor.run {
                if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
                    print("📝 Updating recording transcription")
                    recordings[index].transcription = formattedText
                    objectWillChange.send()
                    saveRecordings()
                    print("💾 Changes saved")
                } else {
                    print("❌ Failed to find recording with id: \(recording.id)")
                }
            }
            
            print("🔄 Auto-prompt formatting completed successfully")
        } catch {
            print("❌ Failed to apply auto-prompt: \(error)")
            print("🔍 Error details: \(error.localizedDescription)")
        }
    }
    
    func updatePreset(_ preset: RecordingPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            // Save presets
            if let encoded = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.set(encoded, forKey: "presets")
            }
        }
    }
    
    func transcriptionPromptFor(presetId: String) -> String {
        presets.first { $0.id == presetId }?.transcriptionPrompt ?? RecordingPreset.defaultTranscriptionPrompt
    }
    
    func importAudioFile(_ url: URL, preset: RecordingPreset) async throws -> RecordingItem {
        print("🎯 Starting audio file import")
        
        do {
            // Create a temporary directory for chunks
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let importDirectory = documentsPath.appendingPathComponent("import_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
            print("📁 Created import directory: \(importDirectory)")
            
            // Load the audio file
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationInSeconds = CMTimeGetSeconds(duration)
            print("⏱️ Audio duration: \(durationInSeconds)s")
            
            // Split into chunks based on power
            let chunks = try await splitImportedAudioIntoPowerBasedChunks(
                asset: asset,
                outputDirectory: importDirectory
            )
            print("✂️ Split into \(chunks.count) chunks")
            
            // Create a new recording item with temporary label
            let newRecording = RecordingItem(
                chunks: chunks,
                preset: preset.id,
                label: "Imported Recording",
                duration: durationInSeconds
            )
            
            await MainActor.run {
                print("📝 Adding new recording to list")
                recordings.insert(newRecording, at: 0)
                objectWillChange.send()
                saveRecordings()
            }
            
            // Start transcription immediately after import
            await transcribeRecording(newRecording)
            
            print("🎯 Import completed successfully")
            
            return newRecording
            
        } catch {
            print("❌ Failed to import audio: \(error)")
            print("🔍 Error details: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func splitImportedAudioIntoPowerBasedChunks(asset: AVAsset, outputDirectory: URL) async throws -> [URL] {
        print("🎯 Starting audio splitting")
        
        // Calculate duration
        let duration = try await asset.load(.duration)
        
        var chunks: [URL] = []
        var currentStartTime = CMTime.zero
        let chunkDuration = CMTime(seconds: maxChunkDuration, preferredTimescale: 600)
        
        while currentStartTime < duration {
            let currentEndTime = CMTimeAdd(currentStartTime, chunkDuration)
            let actualEndTime = CMTimeMinimum(currentEndTime, duration)
            
            // Create timeRange for this chunk
            let timeRange = CMTimeRangeFromTimeToTime(start: currentStartTime, end: actualEndTime)
            
            // Create export session for this chunk
            let chunkURL = outputDirectory.appendingPathComponent("\(Date().timeIntervalSince1970)_chunk\(chunks.count + 1).m4a")
            
            // Create and configure export session
            if let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
                exportSession.outputURL = chunkURL
                exportSession.outputFileType = .m4a
                exportSession.timeRange = timeRange
                
                // Set audio settings to match our standard format
                let audioMix = AVMutableAudioMix()
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                let audioMixInput = AVMutableAudioMixInputParameters(track: audioTrack)
                audioMixInput.trackID = audioTrack?.trackID ?? kCMPersistentTrackID_Invalid
                audioMix.inputParameters = [audioMixInput]
                exportSession.audioMix = audioMix
                
                // Use new async/await export API
                do {
                    try await exportSession.export(to: chunkURL, as: .m4a)
                    chunks.append(chunkURL)
                    print("✅ Created chunk \(chunks.count): \(chunkURL)")
                } catch {
                    print("❌ Export failed for chunk: \(error)")
                    throw TranscriptionError.exportFailed
                }
            }
            
            // Move to next chunk
            currentStartTime = actualEndTime
        }
        
        print("✅ Created \(chunks.count) chunks")
        return chunks
    }
    
    func updateRecordingPreset(_ recording: RecordingItem, newPreset: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].preset = newPreset
            objectWillChange.send()
            saveRecordings()
        }
    }
    
    func handleIncomingURL(_ url: URL) {
        print("🔗 Handling incoming URL: \(url)")
        
        // Create a copy of the file in our app's document directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent("imported_\(Date().timeIntervalSince1970).\(url.pathExtension)")
        
        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
            print("✅ File copied to: \(destinationURL)")
            
            // Use the default preset for imports
            guard let defaultPreset = presets.first(where: { $0.id == "default" }) else {
                print("❌ Default preset not found")
                return
            }
            
            // Import the file and handle potential errors
            Task { @MainActor in
                do {
                    let _ = try await importAudioFile(destinationURL, preset: defaultPreset)
                    print("✅ File imported successfully")
                } catch {
                    print("❌ Failed to import audio file: \(error)")
                    print("🔍 Error details: \(error.localizedDescription)")
                }
            }
        } catch {
            print("❌ Failed to copy incoming file: \(error)")
        }
    }
    
    func updateRecordingLabel(id: UUID, newLabel: String) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].label = newLabel
        }
    }
} 
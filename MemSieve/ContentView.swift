//
//  ContentView.swift
//  MemSieve
//
//  Created by Jan Siml on 07/12/2024.
//

import SwiftUI
import AVFoundation
import OpenAI

extension UTType {
    static let wav = UTType(filenameExtension: "wav")!
    static let m4a = UTType(filenameExtension: "m4a")!
}

struct RecordingPreset: Codable {
    let id: String
    let name: String
    let autoPrompt: String?
    var transcriptionPrompt: String
    
    static let defaultTranscriptionPrompt = "I am Jan Šiml, my wife is Ann. I live in London, UK and like GenAI applications."
    
    static let presets = [
        RecordingPreset(
            id: "default",
            name: "Default",
            autoPrompt: nil,
            transcriptionPrompt: defaultTranscriptionPrompt
        ),
        RecordingPreset(
            id: "bullets",
            name: "Bullet Points",
            autoPrompt: """
            You will be provided a transcript based on an audio recording. 
            Your task is to transform the transcript by removing any utterances, fixing transcription errors, adding punctuation, and formatting it into sections and bullet-points inside those sections. 
            If it is already formatted, just return the original text. 
            You MUST NOT change any of the content or add any new content. You are purely transforming the form and improving the quality.
            """,
            transcriptionPrompt: defaultTranscriptionPrompt
        ),
        RecordingPreset(
            id: "thoughts",
            name: "Thoughts",
            autoPrompt: """
            You will be provided a transcript based on an audio recording.
            Your task is to transform the transcript by removing any utterances, fixing transcription errors, adding punctuation, and formatting it into clear sections with headings and paragraphs. 
            If it is already formatted, just return the original text. 
            You MUST NOT change any of the content or add any new content. You are purely transforming the form and improving the quality.
            """,
            transcriptionPrompt: defaultTranscriptionPrompt
        )
    ]
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    
    var body: some View {
        TabView {
            DictateView()
                .tabItem {
                    Label("Dictate", systemImage: "mic.fill")
                }
            
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

struct DictateView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedPresetId = "default"
    @State private var showLabelSheet = false
    @State private var labelText = ""
    @State private var showImportPicker = false
    
    var selectedPreset: RecordingPreset {
        RecordingPreset.presets.first { $0.id == selectedPresetId } ?? RecordingPreset.presets[0]
    }
    
    var formattedDuration: String {
        let duration = Int(model.recordingDuration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var formattedPower: String {
        String(format: "%.1f dB", model.currentPower)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Picker("Preset", selection: $selectedPresetId) {
                    ForEach(RecordingPreset.presets, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                HStack {
                    Text(formattedDuration)
                        .font(.system(size: 54, weight: .light, design: .monospaced))
                    if model.isRecording {
                        Text(formattedPower)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                
                Button(action: {
                    if model.isRecording {
                        model.stopRecordingTemporarily()
                        showLabelSheet = true
                    } else {
                        model.startRecording(preset: selectedPreset.name)
                    }
                }) {
                    Circle()
                        .fill(model.isRecording ? Color.red : Color.blue)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                        )
                }
                .padding(.vertical, 40)
                
                if let latestRecording = model.recordings.first {
                    NavigationLink(destination: RecordingDetailView(recording: latestRecording)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest Recording")
                                .font(.headline)
                            Text(latestRecording.label)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(UIColor.systemGray6))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .alert("Enter Recording Label", isPresented: $showLabelSheet) {
                TextField("Label", text: $labelText)
                Button("Cancel", role: .cancel) {
                    labelText = ""
                }
                Button("Save") {
                    print("🎯 Stopping recording with preset: \(selectedPreset.name)")
                    model.stopRecordingAndAddItem(preset: selectedPreset.id, label: labelText)
                    
                    if let latestRecording = model.recordings.first {
                        Task {
                            // Set transcription prompt for this recording
                            let transcriptionPrompt = model.transcriptionPromptFor(presetId: selectedPresetId)
                            print("📝 Using transcription prompt: \(transcriptionPrompt)")
                            model.transcriptionPrompt = transcriptionPrompt
                            
                            // First, transcribe the recording
                            print("🎙️ Starting transcription for recording: \(latestRecording.id)")
                            await model.transcribeRecording(latestRecording)
                            print("✅ Transcription completed")
                            
                            // Then, if it's not Default preset and has an auto-prompt, apply it
                            if selectedPreset.id != "default", let autoPrompt = selectedPreset.autoPrompt {
                                print("🤖 Found auto-prompt for preset \(selectedPreset.name)")
                                print("💭 Auto-prompt: \(autoPrompt)")
                                await model.applyAutoPrompt(to: latestRecording, prompt: autoPrompt)
                                print("✅ Auto-prompt formatting completed")
                            } else {
                                print("ℹ️ No auto-prompt to apply (Default preset or nil auto-prompt)")
                            }
                        }
                    }
                    labelText = ""
                }
            } message: {
                Text("Give your recording a descriptive label")
            }
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.wav, .m4a, .audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    
                    // Start security-scoped resource access
                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access the file")
                        return
                    }
                    
                    defer { url.stopAccessingSecurityScopedResource() }
                    
                    Task {
                        do {
                            // First import the file and wait for it to complete
                            let importedRecording = try await model.importAudioFile(url, preset: selectedPreset)
                            print("📥 Successfully imported audio file with ID: \(importedRecording.id)")
                            
                            // Show the label sheet immediately after successful import
                            await MainActor.run {
                                labelText = url.deletingPathExtension().lastPathComponent
                                showLabelSheet = true
                            }
                            
                            // Set transcription prompt
                            let transcriptionPrompt = model.transcriptionPromptFor(presetId: selectedPresetId)
                            print("📝 Using transcription prompt: \(transcriptionPrompt)")
                            model.transcriptionPrompt = transcriptionPrompt
                            
                            // Start transcription
                            print("🎙️ Starting transcription for imported recording")
                            await model.transcribeRecording(importedRecording)
                            print("✅ Transcription completed")
                            
                            // Apply auto-prompt if needed
                            if selectedPreset.id != "default", let autoPrompt = selectedPreset.autoPrompt {
                                print("🤖 Found auto-prompt for preset \(selectedPreset.name)")
                                print("💭 Auto-prompt: \(autoPrompt)")
                                await model.applyAutoPrompt(to: importedRecording, prompt: autoPrompt)
                                print("✅ Auto-prompt formatting completed")
                            }
                        } catch {
                            print("❌ Error during import process: \(error)")
                        }
                    }
                    
                case .failure(let error):
                    print("❌ Import failed: \(error)")
                }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var sortByTitle = false
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    
    var filteredRecordings: [RecordingItem] {
        let filtered = model.recordings.filter { recording in
            searchText.isEmpty || 
            recording.label.localizedCaseInsensitiveContains(searchText) ||
            recording.preset.localizedCaseInsensitiveContains(searchText)
        }
        
        return filtered.sorted { (first: RecordingItem, second: RecordingItem) in
            if sortByTitle {
                return first.label.localizedCaseInsensitiveCompare(second.label) == .orderedAscending
            } else {
                return first.date > second.date
            }
        }
    }
    
    private func deleteAllRecordings() {
        model.deleteAllRecordings()
        isEditing = false
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(filteredRecordings) { recording in
                    NavigationLink(destination: RecordingDetailView(recording: recording)) {
                        RecordingRow(recording: recording)
                    }
                }
                .onDelete { indexSet in
                    let recordingsToDelete = indexSet.map { filteredRecordings[$0] }
                    for recording in recordingsToDelete {
                        model.deleteRecording(recording)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search recordings")
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.recordings.isEmpty {
                        Button(isEditing ? "Done" : "Edit") {
                            isEditing.toggle()
                        }
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if isEditing {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Text("Delete All")
                                    .foregroundColor(.red)
                            }
                        }
                        
                        Button(action: { sortByTitle.toggle() }) {
                            Label(
                                sortByTitle ? "Sort by Date" : "Sort by Title",
                                systemImage: sortByTitle ? "calendar" : "textformat"
                            )
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .alert("Delete All Recordings", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All", role: .destructive) {
                    deleteAllRecordings()
                }
            } message: {
                Text("Are you sure you want to delete all recordings? This action cannot be undone.")
            }
        }
    }
}

struct RecordingRow: View {
    let recording: RecordingItem
    
    var formattedDuration: String {
        let duration = Int(recording.duration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recording.label)
                .font(.headline)
            
            HStack {
                Text(recording.preset)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(recording.date, style: .date)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text(formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

func concatenateAudioFiles(from urls: [URL], to outputURL: URL) async throws {
    let composition = AVMutableComposition()
    let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    
    var currentTime = CMTime.zero
    
    for url in urls {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            try audioTrack?.insertTimeRange(timeRange, of: track, at: currentTime)
            currentTime = CMTimeAdd(currentTime, duration)
        }
    }
    
    // Export the composition
    if let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) {
        try await exportSession.export(to: outputURL, as: .m4a)
    }
}

struct TranscriptionControlsView: View {
    @EnvironmentObject var model: AppModel
    let recording: RecordingItem
    let localTranscription: String
    let isTranscribing: Bool
    let previousVersion: String?
    let nextVersion: String?
    let isAtOriginal: Bool
    let onAutoPrompt: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onShowPromptDialog: () -> Void
    
    var body: some View {
        HStack {
            if previousVersion != nil {
                Button(action: onUndo) {
                    Image(systemName: "arrow.backward")
                }
                .disabled(isAtOriginal)
                
                Button(action: onRedo) {
                    Image(systemName: "arrow.forward")
                }
                .disabled(nextVersion == nil || !isAtOriginal)
            }
            
            Spacer()
            
            if localTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: {
                    Task {
                        await model.transcribeRecording(recording)
                    }
                }) {
                    HStack(spacing: 4) {
                        if isTranscribing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text("Transcribe")
                        Image(systemName: "waveform")
                    }
                }
                .disabled(isTranscribing)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
            } else if let preset = model.presets.first(where: { $0.id == recording.preset }),
                      let _ = preset.autoPrompt {
                Button(action: onAutoPrompt) {
                    HStack(spacing: 4) {
                        if model.isAutoPrompting {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text("Auto Edit")
                        Image(systemName: "sparkles")
                    }
                }
                .disabled(model.isAutoPrompting)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
            }
            
            Button(action: {
                UIPasteboard.general.string = localTranscription
            }) {
                Image(systemName: "doc.on.doc")
            }
            .disabled(localTranscription.isEmpty)
            
            Button(action: onShowPromptDialog) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("AI Edit")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 1)
            )
        }
        .padding(.horizontal)
    }
}

// First, create a component for the header section
struct RecordingHeaderView: View {
    let recording: RecordingItem
    let onEditLabel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recording.label)
                    .font(.title)
                    .bold()
                
                Button(action: onEditLabel) {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(.accentColor)
                }
            }
            
            HStack {
                Text(recording.date, style: .date)
                Text(" • ")
                Text(recording.preset)
            }
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }
}

// Create a component for playback controls
struct PlaybackControlsView: View {
    let duration: String
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Text(duration)
                .font(.system(.title2, design: .monospaced))
                .foregroundColor(.secondary)
            
            Button(action: onTogglePlayback) {
                Circle()
                    .fill(isPlaying ? Color.red : Color.blue)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(15)
        .shadow(radius: 5)
        .padding(.horizontal)
    }
}

// Create a component for the transcription editor
struct TranscriptionEditorView: View {
    let isTranscribing: Bool
    @Binding var text: String
    let onSelectionChange: (String?, NSRange?) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .center) {
                CustomTextEditor(
                    text: $text,
                    onSelectionChange: onSelectionChange
                )
                .frame(minHeight: 200, maxHeight: .infinity)
                .padding(8)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
                
                if isTranscribing {
                    Color(UIColor.systemBackground)
                        .opacity(0.7)
                        .overlay(
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Transcribing...")
                                    .foregroundColor(.secondary)
                            }
                        )
                }
            }
        }
        .frame(minHeight: 200, maxHeight: .infinity)
    }
}

struct RecordingDetailView: View {
    @EnvironmentObject var model: AppModel
    let recording: RecordingItem
    @State private var localTranscription: String = ""
    @State private var isPlaying = false
    @State private var currentChunkIndex = 0
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playerDelegate: ChunkPlayerDelegate?
    @State private var isTranscribing = false
    @State private var showPromptDialog = false
    @State private var editPrompt = ""
    @State private var selectedText: String?
    @State private var selectedRange: NSRange?
    @State private var previousVersion: String?
    @State private var nextVersion: String?
    @State private var isAtOriginal = true
    @State private var isProcessing = false
    @State private var showShareSheet = false
    @State private var itemsToShare: [Any] = []
    @State private var isExporting = false
    @State private var previousVersions: [String] = []
    @State private var currentVersionIndex: Int = 0
    @State private var pollingTimer: Timer?
    @State private var showLabelSheet = false
    @State private var newLabel = ""
    @State private var showDeleteConfirmation = false
    @Environment(\.presentationMode) var presentationMode
    
    init(recording: RecordingItem) {
        self.recording = recording
        _localTranscription = State(initialValue: recording.transcription)
        _isProcessing = State(initialValue: recording.transcription.isEmpty)
    }
    
    private func handleAutoPrompt() {
        if let preset = model.presets.first(where: { $0.id == recording.preset }),
           let autoPrompt = preset.autoPrompt {
            Task {
                await model.applyAutoPrompt(to: recording, prompt: autoPrompt)
            }
        }
    }
    
    private func handleUndo() {
        nextVersion = localTranscription
        localTranscription = previousVersion!
        isAtOriginal = true
    }
    
    private func handleRedo() {
        if let next = nextVersion {
            previousVersion = localTranscription
            localTranscription = next
            isAtOriginal = false
        }
    }
    
    private func handleShowPromptDialog() {
        showPromptDialog = true
    }
    
    private func handleSelectionChange(text: String?, range: NSRange?) {
        print("🔍 Selection changed - text: \(text ?? "none")")
        Task { @MainActor in
            selectedText = text
            selectedRange = range
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            if isProcessing {
                // Show loading view when processing
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Processing recording...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Label and timestamp
                        RecordingHeaderView(recording: recording, onEditLabel: {
                            newLabel = recording.label
                            showLabelSheet = true
                        })
                        
                        // Playback controls
                        PlaybackControlsView(
                            duration: formattedDuration,
                            isPlaying: isPlaying,
                            onTogglePlayback: togglePlayback
                        )
                        
                        // Transcription
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Transcription")
                                    .font(.headline)
                                
                                if isTranscribing {
                                    ProgressView()
                                }
                                
                                Spacer()
                            }
                            
                            TranscriptionControlsView(
                                recording: recording,
                                localTranscription: localTranscription,
                                isTranscribing: isTranscribing,
                                previousVersion: previousVersion,
                                nextVersion: nextVersion,
                                isAtOriginal: isAtOriginal,
                                onAutoPrompt: handleAutoPrompt,
                                onUndo: handleUndo,
                                onRedo: handleRedo,
                                onShowPromptDialog: handleShowPromptDialog
                            )
                            
                            TranscriptionEditorView(
                                isTranscribing: isTranscribing,
                                text: $localTranscription,
                                onSelectionChange: handleSelectionChange
                            )
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
        }
        .onAppear {
            // Start polling when view appears
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if let updatedRecording = model.recordings.first(where: { $0.id == recording.id }) {
                    // Check if processing should end
                    if isProcessing && 
                       !model.isTranscribing && 
                       !model.isAutoPrompting && 
                       !updatedRecording.transcription.isEmpty {
                        isProcessing = false
                    }
                }
            }
        }
        .onDisappear {
            // Clean up timer when view disappears
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
        .onReceive(model.$recordings) { _ in
            if let updatedRecording = model.recordings.first(where: { $0.id == recording.id }) {
                print("📝 Updating local transcription from model")
                print("New transcription: \(updatedRecording.transcription)")
                localTranscription = updatedRecording.transcription
                
                checkProcessingState(transcription: updatedRecording.transcription)
            }
        }
        .onReceive(model.$isTranscribing) { isTranscribing in
            if isTranscribing {
                isProcessing = true
            } else {
                checkProcessingState(transcription: localTranscription)
            }
        }
        .onReceive(model.$isAutoPrompting) { isAutoPrompting in
            if isAutoPrompting {
                isProcessing = true
            } else {
                checkProcessingState(transcription: localTranscription)
            }
        }
        .alert("Enter AI Edit Prompt", isPresented: $showPromptDialog) {
            TextField("Enter your editing instructions", text: $editPrompt)
                .autocapitalization(.none)
            
            Button("Edit") {
                let promptText = editPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !promptText.isEmpty else { return }
                
                Task {
                    if let selectedText = selectedText, let range = selectedRange {
                        // Edit selected text only
                        print("✂️ Editing selected text: \(selectedText)")
                        await performAIEdit(text: selectedText, prompt: promptText, replaceAll: false)
                    } else {
                        // Edit all text
                        print("📝 Editing all text")
                        await performAIEdit(text: localTranscription, prompt: promptText, replaceAll: true)
                    }
                }
                editPrompt = ""
            }
            .disabled(editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            
            Button("Cancel", role: .cancel) {
                editPrompt = ""
            }
        } message: {
            Text("Enter your instructions for how the AI should edit the text")
        }
        .onDisappear {
            stopPlayback()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { 
                        Task {
                            await shareContent(shareAudio: false)
                        }
                    }) {
                        Label("Share Transcription", systemImage: "doc.text")
                    }
                    .disabled(localTranscription.isEmpty)
                    
                    Button(action: { 
                        Task {
                            await shareContent(shareAudio: true)
                        }
                    }) {
                        Label("Share Audio", systemImage: "waveform")
                    }
                    
                    Button(action: { 
                        Task {
                            await shareContent(shareAudio: true)
                        }
                    }) {
                        Label("Share Both", systemImage: "square.and.arrow.up")
                    }
                    .disabled(localTranscription.isEmpty)
                    
                    Divider()
                    
                    Button(role: .destructive, action: {
                        showDeleteConfirmation = true
                    }) {
                        Label("Delete Recording", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: itemsToShare)
        }
        .alert("Edit Label", isPresented: $showLabelSheet) {
            TextField("Label", text: $newLabel)
            Button("Cancel", role: .cancel) {
                newLabel = ""
            }
            Button("Save") {
                if !newLabel.isEmpty {
                    model.updateRecordingLabel(id: recording.id, newLabel: newLabel)
                }
                newLabel = ""
            }
        } message: {
            Text("Enter a new label for this recording")
        }
        .alert(isPresented: $showDeleteConfirmation) {
            deleteAlert
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    private func startPlayback() {
        guard currentChunkIndex < recording.chunks.count else {
            isPlaying = false
            currentChunkIndex = 0
            return
        }
        
        configureAudioSession()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recording.chunks[currentChunkIndex])
            playerDelegate = ChunkPlayerDelegate {
                currentChunkIndex += 1
                if currentChunkIndex < recording.chunks.count {
                    startPlayback()
                } else {
                    isPlaying = false
                    currentChunkIndex = 0
                }
            }
            audioPlayer?.delegate = playerDelegate
            audioPlayer?.play()
            isPlaying = true
        } catch {
            print("Failed to play recording chunk: \(error)")
            isPlaying = false
        }
    }
    
    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil // Clean up delegate reference
        isPlaying = false
        currentChunkIndex = 0
    }
    
    var formattedDuration: String {
        let duration = Int(recording.duration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func performAIEdit(text: String, prompt: String, replaceAll: Bool) async {
        await MainActor.run {
            isTranscribing = true
        }
        
        defer {
            Task { @MainActor in
                isTranscribing = false
            }
        }

        print("🎯 Starting AI Edit")
        print("📝 Text length: \(text.count) characters")
        print("💭 Prompt: \(prompt)")
        
        // Store current version as previous before making changes
        await MainActor.run {
            previousVersion = localTranscription
            nextVersion = nil  // Clear any stored next version
            isAtOriginal = false
        }
        
        let userMessage = """
        <PROVIDED TEXT>
        \(text.trimmingCharacters(in: .whitespacesAndNewlines))
        </PROVIDED TEXT>
        
        <USER REQUEST>
        \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        </USER REQUEST>
        """

        print("🤖 System Message:")
        print(model.aiSystemMessage)

        print("📨 User Message:")
        print(userMessage)
        
        let messages = [
            ChatQuery.ChatCompletionMessageParam(role: .system, content: model.aiSystemMessage)!,
            ChatQuery.ChatCompletionMessageParam(role: .user, content: userMessage)!
        ]
        
        let query = ChatQuery(
            messages: messages,
            model: .gpt4_o
        )
        
        do {
            if replaceAll {
                print("📚 Storing current version in history")
                previousVersions.append(localTranscription)
                currentVersionIndex = previousVersions.count
                
                print("🎯 Requesting AI edit for full text")
                let response = try await model.chatCompletion(query: query)
                print("✅ Received edited text: \(response)")
                await MainActor.run {
                    localTranscription = response
                }
            } else if let range = selectedRange {
                print("✂️ Handling partial text replacement")
                let nsString = NSString(string: localTranscription)
                let before = nsString.substring(to: range.location)
                let after = nsString.substring(from: range.location + range.length)
                
                print("🎯 Requesting AI edit for selected text")
                let response = try await model.chatCompletion(query: query)
                print("✅ Received edited text: \(response)")
                await MainActor.run {
                    localTranscription = before + response + after
                }
            }
        } catch {
            print("❌ Error during AI Edit: \(error)")
        }
    }
    
    private func shareContent(shareAudio: Bool = false) async {
        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }
        
        var items: [Any] = []
        
        // Add transcription text if available
        if !localTranscription.isEmpty {
            items.append(localTranscription)
        }
        
        // Add audio file if requested
        if shareAudio {
            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("m4a")
                
                try await concatenateAudioFiles(from: recording.chunks, to: tempURL)
                items.append(tempURL)
            } catch {
                print("Error exporting audio: \(error)")
            }
        }
        
        await MainActor.run {
            itemsToShare = items
            showShareSheet = true
        }
    }
    
    private func checkProcessingState(transcription: String) {
        print("🔍 Checking processing state:")
        print("- Transcription empty: \(transcription.isEmpty)")
        print("- Is transcribing: \(model.isTranscribing)")
        print("- Is auto prompting: \(model.isAutoPrompting)")
        
        Task { @MainActor in
            // Check if we have a valid recording and transcription
            if let updatedRecording = model.recordings.first(where: { $0.id == recording.id }) {
                localTranscription = updatedRecording.transcription
                
                if !updatedRecording.transcription.isEmpty && !model.isTranscribing && !model.isAutoPrompting {
                    print("✅ All conditions met - ending processing state")
                    isProcessing = false
                } else {
                    print("⏳ Still processing - waiting for conditions to be met")
                }
            }
        }
    }
    
    private var deleteAlert: Alert {
        Alert(
            title: Text("Delete Recording"),
            message: Text("Are you sure you want to delete this recording? This action cannot be undone."),
            primaryButton: .destructive(Text("Delete")) {
                model.deleteRecording(recording)
                presentationMode.wrappedValue.dismiss()
            },
            secondaryButton: .cancel()
        )
    }
}

class ChunkPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            onFinish()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    
    let languages = [
        ("en", "English"),
        ("cs", "Czech")
    ]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Preset Settings")) {
                    ForEach(model.presets, id: \.id) { preset in
                        NavigationLink(preset.name) {
                            PresetSettingsView(preset: preset)
                        }
                    }
                }
                .textCase(nil)
                
                Section(header: Text("Language")) {
                    Picker("Language", selection: $model.transcriptionLanguage) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                }
                .textCase(nil)
                
                Section(header: Text("AI Editor Settings")) {
                    Text("System Message")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextEditor(text: $model.aiSystemMessage)
                        .frame(height: 150)
                        .font(.body)
                        .padding(8)
                        .background(Color(UIColor.systemGray6))
                        .cornerRadius(8)
                }
                .textCase(nil)
            }
            .navigationTitle("Settings")
        }
    }
}

struct PresetSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) var presentationMode
    @State private var transcriptionPrompt: String
    let preset: RecordingPreset
    
    init(preset: RecordingPreset) {
        self.preset = preset
        _transcriptionPrompt = State(initialValue: preset.transcriptionPrompt)
    }
    
    var body: some View {
        Form {
            Section(header: Text("Transcription Prompt")) {
                TextEditor(text: $transcriptionPrompt)
                    .frame(height: 100)
                    .font(.body)
            }
            .textCase(nil)
            
            if let _ = preset.autoPrompt {
                Section(header: Text("Auto-Prompt (Read Only)")) {
                    Text(preset.autoPrompt ?? "")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .textCase(nil)
            }
            
            Button("Save") {
                let updatedPreset = RecordingPreset(
                    id: preset.id,
                    name: preset.name,
                    autoPrompt: preset.autoPrompt,
                    transcriptionPrompt: transcriptionPrompt
                )
                model.updatePreset(updatedPreset)
                presentationMode.wrappedValue.dismiss()
            }
        }
        .navigationTitle(preset.name)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}

struct CustomTextEditor: UIViewRepresentable {
    @Binding var text: String
    let onSelectionChange: (String?, NSRange?) -> Void
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = UIColor.systemGray6
        textView.delegate = context.coordinator
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSelectionChange: onSelectionChange)
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        let onSelectionChange: (String?, NSRange?) -> Void
        
        init(text: Binding<String>, onSelectionChange: @escaping (String?, NSRange?) -> Void) {
            _text = text
            self.onSelectionChange = onSelectionChange
            super.init()
        }
        
        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
        
        func textViewDidChangeSelection(_ textView: UITextView) {
            let selectedRange = textView.selectedRange
            if selectedRange.length > 0 {
                let selectedText = (textView.text as NSString).substring(with: selectedRange)
                Task { @MainActor in
                    onSelectionChange(selectedText, selectedRange)
                }
            } else {
                Task { @MainActor in
                    onSelectionChange(nil, nil)
                }
            }
        }
    }
}

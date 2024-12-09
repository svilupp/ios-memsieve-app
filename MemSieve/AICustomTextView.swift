import UIKit

class AICustomTextView: UITextView {
    var onAIEdit: ((String, NSRange) -> Void)?
    private var editMenuInteraction: UIEditMenuInteraction?
    private var longPressGesture: UILongPressGestureRecognizer?
    
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        print("📱 AICustomTextView initialized")
        setupInteractions()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        print("📱 AICustomTextView initialized from coder")
        setupInteractions()
    }
    
    private func setupInteractions() {
        print("🔄 Setting up interactions")
        
        // Basic setup
        isEditable = true
        isSelectable = true
        isUserInteractionEnabled = true
        delegate = self
        
        // Add long press gesture
        print("👆 Adding long press gesture")
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture?.minimumPressDuration = 0.5
        addGestureRecognizer(longPressGesture!)
        
        // Enable UIEditMenuInteraction
        print("🎯 Adding UIEditMenuInteraction")
        editMenuInteraction = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenuInteraction!)
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        print("👆 Long press detected")
        if gesture.state == .began {
            let location = gesture.location(in: self)
            print("📍 Long press location: \(location)")
            
            // Get the character index at the touch location
            let characterIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            print("📝 Character index: \(characterIndex)")
            
            // Select the word at the touch location
            selectWord(at: characterIndex)
        }
    }
    
    private func selectWord(at index: Int) {
        guard index < text.count else { return }
        print("🔍 Selecting word at index: \(index)")
        
        let text = (self.text as NSString)
        let range = text.rangeOfWord(at: index)
        print("📏 Word range: \(range)")
        
        selectedRange = range
        
        // Present the menu
        if selectedRange.length > 0 {
            let selectionRect = firstRect(for: selectedTextRange!)
            let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: selectionRect.midX, y: selectionRect.minY))
            editMenuInteraction?.presentEditMenu(with: configuration)
        }
    }
    
    override var canBecomeFirstResponder: Bool { true }
    
    // Override key press events
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        print("⌨️ Presses began")
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - NSString Extension
extension NSString {
    func rangeOfWord(at index: Int) -> NSRange {
        let options: NSString.EnumerationOptions = [.byWords, .substringNotRequired]
        var wordRange = NSRange(location: 0, length: 0)
        
        enumerateSubstrings(in: NSRange(location: 0, length: length), options: options) { _, range, _, stop in
            if index >= range.location && index < range.location + range.length {
                wordRange = range
                stop.pointee = true
            }
        }
        
        return wordRange
    }
}

// MARK: - UITextViewDelegate
extension AICustomTextView: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        print("✂️ Selection changed: \(selectedRange)")
        
        // Update menu when selection changes
        if selectedRange.length > 0 {
            print("📋 Selection valid, updating menu...")
            let selectionRect = firstRect(for: selectedTextRange!)
            let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: selectionRect.midX, y: selectionRect.minY))
            editMenuInteraction?.presentEditMenu(with: configuration)
        }
    }
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        print("📝 Should change text in range: \(range)")
        return true
    }
    
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        print("✏️ Should begin editing")
        return true
    }
    
    func textViewDidBeginEditing(_ textView: UITextView) {
        print("✏️ Did begin editing")
    }
}

// MARK: - UIEditMenuInteractionDelegate
extension AICustomTextView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        print("📋 Building edit menu")
        
        // Create AI Edit action
        let aiEditAction = UIAction(
            title: "AI Edit",
            image: UIImage(systemName: "wand.and.stars")
        ) { [weak self] _ in
            print("🎯 AI Edit action selected")
            guard let self = self,
                  let selectedText = self.text(in: self.selectedTextRange!) else {
                print("⚠️ No valid selection")
                return
            }
            print("📝 Selected text: \(selectedText)")
            self.onAIEdit?(selectedText, self.selectedRange)
        }
        
        // Create menu with our custom action and suggested actions
        let customMenu = UIMenu(children: [aiEditAction] + suggestedActions)
        print("✅ Created menu with AI Edit action")
        return customMenu
    }
    
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let selectedRange = selectedTextRange else { return .zero }
        return firstRect(for: selectedRange)
    }
    
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDisplayMenuFor configuration: UIEditMenuConfiguration) {
        print("👀 Menu will display")
    }
    
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, didEndInteractingWith configuration: UIEditMenuConfiguration) {
        print("👋 Menu interaction ended")
    }
} 
import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var status: CoreStatus?
    private let apple = AppleSpeechEngine()
    private let recorder = AudioRecorder()
    private let liveMicrophone = AppleLiveMicrophone()
    private var appleSession: AppleSpeechLiveSession?
    private var liveSessionID: UUID?
    private var liveFailure: String?
    private var liveText = ""
    private var liveTranscriptItem: NSMenuItem?
    private let hotKey = HotKey()
    private let fnHotKey = FnHotKey()
    private var recording = RecordingLifecycle()
    private var isRecording: Bool { recording.isRecording }
    private var isBusy = false
    private var message = "Loading…"
    private var appleStatus = "Checking Apple Speech…"
    private var lastTranscript: Transcript?
    private var pasteTarget: NSRunningApplication?
    private var recordingTimer: Timer?
    private var recordingStart = Date()
    private var locales: [Locale] = []

    private var currentVersion: String {
        status?.version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()
        recorder.onLimitReached = { [weak self] in
            guard let self, self.isRecording else { return }
            self.stopRecording()
        }
        hotKey.onPress = { [weak self] in self?.toggleRecording() }
        do { try hotKey.register() } catch { message = error.localizedDescription }
        fnHotKey.onGesture = { [weak self] action in self?.handleFn(action) }
        fnHotKey.onAvailabilityChange = { [weak self] in self?.rebuildMenu() }
        fnHotKey.onInterrupted = { [weak self] in
            guard let self, self.recording.isFnOwned else { return }
            self.requestStopRecording()
        }
        fnHotKey.start()
        Task {
            do {
                status = try await Core.status()
                if message == "Loading…" { message = "Ready" }
                locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
                await refreshAppleStatus()
            } catch { message = error.localizedDescription }
            rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnHotKey.stop()
        recordingTimer?.invalidate()
        recorder.cleanUp()
        liveMicrophone.stop()
        lw_shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isBusy || isRecording {
            message = isRecording ? "Stop or discard the recording before quitting" : "Wait for the current operation to finish before quitting"
            rebuildMenu()
            return .terminateCancel
        }
        return .terminateNow
    }

    func menuWillOpen(_ menu: NSMenu) { fnHotKey.refresh(); rebuildMenu() }

    private func updateIcon() {
        let name = isRecording ? "record.circle.fill" : (isBusy ? "waveform" : "waveform.circle")
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Local Whisper")
        statusItem.button?.contentTintColor = isRecording ? .systemRed : nil
        statusItem.button?.title = isRecording ? " \(Int(Date().timeIntervalSince(recordingStart)))s" : ""
        statusItem.button?.toolTip = "Local Whisper — \(message) · Hold Fn / double-tap Fn / ⌘⇧Space" + (liveText.isEmpty ? "" : "\n\(liveText)")
    }

    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        item.representedObject = value
        return item
    }

    private func submenu(_ title: String, in menu: NSMenu, enabled: Bool = true) -> NSMenu {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = enabled
        let child = NSMenu()
        child.autoenablesItems = false
        parent.submenu = child
        menu.addItem(parent)
        return child
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        updateIcon()
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()
        liveTranscriptItem = nil
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(item("Local Whisper \(currentVersion)"))
        let statusLine = item(String(message.prefix(100)))
        statusLine.toolTip = message
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let record = item(isRecording ? "Stop and Transcribe" : "Start Recording", action: #selector(toggleRecording), enabled: !isBusy && status != nil)
        record.keyEquivalent = " "
        record.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(record)
        if isRecording { menu.addItem(item("Discard Recording", action: #selector(discardRecording))) }
        if isRecording && appleSession != nil {
            menu.addItem(item("Live Transcript"))
            let preview = item(livePreview)
            preview.toolTip = liveText
            menu.addItem(preview)
            liveTranscriptItem = preview
        }
        let shortcuts = submenu("Keyboard Shortcuts", in: menu)
        shortcuts.addItem(item("Hold Fn to speak; release to transcribe"))
        shortcuts.addItem(item("Double-tap Fn to start / stop"))
        shortcuts.addItem(item("⌘⇧Space to start / stop"))
        shortcuts.addItem(.separator())
        shortcuts.addItem(item(fnHotKey.statusText))
        shortcuts.addItem(item("Set Up Fn / Globe Key…", action: #selector(setUpFn), enabled: !isBusy && !isRecording))
        let canConfigure = !isBusy && !isRecording
        if let status {
            let config = status.config
            menu.addItem(.separator())
            let providers = submenu("Provider: \(providerName(config.provider))", in: menu, enabled: canConfigure)
            for (id, title) in [("apple", "Apple Speech — On Device"), ("local", "Hugging Face Model — On Device"), ("groq", "Groq — Cloud API")] {
                let option = item(title, action: #selector(selectProvider), enabled: canConfigure, value: id)
                option.state = config.provider == id ? .on : .off
                providers.addItem(option)
            }
            let models = submenu("Local Models", in: menu, enabled: canConfigure)
            for model in status.models {
                let size = ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)
                let title = model.installed ? model.name : "Download \(model.name) (\(size))"
                let option = item(title, action: #selector(selectLocalModel), enabled: canConfigure, value: model.id)
                option.state = config.localModel == model.id && model.installed ? .on : .off
                option.toolTip = model.languages
                models.addItem(option)
            }
            models.addItem(.separator())
            models.addItem(item("Downloads once; recognition runs locally"))

            let appleMenu = submenu("Apple Speech", in: menu, enabled: canConfigure)
            appleMenu.addItem(item(appleStatus))
            appleMenu.addItem(item("Prepare Apple Speech (\(config.appleLocale))…", action: #selector(prepareApple), enabled: canConfigure))
            let languages = submenu("Language: \(config.appleLocale)", in: appleMenu)
            for locale in locales {
                let id = locale.identifier(.bcp47)
                let name = Locale.current.localizedString(forIdentifier: id) ?? id
                let option = item(name, action: #selector(selectLanguage), enabled: canConfigure, value: id)
                option.state = id == config.appleLocale ? .on : .off
                languages.addItem(option)
            }
            if locales.isEmpty { languages.addItem(item("No Apple speech languages available")) }

            let groqMenu = submenu("Groq", in: menu, enabled: canConfigure)
            groqMenu.addItem(item("Audio is sent to Groq when this provider is selected"))
            groqMenu.addItem(item("Set API Key…", action: #selector(setGroqKey), enabled: canConfigure))
            groqMenu.addItem(item("Remove API Key", action: #selector(removeGroqKey), enabled: canConfigure))
            groqMenu.addItem(.separator())
            for model in ["whisper-large-v3-turbo", "whisper-large-v3"] {
                let option = item(model, action: #selector(selectGroqModel), enabled: canConfigure, value: model)
                option.state = config.groqModel == model ? .on : .off
                groqMenu.addItem(option)
            }
            let languageMenu = submenu("Local / Groq Language", in: menu, enabled: canConfigure)
            for (id, name) in [("auto", "Detect Automatically"), ("en", "English"), ("hi", "Hindi"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("ja", "Japanese"), ("zh", "Chinese")] {
                let option = item(name, action: #selector(selectHint), enabled: canConfigure, value: id)
                option.state = (config.language ?? "auto") == id ? .on : .off
                languageMenu.addItem(option)
            }
            languageMenu.addItem(item("Parakeet v3 always detects its language"))
            menu.addItem(.separator())
            let paste = item("Paste After Transcribing", action: #selector(togglePaste), enabled: canConfigure)
            paste.state = config.pasteAfterTranscription ? .on : .off
            menu.addItem(paste)
            if !AXIsProcessTrusted() {
                menu.addItem(item("Enable Pasting (Accessibility)…", action: #selector(enablePasting), enabled: canConfigure))
            }
            menu.addItem(item("Transcribe Audio File…", action: #selector(transcribeFile), enabled: canConfigure))
        }
        menu.addItem(item("Copy Last Transcript", action: #selector(copyLast), enabled: lastTranscript != nil))
        menu.addItem(item("Show Last Transcript…", action: #selector(showLast), enabled: lastTranscript != nil))
        menu.addItem(.separator())
        menu.addItem(item("Open App Data Folder", action: #selector(openData), enabled: status != nil))
        menu.addItem(item("Check for Updates…", action: #selector(checkForUpdates), enabled: canConfigure))
        menu.addItem(item("Changelog…", action: #selector(openChangelog), enabled: status != nil))
        menu.addItem(item("About Local Whisper…", action: #selector(showAbout)))
        let quit = item("Quit Local Whisper", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func providerName(_ id: String) -> String {
        switch id { case "apple": return "Apple Speech"; case "local": return "Local Model"; default: return "Groq (Cloud)" }
    }

    private func refreshAppleStatus() async {
        guard let locale = status?.config.appleLocale else { return }
        appleStatus = await apple.availability(locale: locale)
    }

    private func runOperation(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy && !isRecording else { return }
        isBusy = true
        message = label
        rebuildMenu()
        Task {
            do {
                try await operation()
                status = try await Core.status()
                message = "Ready"
            } catch {
                message = error.localizedDescription
                showError(error)
            }
            isBusy = false
            rebuildMenu()
        }
    }

    private func configure(_ change: (inout Config) -> Void) {
        guard var config = status?.config else { return }
        change(&config)
        let next = config
        runOperation("Saving…") { [self] in
            try await Core.save(next)
            status = try await Core.status()
            await refreshAppleStatus()
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        configure { $0.provider = id }
    }

    @objc private func selectLocalModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let model = status?.models.first(where: { $0.id == id }) else { return }
        runOperation(model.installed ? "Selecting \(model.name)…" : "Downloading \(model.name)…") { [self] in
            if !model.installed { try await Core.download(id) }
            guard var config = status?.config else { return }
            config.localModel = id
            config.provider = "local"
            try await Core.save(config)
        }
    }

    @objc private func selectGroqModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        configure { $0.groqModel = model }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let locale = sender.representedObject as? String else { return }
        configure { $0.appleLocale = locale }
    }

    @objc private func selectHint(_ sender: NSMenuItem) {
        guard let hint = sender.representedObject as? String else { return }
        configure { $0.language = hint == "auto" ? nil : hint }
    }

    @objc private func togglePaste() { configure { $0.pasteAfterTranscription.toggle() } }

    @objc private func prepareApple() {
        guard let locale = status?.config.appleLocale else { return }
        runOperation("Preparing Apple's speech assets…") { [self] in
            try await apple.prepare(locale: locale)
            await refreshAppleStatus()
        }
    }

    @objc private func setGroqKey() {
        guard !isBusy && !isRecording else { return }
        let alert = NSAlert()
        alert.messageText = "Groq API Key"
        alert.informativeText = "Stored in your Mac's Keychain. When you select Groq, recordings are uploaded to Groq for transcription."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.placeholderString = "gsk_…"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save to Keychain")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            do { try GroqKeychain.save(input.stringValue); message = "Groq key saved in Keychain" }
            catch { showError(error) }
        }
        input.stringValue = ""
        rebuildMenu()
    }

    @objc private func removeGroqKey() {
        do { try GroqKeychain.delete(); message = "Groq key removed" }
        catch { showError(error) }
        rebuildMenu()
    }

    @objc private func toggleRecording() {
        toggleRecordingFrom(.standard)
    }

    private func toggleRecordingFrom(_ source: RecordingLifecycle.Source) {
        if recording.hasSession { requestStopRecording(); return }
        startRecording(source: source)
    }

    private func handleFn(_ action: FnGesture.Action) {
        switch action {
        case .beginHold: startRecording(source: .fnHold)
        case .endHold: requestStopRecording(only: .fnHold)
        case .toggle: toggleRecordingFrom(.fnToggle)
        }
    }

    private func requestStopRecording(only source: RecordingLifecycle.Source? = nil) {
        if recording.requestStop(only: source) { stopRecording() }
    }

    private func startRecording(source: RecordingLifecycle.Source) {
        guard !isBusy && !recording.hasSession else { return }
        guard let config = status?.config else { return }
        if config.provider == "local" && status?.models.first(where: { $0.id == config.localModel })?.installed != true {
            showError(AppError("Download a model from Local Models before recording."))
            return
        }
        if config.provider == "groq" {
            do {
                guard try GroqKeychain.read() != nil else { throw AppError("Set your Groq API key from the menu before recording.") }
            } catch { showError(error); return }
        }
        guard recording.begin(source) else { return }
        pasteTarget = NSWorkspace.shared.frontmostApplication
        isBusy = true
        message = "Starting microphone…"
        rebuildMenu()
        Task {
            do {
                if config.provider == "apple" {
                    let id = UUID()
                    liveSessionID = id
                    liveText = ""
                    liveFailure = nil
                    appleSession = try await liveMicrophone.start(speech: apple, locale: config.appleLocale,
                        shouldStart: { [self] in recording.shouldStart },
                        onUpdate: { [weak self] update in
                            Task { @MainActor in
                                guard let self, self.liveSessionID == id else { return }
                                self.liveText = update.text
                                self.liveTranscriptItem?.title = self.livePreview
                                self.liveTranscriptItem?.toolTip = update.text
                                self.updateIcon()
                            }
                        }, onFailure: { [weak self] failure in
                            Task { @MainActor in
                                guard let self, self.liveSessionID == id else { return }
                                self.liveFailure = failure
                                if self.isRecording { self.failLiveRecording(failure) }
                            }
                        })
                    if let liveFailure { throw AppError(liveFailure) }
                } else {
                    try await recorder.start(shouldStart: { [self] in recording.shouldStart })
                }
                guard recording.didStart() else { throw CancellationError() }
                recordingStart = Date()
                message = config.provider == "apple" ? "Listening · Apple Speech Live" : "Recording · \(providerName(config.provider))"
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.updateIcon()
                        if self.isRecording && Date().timeIntervalSince(self.recordingStart) >= 300 {
                            self.stopRecording()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                recordingTimer = timer
            } catch {
                recording.reset()
                recorder.cleanUp()
                liveMicrophone.stop()
                liveSessionID = nil
                if let session = appleSession { await session.cancel() }
                appleSession = nil
                liveText = ""
                if error is CancellationError {
                    message = "Recording cancelled before microphone was ready"
                } else {
                    message = error.localizedDescription
                    showError(error)
                }
            }
            isBusy = false
            rebuildMenu()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        recording.reset()
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let session = appleSession {
            liveMicrophone.stop()
            appleSession = nil
            isBusy = true
            message = "Finishing Apple Speech…"
            rebuildMenu()
            Task {
                defer {
                    liveSessionID = nil
                    liveText = ""
                    isBusy = false
                    rebuildMenu()
                }
                do { completeTranscript(try await session.finish(), shouldPaste: true) }
                catch { message = error.localizedDescription; showError(error) }
            }
            return
        }
        guard let url = recorder.stop() else { recorder.cleanUp(); rebuildMenu(); return }
        transcribe(url: url, shouldPaste: true, cleanUp: true)
    }

    @objc private func discardRecording() {
        guard isRecording else { return }
        recording.reset()
        recordingTimer?.invalidate()
        recordingTimer = nil
        recorder.cleanUp()
        liveMicrophone.stop()
        liveSessionID = nil
        liveText = ""
        if let session = appleSession {
            appleSession = nil
            isBusy = true
            Task {
                await session.cancel()
                isBusy = false
                rebuildMenu()
            }
        }
        message = "Recording discarded"
        rebuildMenu()
    }

    private func transcribe(url: URL, shouldPaste: Bool, cleanUp: Bool) {
        guard let config = status?.config, !isBusy else { return }
        isBusy = true
        message = "Transcribing with \(providerName(config.provider))…"
        rebuildMenu()
        Task {
            defer {
                if cleanUp { recorder.cleanUp() }
                isBusy = false
                rebuildMenu()
            }
            do {
                let transcript: Transcript
                if config.provider == "apple" {
                    transcript = try await apple.transcribe(url: url, locale: config.appleLocale)
                } else {
                    transcript = try await Core.transcribe(url, key: config.provider == "groq" ? GroqKeychain.read() : nil)
                }
                completeTranscript(transcript, shouldPaste: shouldPaste)
            } catch {
                message = error.localizedDescription
                showError(error)
            }
        }
    }

    private var livePreview: String {
        if liveText.isEmpty { return "Listening for speech…" }
        return (liveText.count > 80 ? "…" : "") + String(liveText.suffix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    private func failLiveRecording(_ failure: String) {
        guard isRecording else { return }
        recording.reset()
        recordingTimer?.invalidate()
        recordingTimer = nil
        liveMicrophone.stop()
        liveSessionID = nil
        liveText = ""
        let session = appleSession
        appleSession = nil
        isBusy = true
        rebuildMenu()
        Task {
            defer { isBusy = false; rebuildMenu() }
            await session?.cancel()
            message = failure
            showError(AppError(failure))
        }
    }

    private func completeTranscript(_ transcript: Transcript, shouldPaste: Bool) {
        guard !transcript.text.isEmpty else { message = "No speech detected"; return }
        lastTranscript = transcript
        copy(transcript.text)
        message = "Copied · \(transcript.model)"
        if shouldPaste && status?.config.pasteAfterTranscription == true {
            if AXIsProcessTrusted() { paste() }
            else { message = "Copied · Enable Pasting to insert automatically" }
        }
    }

    @objc private func transcribeFile() {
        guard !isBusy && !isRecording else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.message = "Select a WAV file. Local and Groq providers require mono, 16 kHz, 16-bit PCM audio (up to five minutes)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url: url, shouldPaste: false, cleanUp: false)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func paste() {
        guard let target = pasteTarget, target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !target.isTerminated else { return }
        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Never send keystrokes to an unrelated app if focus changed meanwhile.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    @objc private func enablePasting() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func setUpFn() {
        let alert = NSAlert()
        alert.messageText = "Fn / Globe Dictation"
        alert.informativeText = "Hold Fn for 0.3 seconds, speak, then release to transcribe. Or double-tap Fn to start and double-tap again to stop.\n\nEnable Local Whisper in System Settings → Privacy & Security → Input Monitoring. If macOS asks, quit and reopen the app after granting access.\n\nIn System Settings → Keyboard, set ‘Press 🌐 key to’ (or ‘Press fn key to’) to ‘Do Nothing’. Also turn off or change the ‘Press Fn Twice’ shortcut under Keyboard → Dictation to avoid starting Apple Dictation too.\n\nFn combinations still work. ⌘⇧Space and the menu are always available."
        alert.addButton(withTitle: "Enable Input Monitoring")
        alert.addButton(withTitle: "Keyboard Settings")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            fnHotKey.requestAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        } else if response == .alertSecondButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        rebuildMenu()
    }

    @objc private func copyLast() {
        if let lastTranscript { copy(lastTranscript.text) }
    }

    @objc private func showLast() {
        guard let transcript = lastTranscript else { return }
        let alert = NSAlert()
        alert.messageText = "Last Transcript"
        alert.informativeText = "\(transcript.model) · \(String(format: "%.1f", transcript.elapsedMs / 1000)) seconds"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.string = transcript.text
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 14)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { copy(transcript.text) }
    }

    @objc private func openData() {
        if let path = status?.dataDir { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Local Whisper \(currentVersion)"
        alert.informativeText = "Rust transcription core · native macOS menu bar\n\nHold Fn to speak; release to transcribe.\nDouble-tap Fn or press ⌘⇧Space to start / stop.\nFn requires Input Monitoring access and keyboard setup.\n\nApple Speech and downloaded Hugging Face models run on device. Groq uploads audio to its API.\n\nRecordings are deleted after transcription. The last transcript stays in memory and the clipboard; no history is saved.\n\nApple silicon · macOS 26+"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openChangelog() {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        guard !isBusy && !isRecording else { return }
        isBusy = true
        message = "Checking for updates…"
        rebuildMenu()
        Task {
            defer { isBusy = false; rebuildMenu() }
            do {
                let update = try await Core.checkForUpdates()
                let alert = NSAlert()
                switch update.status {
                case .available:
                    let latest = update.latestVersion ?? "a newer version"
                    alert.messageText = "Local Whisper \(latest) Is Available"
                    alert.informativeText = "You’re using \(update.currentVersion). Download the release, quit Local Whisper, and replace the app in Applications. Your settings and models are stored separately."
                    if update.downloadURL != nil {
                        alert.addButton(withTitle: "Download Update")
                        alert.addButton(withTitle: "View Release Notes")
                    } else {
                        alert.addButton(withTitle: "View Release")
                    }
                    alert.addButton(withTitle: "Later")
                    message = "Update available: \(latest)"
                case .upToDate:
                    alert.messageText = "You’re Up to Date"
                    alert.informativeText = "You’re running Local Whisper \(update.currentVersion)."
                    alert.addButton(withTitle: "OK")
                    message = "Up to date · \(update.currentVersion)"
                case .noReleases:
                    alert.messageText = "No Releases Published Yet"
                    alert.informativeText = "You’re running Local Whisper \(update.currentVersion). Published releases will appear here once they are available on GitHub."
                    alert.addButton(withTitle: "OK")
                    message = "No public release available yet"
                }
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                if update.status == .available {
                    if response == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(update.downloadURL ?? update.releaseURL)
                    } else if response == .alertSecondButtonReturn && update.downloadURL != nil {
                        NSWorkspace.shared.open(update.releaseURL)
                    }
                }
            } catch {
                message = "Update check failed"
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Local Whisper"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

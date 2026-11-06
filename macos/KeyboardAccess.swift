/// Accessibility supports keyboard event taps and pasting. Input Monitoring is
/// an alternative for listening without granting control of other applications.
enum KeyboardAccess: String {
    case accessibility, inputMonitoring, unavailable

    init(accessibility: Bool, inputMonitoring: Bool) {
        self = accessibility ? .accessibility : (inputMonitoring ? .inputMonitoring : .unavailable)
    }
}

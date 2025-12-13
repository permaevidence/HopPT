import Foundation

enum DeviceSupport {
    static let isIPhone13OrNewer: Bool = {
        var systemInfo = utsname(); uname(&systemInfo)
        let raw = withUnsafeBytes(of: &systemInfo.machine) { ptr -> String in
            let data = Data(ptr)
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        guard raw.hasPrefix("iPhone") else { return false }
        let digits = raw.dropFirst("iPhone".count)
        guard let comma = digits.firstIndex(of: ","),
              let major = Int(digits[..<comma]) else { return false }
        return major >= 14          // iPhone14,* ⇒ iPhone 13 generation
    }()
}

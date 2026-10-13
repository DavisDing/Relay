import Foundation

// Embed the icon in the UDIF data fork so downloads retain it without xattrs.
// Finder's custom icon resource ID is -16455. Preserve all disk block resources.
func runHdiutil(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "RelayDMGIcon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments[0]) failed"])
    }
    return data
}

func resources(of image: String) throws -> [String: Any] {
    let data = try runHdiutil(["udifderez", "-xml", image])
    guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw NSError(domain: "RelayDMGIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid disk image resources"])
    }
    return result
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "RelayDMGIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: set-dmg-icon.swift <icon.icns> <image.dmg>"])
    }
    let iconURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let image = CommandLine.arguments[2]
    let icon = try Data(contentsOf: iconURL)
    guard icon.count >= 8, icon.prefix(4) == Data("icns".utf8),
          icon.dropFirst(4).prefix(4).reduce(UInt64(0), { ($0 << 8) | UInt64($1) }) == UInt64(icon.count) else {
        throw NSError(domain: "RelayDMGIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid ICNS icon"])
    }
    let original = try resources(of: image)
    guard original["blkx"] != nil else {
        throw NSError(domain: "RelayDMGIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing UDIF block resources"])
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("relay-dmg-icon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let resourceURL = temporary.appendingPathComponent("icon.plist")
    let entry: [String: Any] = ["Attributes": "0x0000", "ID": "-16455", "Name": "", "Data": icon]
    let xml = try PropertyListSerialization.data(fromPropertyList: ["icns": [entry]], format: .xml, options: 0)
    try xml.write(to: resourceURL, options: .atomic)
    _ = try runHdiutil(["udifrez", image, "-xml", resourceURL.path])
    let updated = try resources(of: image)
    guard let icons = updated["icns"] as? [[String: Any]],
          let customIcon = icons.first(where: { $0["ID"] as? String == "-16455" }),
          customIcon["Data"] as? Data == icon else {
        throw NSError(domain: "RelayDMGIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Embedded DMG icon verification failed"])
    }
    for (key, value) in original where key != "icns" {
        guard NSDictionary(dictionary: [key: value]).isEqual(to: [key: updated[key] as Any]) else {
            throw NSError(domain: "RelayDMGIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Embedding the icon changed \(key) resources"])
        }
    }
    print("VERIFIED: embedded DMG icon matches the app icon; disk resources preserved.")
} catch {
    FileHandle.standardError.write(Data("DMG icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}

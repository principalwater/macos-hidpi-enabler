// hidpi lists and selects the HiDPI display modes that macOS generates but hides.
//
// WindowServer builds scaled HiDPI modes for every display. On some Macs it marks part of
// them as valid for mirroring only (IOKit kDisplayModeValidForMirroringFlag), so System
// Settings and CGDisplayCopyAllDisplayModes never offer them. The private CoreGraphics
// display-mode functions still list and select them. WindowServer stores a selection made
// with kCGConfigurePermanently for the current set of displays and applies it again
// whenever that set connects, so nothing keeps running afterwards.
//
// Intel Macs have no such hidden modes for most external displays: they build larger HiDPI
// modes only from a list in the display's override file. `hidpi add` writes that list once,
// and from then on WindowServer keeps those modes hidden in the same way.

import AppKit
import CoreGraphics
import Darwin

/// A display mode as WindowServer lists it, including modes hidden from public APIs.
struct DisplayMode {
  let number: Int32
  let width: Int
  let height: Int
  let scale: Float
  let refreshRate: Int
  let depth: Int
  let isValid: Bool
  let isNative: Bool
  let isHidden: Bool

  var isHiDPI: Bool { scale > 1 }

  var summary: String {
    // Intel Macs report a rate of 0 for some displays.
    let rate = refreshRate > 0 ? ", \(refreshRate) Hz" : ""
    return "\(width) x \(height) \(isHiDPI ? "HiDPI" : "LoDPI")\(rate)"
  }
}

/// The HiDPI modes of one size, in WindowServer order. WindowServer can list a mode once per
/// color depth.
struct HiDPISize {
  let width: Int
  let height: Int
  var modes: [DisplayMode]

  func line(current: Int32?) -> String {
    let size = "\(width) x \(height)"
    var rates: [String] = []
    for rate in modes.map(\.refreshRate) where rate > 0 && !rates.contains(String(rate)) {
      rates.append(String(rate))
    }
    var notes: [String] = []
    if modes.allSatisfy(\.isHidden) { notes.append("hidden") }
    if modes.contains(where: { $0.number == current }) { notes.append("current") }
    let padding = String(repeating: " ", count: max(1, 13 - size.count))
    let rateColumn = rates.isEmpty ? "" : rates.joined(separator: ", ") + " Hz"
    let suffix = notes.isEmpty ? "" : "  " + notes.joined(separator: ", ")
    return size + padding + rateColumn + suffix
  }
}

enum ToolError: Error, CustomStringConvertible {
  case missingSymbol(String)
  case unknownDisplay(String)
  case badSize(String)
  case noSuchMode(String, display: CGDirectDisplayID)
  case configurationFailed(CGError)
  case notApplied(DisplayMode)
  case noNativeMode(CGDirectDisplayID)
  case hasHiDPIModes(CGDirectDisplayID)
  case needsRoot(String)
  case overrideExists(String)
  case overrideNotWritten(String)
  case noOverride(String)
  case foreignOverride(String)

  var description: String {
    switch self {
    case .missingSymbol(let name):
      return "this macOS release has no \(name); the tool cannot work here"
    case .unknownDisplay(let argument):
      return "no online display \(argument); run hidpi without arguments to list displays"
    case .badSize(let argument):
      return "expected WIDTHxHEIGHT or WIDTHxHEIGHT@HZ, got \(argument)"
    case .noSuchMode(let size, let display):
      return "display \(display) has no HiDPI mode \(size); run hidpi to list its modes"
    case .configurationFailed(let error):
      return "WindowServer rejected the display configuration (CGError \(error.rawValue))"
    case .notApplied(let mode):
      return "WindowServer did not switch to \(mode.summary)"
    case .noNativeMode(let display):
      return "display \(display) reports no native mode, so the sizes to add are unknown"
    case .hasHiDPIModes(let display):
      return "display \(display) already has HiDPI modes above half its size; "
        + "run hidpi to list them"
    case .needsRoot(let arguments):
      return "changing /Library/Displays needs administrator rights; run: "
        + "sudo \(CommandLine.arguments[0]) \(arguments)"
    case .overrideExists(let path):
      return "\(path) already exists; reconnect the display so macOS reads it, "
        + "or move the file away to replace it"
    case .overrideNotWritten(let path):
      return "could not write \(path)"
    case .noOverride(let path):
      return "\(path) does not exist, so there is nothing to remove"
    case .foreignOverride(let path):
      return "\(path) was not written by hidpi, so it stays in place"
    }
  }
}

/// The private CoreGraphics functions behind the complete display-mode list.
///
/// This is the only unsafe code in the tool. The functions are resolved at run time so a
/// macOS release without them fails with a message instead of at launch. Published headers
/// disagree on whether they return CGError, so they are declared without a result and the
/// tool checks what they write instead. The 0xD4-byte mode description has kept this
/// layout for many macOS releases; displayplacer documents the same one.
struct PrivateDisplayModes {
  private typealias CountModes = @convention(c) (
    CGDirectDisplayID, UnsafeMutablePointer<Int32>
  ) -> Void
  private typealias DescribeMode = @convention(c) (
    CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32
  ) -> Void
  private typealias CurrentMode = @convention(c) (
    CGDirectDisplayID, UnsafeMutablePointer<Int32>
  ) -> Void
  private typealias ConfigureMode = @convention(c) (
    CGDisplayConfigRef?, CGDirectDisplayID, Int32
  ) -> Void

  private static let descriptionLength = 0xD4
  private static let validFlag: UInt32 = 0x1
  private static let nativeFlag: UInt32 = 0x0200_0000

  private let countModes: CountModes
  private let describeMode: DescribeMode
  private let currentModeNumber: CurrentMode
  private let configureMode: ConfigureMode

  init() throws {
    countModes = try Self.function(named: "CGSGetNumberOfDisplayModes")
    describeMode = try Self.function(named: "CGSGetDisplayModeDescriptionOfLength")
    currentModeNumber = try Self.function(named: "CGSGetCurrentDisplayMode")
    configureMode = try Self.function(named: "CGSConfigureDisplayMode")
  }

  /// Returns every mode WindowServer keeps for `display`, in WindowServer order.
  func modes(of display: CGDirectDisplayID) -> [DisplayMode] {
    let publicNumbers = Self.publicModeNumbers(of: display)
    var count: Int32 = 0
    countModes(display, &count)
    guard count > 0 else { return [] }
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Self.descriptionLength, alignment: MemoryLayout<UInt32>.alignment)
    defer { buffer.deallocate() }
    return (0..<count).compactMap { index in
      buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Self.descriptionLength)
      describeMode(display, index, buffer, Int32(Self.descriptionLength))
      let width = Int(buffer.loadUnaligned(fromByteOffset: 0x08, as: UInt32.self))
      let height = Int(buffer.loadUnaligned(fromByteOffset: 0x0C, as: UInt32.self))
      // A description that stayed zeroed was not filled in.
      guard width > 0, height > 0 else { return nil }
      let number = Int32(bitPattern: buffer.loadUnaligned(fromByteOffset: 0x00, as: UInt32.self))
      let flags = buffer.loadUnaligned(fromByteOffset: 0x04, as: UInt32.self)
      return DisplayMode(
        number: number,
        width: width,
        height: height,
        scale: buffer.loadUnaligned(fromByteOffset: 0xD0, as: Float.self),
        refreshRate: Int(buffer.loadUnaligned(fromByteOffset: 0xBE, as: UInt16.self)),
        depth: Int(buffer.loadUnaligned(fromByteOffset: 0x10, as: UInt32.self)),
        isValid: flags & Self.validFlag != 0,
        isNative: flags & Self.nativeFlag != 0,
        isHidden: !publicNumbers.contains(number))
    }
  }

  /// Returns the number of the mode `display` is using now.
  func currentMode(of display: CGDirectDisplayID) -> Int32? {
    var number: Int32 = -1
    currentModeNumber(display, &number)
    return number >= 0 ? number : nil
  }

  /// Switches `display` to `mode` and asks WindowServer to keep it for this set of
  /// displays.
  func select(_ mode: DisplayMode, on display: CGDirectDisplayID) throws {
    var configuration: CGDisplayConfigRef?
    let begun = CGBeginDisplayConfiguration(&configuration)
    guard begun == .success else { throw ToolError.configurationFailed(begun) }
    configureMode(configuration, display, mode.number)
    let completed = CGCompleteDisplayConfiguration(configuration, .permanently)
    guard completed == .success else { throw ToolError.configurationFailed(completed) }
    guard currentMode(of: display) == mode.number else { throw ToolError.notApplied(mode) }
  }

  private static func function<Function>(named name: String) throws -> Function {
    // RTLD_DEFAULT searches every loaded image; CoreGraphics exports these functions.
    guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
      throw ToolError.missingSymbol(name)
    }
    return unsafeBitCast(address, to: Function.self)
  }

  private static func publicModeNumbers(of display: CGDirectDisplayID) -> Set<Int32> {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    return Set(modes.map(\.ioDisplayModeID))
  }
}

/// The display override file that makes an Intel Mac generate larger HiDPI modes.
///
/// CoreDisplay uses the first file it finds for a display and looks in `folder` before the
/// sealed system folder. Its built-in list of scaled modes stops at the panel size, so a
/// HiDPI mode above half the panel size needs an entry here for its larger frame. An entry
/// of scale-resolutions holds four big-endian UInt32 values: frame width, frame height,
/// install flags and mode flags (IOFBInstallScaledModes in Apple's IOGraphicsLib.c).
struct DisplayOverride {
  private static let folder = "/Library/Displays/Contents/Resources/Overrides"
  private static let systemFolder = "/System/Library/Displays/Contents/Resources/Overrides"
  /// Marks a file as written by this tool, so `remove` never deletes someone else's.
  private static let ownerKey = "macos-hidpi-enabler"
  /// kScaleInstallAlways | kScaleInstallMirrorDeps
  private static let installFlags: UInt32 = 0x9
  /// kDisplayModeValidForMirroringFlag | kDisplayModeValidForHiResFlag
  private static let modeFlags: UInt32 = 0x00A0_0000
  /// The desktop sizes to offer, as fractions of the panel size. Half is left out: its frame
  /// would match the panel's own mode, and macOS drops such an entry as a duplicate.
  private static let fractions: [Double] = [1, 0.8, 0.75, 0.625, 0.5625]

  let path: String
  private let systemPath: String
  private let vendor: UInt32
  private let product: UInt32

  init(display: CGDirectDisplayID) {
    vendor = CGDisplayVendorNumber(display)
    product = CGDisplayModelNumber(display)
    let file =
      "DisplayVendorID-\(String(vendor, radix: 16))/DisplayProductID-\(String(product, radix: 16))"
    path = Self.folder + "/" + file
    systemPath = Self.systemFolder + "/" + file
  }

  /// Writes the file, keeping what Apple's own file for this display says.
  func install(native: DisplayMode, name: String) throws {
    let files = FileManager.default
    guard !files.fileExists(atPath: path) else { throw ToolError.overrideExists(path) }
    var contents = NSDictionary(contentsOfFile: systemPath) as? [String: Any] ?? [:]
    contents["DisplayVendorID"] = Int(vendor)
    contents["DisplayProductID"] = Int(product)
    contents["DisplayProductName"] = contents["DisplayProductName"] ?? name
    contents["scale-resolutions"] = Self.scaleResolutions(native: native)
    contents[Self.ownerKey] = true
    let data = try PropertyListSerialization.data(
      fromPropertyList: contents, format: .xml, options: 0)
    try files.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    guard files.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o644])
    else { throw ToolError.overrideNotWritten(path) }
  }

  /// Deletes the file, if this tool wrote it.
  func remove() throws {
    guard let contents = NSDictionary(contentsOfFile: path) else {
      throw ToolError.noOverride(path)
    }
    guard contents[Self.ownerKey] != nil else { throw ToolError.foreignOverride(path) }
    try FileManager.default.removeItem(atPath: path)
    // Fails harmlessly while the folder still holds a file for another display.
    rmdir((path as NSString).deletingLastPathComponent)
  }

  private static func scaleResolutions(native: DisplayMode) -> [Data] {
    fractions.map { fraction in
      let width = (Double(native.width) * fraction).rounded()
      let height = (width * Double(native.height) / Double(native.width)).rounded()
      // A HiDPI mode renders a frame of twice its size.
      let entry = [UInt32(width) * 2, UInt32(height) * 2, installFlags, modeFlags]
      return entry.map(\.bigEndian).withUnsafeBytes { Data($0) }
    }
  }
}

func onlineDisplays() -> [CGDirectDisplayID] {
  var count: UInt32 = 0
  guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
  var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
  return Array(displays.prefix(Int(count)))
}

/// Returns the online display that a command-line argument names.
func onlineDisplay(_ argument: String) throws -> CGDirectDisplayID {
  let display: CGDirectDisplayID? =
    argument == "main" ? CGMainDisplayID() : CGDirectDisplayID(argument)
  guard let display, onlineDisplays().contains(display) else {
    throw ToolError.unknownDisplay(argument)
  }
  return display
}

@MainActor
func displayName(_ display: CGDirectDisplayID) -> String {
  let key = NSDeviceDescriptionKey("NSScreenNumber")
  let screen = NSScreen.screens.first {
    ($0.deviceDescription[key] as? NSNumber)?.uint32Value == display
  }
  if let screen { return screen.localizedName }
  return CGDisplayIsBuiltin(display) != 0 ? "Built-in display" : "Display"
}

/// Groups the valid HiDPI modes by size.
func hiDPISizes(_ modes: [DisplayMode]) -> [HiDPISize] {
  var sizes: [HiDPISize] = []
  for mode in modes where mode.isValid && mode.isHiDPI {
    guard
      let index = sizes.firstIndex(where: { $0.width == mode.width && $0.height == mode.height })
    else {
      sizes.append(HiDPISize(width: mode.width, height: mode.height, modes: [mode]))
      continue
    }
    sizes[index].modes.append(mode)
  }
  return sizes
}

/// Whether a HiDPI size lies above half the panel size, the range that `hidpi add` adds.
func hasLargeHiDPISize(_ sizes: [HiDPISize], native: DisplayMode) -> Bool {
  sizes.contains { $0.width > native.width / 2 }
}

@MainActor
func listDisplays(using api: PrivateDisplayModes) {
  let main = CGMainDisplayID()
  for display in onlineDisplays() {
    let modes = api.modes(of: display)
    let current = api.currentMode(of: display)
    print("Display \(display): \(displayName(display))\(display == main ? " (main)" : "")")
    if let mode = modes.first(where: { $0.number == current }) {
      print("  current: \(mode.summary)")
    }
    let sizes = hiDPISizes(modes)
    print(sizes.isEmpty ? "  no HiDPI modes" : "  HiDPI modes:")
    for size in sizes {
      print("    " + size.line(current: current))
    }
    if let native = modes.first(where: \.isNative), !hasLargeHiDPISize(sizes, native: native) {
      let isWritten = FileManager.default.fileExists(atPath: DisplayOverride(display: display).path)
      print(
        isWritten
          ? "  reconnect the display or restart so macOS reads its override file"
          : "  add larger sizes with: sudo hidpi add \(display)")
    }
  }
  print("\nSelect one with: hidpi DISPLAY WIDTHxHEIGHT[@HZ]")
}

@MainActor
func selectMode(using api: PrivateDisplayModes, display argument: String, size: String) throws {
  let display = try onlineDisplay(argument)
  let parts = size.split(separator: "@", maxSplits: 1)
  let dimensions = parts.first?.split(separator: "x").compactMap { Int($0) } ?? []
  let refreshRate = parts.count == 2 ? Int(parts[1]) : nil
  guard dimensions.count == 2, parts.count == 1 || refreshRate != nil else {
    throw ToolError.badSize(size)
  }
  let candidates =
    hiDPISizes(api.modes(of: display)).first {
      $0.width == dimensions[0] && $0.height == dimensions[1]
    }?.modes ?? []
  // Without an explicit rate, take the fastest one, as System Settings does by default. Of its
  // color depths, take the deepest, so that switching does not lower the depth.
  let matching =
    refreshRate == nil ? candidates : candidates.filter { $0.refreshRate == refreshRate }
  let mode = matching.max { ($0.refreshRate, $0.depth) < ($1.refreshRate, $1.depth) }
  guard let mode else { throw ToolError.noSuchMode(size, display: display) }
  try api.select(mode, on: display)
  print("\(displayName(display)): \(mode.summary) selected.")
  print("macOS keeps it for this set of displays and applies it again on every connect.")
}

@MainActor
func addModes(using api: PrivateDisplayModes, display argument: String) throws {
  let display = try onlineDisplay(argument)
  let modes = api.modes(of: display)
  guard let native = modes.first(where: \.isNative) else {
    throw ToolError.noNativeMode(display)
  }
  guard !hasLargeHiDPISize(hiDPISizes(modes), native: native) else {
    throw ToolError.hasHiDPIModes(display)
  }
  guard geteuid() == 0 else { throw ToolError.needsRoot("add \(display)") }
  let override = DisplayOverride(display: display)
  try override.install(native: native, name: displayName(display))
  print("\(displayName(display)): wrote \(override.path).")
  print("Reconnect the display or restart so macOS reads it, then run hidpi to list the new modes.")
}

@MainActor
func removeModes(display argument: String) throws {
  let display = try onlineDisplay(argument)
  guard geteuid() == 0 else { throw ToolError.needsRoot("remove \(display)") }
  let override = DisplayOverride(display: display)
  try override.remove()
  print("\(displayName(display)): removed \(override.path).")
  print("Reconnect the display or restart so macOS stops offering the added modes.")
}

let usage = """
  usage: hidpi                            list displays and their HiDPI modes
         hidpi DISPLAY WIDTHxHEIGHT[@HZ]  switch DISPLAY (an ID from the list, or main)
                                          to that HiDPI mode and keep it
         sudo hidpi add DISPLAY           make an Intel Mac generate larger HiDPI modes
                                          for DISPLAY, with a display override file
         sudo hidpi remove DISPLAY        delete that file
  """

/// Runs the command line and returns the process exit status.
@MainActor
func run(_ arguments: [String]) -> Int32 {
  if arguments.first == "-h" || arguments.first == "--help" {
    print(usage)
    return 0
  }
  guard arguments.isEmpty || arguments.count == 2 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    return 2
  }
  do {
    let api = try PrivateDisplayModes()
    switch arguments.first {
    case nil: listDisplays(using: api)
    case "add": try addModes(using: api, display: arguments[1])
    case "remove": try removeModes(display: arguments[1])
    default: try selectMode(using: api, display: arguments[0], size: arguments[1])
    }
    return 0
  } catch {
    FileHandle.standardError.write(Data("hidpi: \(error)\n".utf8))
    return 1
  }
}

// Top-level code runs on the main thread both when compiled and under `swift hidpi.swift`,
// but only the compiled form treats it as main-actor isolated.
exit(MainActor.assumeIsolated { run(Array(CommandLine.arguments.dropFirst())) })

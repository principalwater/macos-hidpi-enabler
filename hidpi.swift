// hidpi lists and selects the HiDPI display modes that macOS generates but hides.
//
// WindowServer builds scaled HiDPI modes for every display. On some Macs it marks part of
// them as valid for mirroring only (IOKit kDisplayModeValidForMirroringFlag), so System
// Settings and CGDisplayCopyAllDisplayModes never offer them. The private CoreGraphics
// display-mode functions still list and select them. WindowServer stores a selection made
// with kCGConfigurePermanently for the current set of displays and applies it again
// whenever that set connects, so nothing keeps running afterwards.

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
  let isValid: Bool
  let isHidden: Bool

  var isHiDPI: Bool { scale > 1 }

  var summary: String {
    "\(width) x \(height) \(isHiDPI ? "HiDPI" : "LoDPI"), \(refreshRate) Hz"
  }
}

/// The HiDPI modes of one size, one per refresh rate, in WindowServer order.
struct HiDPISize {
  let width: Int
  let height: Int
  var modes: [DisplayMode]

  func line(current: Int32?) -> String {
    let size = "\(width) x \(height)"
    let rates = modes.map { String($0.refreshRate) }.joined(separator: ", ")
    var notes: [String] = []
    if modes.allSatisfy(\.isHidden) { notes.append("hidden") }
    if modes.contains(where: { $0.number == current }) { notes.append("current") }
    let padding = String(repeating: " ", count: max(1, 13 - size.count))
    let suffix = notes.isEmpty ? "" : "  " + notes.joined(separator: ", ")
    return size + padding + rates + " Hz" + suffix
  }
}

enum ToolError: Error, CustomStringConvertible {
  case missingSymbol(String)
  case unknownDisplay(String)
  case badSize(String)
  case noSuchMode(String, display: CGDirectDisplayID)
  case configurationFailed(CGError)
  case notApplied(DisplayMode)

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
        isValid: flags & Self.validFlag != 0,
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

func onlineDisplays() -> [CGDirectDisplayID] {
  var count: UInt32 = 0
  guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
  var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
  return Array(displays.prefix(Int(count)))
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

/// Groups the valid HiDPI modes by size, keeping one mode per refresh rate.
func hiDPISizes(_ modes: [DisplayMode]) -> [HiDPISize] {
  var sizes: [HiDPISize] = []
  for mode in modes where mode.isValid && mode.isHiDPI {
    guard
      let index = sizes.firstIndex(where: { $0.width == mode.width && $0.height == mode.height })
    else {
      sizes.append(HiDPISize(width: mode.width, height: mode.height, modes: [mode]))
      continue
    }
    if !sizes[index].modes.contains(where: { $0.refreshRate == mode.refreshRate }) {
      sizes[index].modes.append(mode)
    }
  }
  return sizes
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
  }
  print("\nSelect one with: hidpi DISPLAY WIDTHxHEIGHT[@HZ]")
}

@MainActor
func selectMode(using api: PrivateDisplayModes, display argument: String, size: String) throws {
  let display: CGDirectDisplayID? =
    argument == "main" ? CGMainDisplayID() : CGDirectDisplayID(argument)
  guard let display, onlineDisplays().contains(display) else {
    throw ToolError.unknownDisplay(argument)
  }
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
  // Without an explicit rate, take the fastest one, as System Settings does by default.
  let mode =
    refreshRate == nil
    ? candidates.max { $0.refreshRate < $1.refreshRate }
    : candidates.first { $0.refreshRate == refreshRate }
  guard let mode else { throw ToolError.noSuchMode(size, display: display) }
  try api.select(mode, on: display)
  print("\(displayName(display)): \(mode.summary) selected.")
  print("macOS keeps it for this set of displays and applies it again on every connect.")
}

let usage = """
  usage: hidpi                          list displays and their HiDPI modes
         hidpi DISPLAY WIDTHxHEIGHT[@HZ]  switch DISPLAY (an ID from the list, or main)
                                          to that HiDPI mode and keep it
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
    if arguments.isEmpty {
      listDisplays(using: api)
    } else {
      try selectMode(using: api, display: arguments[0], size: arguments[1])
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

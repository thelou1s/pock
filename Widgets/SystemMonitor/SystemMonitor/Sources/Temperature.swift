//
//  Temperature.swift
//  SystemMonitor
//
//  Created by Luis on 19/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import Foundation
import IOKit

/// Reads the CPU temperature from the sensors Apple itself labels as CPU.
///
/// The primary source is the HID event-system client: every Apple Silicon Mac
/// publishes its core temperatures there under names such as
/// `pACC MTR Temp Sensor3`, one per performance and efficiency core. Those are
/// the sensors the open-source monitor `Hot` calls the CPU, and its rule is
/// copied here: take the hottest of the `pACC`/`eACC` readings. The API is not
/// in the public SDK, so its functions are looked up at run time.
///
/// If a machine publishes no such sensor the reader falls back to the
/// `AppleSMC` user client, first the package key `TC0P` (what the `istats`
/// command line tool reports) and then the hottest CPU core key (`Tp…` for the
/// performance cores, `Te…` for the efficiency cores).
///
/// Both interfaces are undocumented, so everything here is best effort: a
/// machine where neither is available shows no temperature at all instead of
/// breaking the rest of the widget.
///
/// Every driver call runs on one serial queue, because a user client connection
/// may not be shared by two callers. Enumerating the SMC keys costs a few hundred
/// milliseconds, which is why that happens once in the background and only when
/// the HID sensors are missing; a refresh then re-reads what was found back then
/// and reports back on the main queue.
internal final class CPUTemperatureReader {

	internal static let shared = CPUTemperatureReader()

	/// Celsius value that fills the usage bar.
	internal static let scaleCeiling: Double = 100

	/// Readings outside this range are not a sensor, they are a register that
	/// happens to start with `T`.
	private static let plausibleRange: ClosedRange<Double> = 10...115

	/// The package level CPU sensor, as reported by `istats cpu`.
	///
	/// Intel machines publish it; on Apple Silicon the key does not exist at all,
	/// which is why the core sensors below are the normal path there.
	private static let packageKeys: [String] = ["TC0P"]

	/// Key prefixes of the CPU core sensors.
	///
	/// On Apple Silicon one key per core and per measurement point: `Tp…` for the
	/// performance cores, `Te…` for the efficiency cores. The `TC…`/`Tc…` keys are
	/// left out because they republish other sensors instead of measuring a core,
	/// and `Tg…` (GPU), `TH…` (SSD) and `TB…` (battery) are other parts.
	private static let corePrefixes: [String] = ["Tp", "Te"]

	/// The sensor families that carry temperatures.
	///
	/// `flt ` is what Apple Silicon uses, `sp78` and `fpe2` what Intel machines
	/// report. Other types are structs whose layout is not published, so they are
	/// skipped rather than guessed at.
	private static let temperatureTypes: Set<String> = ["flt ", "sp78", "fpe2"]

	private enum Format {
		case float
		case sp78
		case fpe2
	}

	private struct Channel {
		let code: UInt32
		let identifier: String
		let size: Int
		let format: Format
	}

	private enum State {
		case idle
		case scanning
		case ready
		case unavailable
	}

	private let queue = DispatchQueue(label: "com.luis.pock.SystemMonitor.smc")
	private let gate = NSLock()
	private var state: State = .idle
	private var hid: HIDSensors?
	private var packageSensors: [Channel] = []
	private var coreSensors: [Channel] = []
	private var lastCelsius: Double?

	private init() { }

	// MARK: Access

	/// Kicks off the one-off key scan. Safe to call on every appearance: a scan
	/// already running or already finished is left alone.
	internal func startScanIfNeeded() {
		gate.lock()
		guard state == .idle else {
			gate.unlock()
			return
		}
		state = .scanning
		gate.unlock()

		queue.async { [weak self] in
			self?.scan()
		}
	}

	/// The last CPU reading, or nil while nothing has been read yet.
	///
	/// Only touches the cached value, so it is safe to call while a refresh is in
	/// flight.
	internal var currentCelsius: Double? {
		gate.lock()
		defer { gate.unlock() }
		return state == .ready ? lastCelsius : nil
	}

	/// Re-reads the CPU sensors, then calls `completion` on the main queue.
	internal func refreshCelsius(completion: @escaping (Double?) -> Void) {
		gate.lock()
		let ready = state == .ready
		gate.unlock()
		guard ready else {
			completion(nil)
			return
		}
		queue.async { [weak self] in
			guard let self = self else {
				return
			}
			let celsius = self.readCelsius()
			DispatchQueue.main.async {
				completion(celsius)
			}
		}
	}

	// MARK: Scanning

	/// Finds the sensors to read. Runs on the SMC queue.
	///
	/// The HID sensors come first: Apple names them, they need no key enumeration,
	/// and they are the sensors `Hot` reports. A machine that publishes none gets
	/// the SMC scan.
	private func scan() {
		if let client = HIDSensors() {
			let values = client.cpuValues()
			if values.isEmpty == false {
				gate.lock()
				hid = client
				lastCelsius = values.max()
				state = .ready
				gate.unlock()
				/// The item list is built before the first values arrive, so ask for
				/// a rebuild now that there is something to show.
				DispatchQueue.main.async {
					NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
				}
				return
			}
		}
		scanSMC()
	}

	private func scanSMC() {
		guard open() else {
			markUnavailable()
			return
		}
		defer { close() }

		guard let count = readInteger(key: "#KEY") else {
			markUnavailable()
			return
		}

		var package: [Channel] = []
		var cores: [Channel] = []
		for index in 0..<count {
			guard let code = key(at: index), let info = information(for: code) else {
				continue
			}
			let identifier = string(for: code)
			let isPackage = Self.packageKeys.contains(identifier)
			guard isPackage || Self.corePrefixes.contains(where: { identifier.hasPrefix($0) }),
				  let format = Self.format(forType: info.type) else {
				continue
			}
			guard let celsius = decode(read(code, size: info.size), format),
				  Self.plausibleRange.contains(celsius) else {
				continue
			}
			let channel = Channel(code: code, identifier: identifier, size: info.size, format: format)
			if isPackage {
				package.append(channel)
			} else {
				cores.append(channel)
			}
		}

		gate.lock()
		packageSensors = package
		coreSensors = cores
		state = package.isEmpty && cores.isEmpty ? .unavailable : .ready
		let didFind = state == .ready
		gate.unlock()

		if didFind {
			/// The item list is built before the first values arrive, so read once
			/// here and ask for a rebuild now that there is something to show.
			_ = readCelsius()
			DispatchQueue.main.async {
				NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
			}
		}
	}

	/// Runs on the SMC queue.
	private func readCelsius() -> Double? {
		gate.lock()
		let client = hid
		gate.unlock()
		if let client = client {
			return keep(client.cpuValues().max())
		}
		return keep(readSMC())
	}

	/// The package sensor is used whenever the machine publishes one: that is the
	/// reading `istats cpu` calls the CPU temperature. Apple Silicon does not
	/// publish it, and there the hottest core becomes the CPU temperature.
	private func readSMC() -> Double? {
		gate.lock()
		let package = packageSensors
		let cores = coreSensors
		gate.unlock()
		guard package.isEmpty == false || cores.isEmpty == false, open() else {
			return nil
		}
		defer { close() }

		var reading: Double?
		for channel in package {
			if let celsius = decode(read(channel.code, size: channel.size), channel.format),
			   Self.plausibleRange.contains(celsius) {
				reading = celsius
				break
			}
		}
		if reading == nil {
			for channel in cores {
				guard let celsius = decode(read(channel.code, size: channel.size), channel.format),
					  Self.plausibleRange.contains(celsius) else {
					continue
				}
				if let hottest = reading {
					reading = max(hottest, celsius)
				} else {
					reading = celsius
				}
			}
		}
		return reading
	}

	/// Remembers a reading, so that one failed tick does not blank the bar.
	private func keep(_ celsius: Double?) -> Double? {
		gate.lock()
		if let celsius = celsius {
			lastCelsius = celsius
		}
		gate.unlock()
		return celsius
	}

	private func markUnavailable() {
		gate.lock()
		state = .unavailable
		gate.unlock()
	}

	// MARK: Driver calls

	/// Must stay 80 bytes: it is the struct the driver expects.
	///
	/// Layout follows SMCKit (MIT, Copyright (c) 2014-2017 beltex), which
	/// transcribed it from Apple's PowerManagement `PrivateLib.c`. Note that
	/// `dataSize` is a 32 bit field here even though `IOByteCount` is 64 bits on
	/// arm64: using `IOByteCount` grows the struct to 88 bytes and every call then
	/// fails.
	private struct ParamStruct {

		struct Version {
			var major: UInt8 = 0
			var minor: UInt8 = 0
			var build: UInt8 = 0
			var reserved: UInt8 = 0
			var release: UInt16 = 0
		}

		struct PLimitData {
			var version: UInt16 = 0
			var length: UInt16 = 0
			var cpuPLimit: UInt32 = 0
			var gpuPLimit: UInt32 = 0
			var memPLimit: UInt32 = 0
		}

		struct KeyInfoData {
			var dataSize: UInt32 = 0
			var dataType: UInt32 = 0
			var dataAttributes: UInt8 = 0
		}

		var key: UInt32 = 0
		var vers = Version()
		var pLimitData = PLimitData()
		var keyInfo = KeyInfoData()
		var padding: UInt16 = 0
		var result: UInt8 = 0
		var status: UInt8 = 0
		var data8: UInt8 = 0
		var data32: UInt32 = 0
		var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
					UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
					UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
					UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
									 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	}

	private enum Command: UInt8 {
		case readKey = 5
		case getKeyFromIndex = 8
		case getKeyInfo = 9
	}

	/// Every request goes through the `HandleYPCEvent` method with the real command
	/// in `data8`, which is how the driver is addressed on both architectures.
	private static let methodIndex: UInt32 = 2
	private static let success: UInt8 = 0

	private var connection: io_connect_t = 0

	private func open() -> Bool {
		guard connection == 0 else {
			return true
		}
		let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
		guard service != 0 else {
			return false
		}
		let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
		IOObjectRelease(service)
		guard result == kIOReturnSuccess else {
			connection = 0
			return false
		}
		return true
	}

	private func close() {
		guard connection != 0 else {
			return
		}
		IOServiceClose(connection)
		connection = 0
	}

	/// Returns nil for any key the SMC does not have, which is the common case while
	/// scanning: most keys report `kSMCKeyNotFound`.
	private func request(_ command: Command, _ input: inout ParamStruct) -> ParamStruct? {
		var output = ParamStruct()
		var size = MemoryLayout<ParamStruct>.stride
		input.data8 = command.rawValue
		guard MemoryLayout<ParamStruct>.stride == 80 else {
			return nil
		}
		let result = IOConnectCallStructMethod(connection, Self.methodIndex, &input,
											   MemoryLayout<ParamStruct>.stride, &output, &size)
		guard result == kIOReturnSuccess, output.result == Self.success else {
			return nil
		}
		return output
	}

	private func information(for code: UInt32) -> (size: Int, type: String)? {
		var input = ParamStruct()
		input.key = code
		guard let output = request(.getKeyInfo, &input) else {
			return nil
		}
		return (Int(output.keyInfo.dataSize), string(for: output.keyInfo.dataType))
	}

	private func key(at index: Int) -> UInt32? {
		var input = ParamStruct()
		input.data32 = UInt32(index)
		guard let output = request(.getKeyFromIndex, &input) else {
			return nil
		}
		return output.key
	}

	private func read(_ code: UInt32, size: Int) -> [UInt8]? {
		var input = ParamStruct()
		input.key = code
		input.keyInfo.dataSize = UInt32(size)
		guard size > 0, let output = request(.readKey, &input) else {
			return nil
		}
		return withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
	}

	/// Reads a big endian counter such as `#KEY`.
	private func readInteger(key name: String) -> Int? {
		guard let code = code(for: name), let info = information(for: code),
			  let bytes = read(code, size: info.size) else {
			return nil
		}
		var value = 0
		for byte in bytes {
			value = value << 8 | Int(byte)
		}
		return value
	}

	// MARK: Encoding

	private static func format(forType type: String) -> Format? {
		guard temperatureTypes.contains(type) else {
			return nil
		}
		switch type {
		case "flt ":
			return .float
		case "sp78":
			return .sp78
		default:
			return .fpe2
		}
	}

	/// `flt ` values reach us little endian on Apple Silicon; decoding them big
	/// endian yields nonsense such as 2.7e20, which the plausible range rejects.
	private func decode(_ bytes: [UInt8]?, _ format: Format) -> Double? {
		guard let bytes = bytes, bytes.isEmpty == false else {
			return nil
		}
		switch format {
		case .float:
			guard bytes.count >= 4 else {
				return nil
			}
			var bits: UInt32 = 0
			for index in 0..<4 {
				bits |= UInt32(bytes[index]) << (8 * index)
			}
			let value = Double(Float(bitPattern: bits))
			return value.isFinite ? value : nil
		case .sp78:
			guard bytes.count >= 2 else {
				return nil
			}
			return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256
		case .fpe2:
			guard bytes.count >= 2 else {
				return nil
			}
			return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2)) / 64
		}
	}

	private func code(for string: String) -> UInt32? {
		let bytes = Array(string.utf8)
		guard bytes.count == 4 else {
			return nil
		}
		var value: UInt32 = 0
		for byte in bytes {
			value = value << 8 | UInt32(byte)
		}
		return value
	}

	/// Turns a key or a type back into its four printable characters, replacing
	/// anything else with `?` so that a garbage value cannot reach a label.
	private func string(for value: UInt32) -> String {
		let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
					UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
		return String(bytes: bytes.map { (0x20...0x7e).contains($0) ? $0 : UInt8(ascii: "?") },
					  encoding: .ascii) ?? "????"
	}
}

/// The CPU core temperatures as Apple publishes them on the HID event bus.
///
/// Every service on that bus has a product name, and the core sensors are the
/// ones Apple labels `pACC MTR Temp Sensor…` for the performance cores and
/// `eACC MTR Temp Sensor…` for the efficiency ones. Naming them is why this is
/// the preferred source: unlike an SMC key such as `Tp2h`, the name says what is
/// being measured.
///
/// The event-system client is not part of the public SDK, so the six functions
/// are looked up in IOKit at run time. A failure to find any of them - or a
/// machine that publishes no such service - makes the initializer return nil,
/// and the reader then falls back to the SMC keys.
///
/// Only ever used from the reader's serial queue, so nothing here is guarded.
internal final class HIDSensors {

	/// Name prefixes of the CPU sensors: `pACC` for the performance cores,
	/// `eACC` for the efficiency cores.
	private static let cpuNamePrefixes: [String] = ["pACC", "eACC"]

	/// Readings outside this range are a service without a sensor, not a
	/// temperature.
	private static let plausibleRange: Range<Double> = 0..<120

	/// Temperature sensors live on Apple's vendor usage page `0xff00` under
	/// usage `5`, which is what selects them out of all the HID services.
	private static let serviceMatch: NSDictionary = [
		"PrimaryUsagePage": NSNumber(value: 0xff00),
		"PrimaryUsage": NSNumber(value: 5),
	]

	/// The HID event type that carries a temperature.
	private static let temperatureEvent: Int64 = 0x0f

	/// The field of that event holding the reading, as a usage page and index.
	private static let temperatureField: Int32 = Int32(0x0f << 16)

	private typealias Client = UnsafeMutableRawPointer
	private typealias Create = @convention(c) (Unmanaged<CFAllocator>?) -> Client?
	private typealias SetMatching = @convention(c) (Client?, CFDictionary?) -> Void
	private typealias CopyServices = @convention(c) (Client?) -> Unmanaged<CFArray>?
	private typealias CopyProperty = @convention(c) (UnsafeRawPointer?, CFString) -> Unmanaged<CFTypeRef>?
	private typealias CopyEvent = @convention(c) (UnsafeRawPointer?, Int64, UInt32, UInt64) -> Unmanaged<CFTypeRef>?
	private typealias FloatValue = @convention(c) (CFTypeRef?, Int32) -> Double

	private let client: Client
	private let copyServices: CopyServices
	private let copyProperty: CopyProperty
	private let copyEvent: CopyEvent
	private let floatValue: FloatValue

	/// nil when the interface is unavailable, which is the case on a system that
	/// does not export it.
	internal init?() {
		guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
			return nil
		}
		guard let create = Self.function(Create.self, from: library, "IOHIDEventSystemClientCreate"),
			  let setMatching = Self.function(SetMatching.self, from: library, "IOHIDEventSystemClientSetMatching"),
			  let copyServices = Self.function(CopyServices.self, from: library, "IOHIDEventSystemClientCopyServices"),
			  let copyProperty = Self.function(CopyProperty.self, from: library, "IOHIDServiceClientCopyProperty"),
			  let copyEvent = Self.function(CopyEvent.self, from: library, "IOHIDServiceClientCopyEvent"),
			  let floatValue = Self.function(FloatValue.self, from: library, "IOHIDEventGetFloatValue"),
			  let client = create(nil) else {
			return nil
		}
		setMatching(client, Self.serviceMatch)
		self.client = client
		self.copyServices = copyServices
		self.copyProperty = copyProperty
		self.copyEvent = copyEvent
		self.floatValue = floatValue
	}

	/// The reading of every CPU core sensor, unordered. Empty when none answers.
	internal func cpuValues() -> [Double] {
		guard let services = copyServices(client)?.takeRetainedValue() else {
			return []
		}
		var values: [Double] = []
		for index in 0..<CFArrayGetCount(services) {
			guard let service = CFArrayGetValueAtIndex(services, index) else {
				continue
			}
			guard let name = productName(service),
				  Self.isCPUSensor(name),
				  let event = copyEvent(service, Self.temperatureEvent, 0, 0) else {
				continue
			}
			let celsius = floatValue(event.takeRetainedValue(), Self.temperatureField)
			if Self.plausibleRange.contains(celsius) {
				values.append(celsius)
			}
		}
		return values
	}

	private static func function<T>(_ type: T.Type, from library: UnsafeMutableRawPointer,
									_ symbol: String) -> T? {
		guard let address = dlsym(library, symbol) else {
			return nil
		}
		return unsafeBitCast(address, to: T.self)
	}

	/// The property is a `CFString`; a service without one is normal, so nothing
	/// is said about it.
	private func productName(_ service: UnsafeRawPointer) -> String? {
		guard let product = copyProperty(service, "Product" as CFString)?.takeRetainedValue() else {
			return nil
		}
		return product as? String
	}

	private static func isCPUSensor(_ name: String) -> Bool {
		cpuNamePrefixes.contains { name.hasPrefix($0) }
	}
}

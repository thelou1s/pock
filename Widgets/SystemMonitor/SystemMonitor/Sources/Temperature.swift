//
//  Temperature.swift
//  SystemMonitor
//
//  Created by Luis on 19/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import Foundation
import IOKit

/// Reads the CPU temperature through the `AppleSMC` user client.
///
/// The SMC interface is not a public API, so everything here is best effort: a
/// machine where it is unavailable shows no temperature at all instead of
/// breaking the rest of the widget.
///
/// Apple does not name the sensors, so the reading is derived: the CPU package
/// sensor is used where a machine publishes one (`TC0P`, the key the `istats`
/// command line tool reports as the CPU temperature), and where none exists the
/// hottest CPU core sensor stands in for it. Both paths read the cores
/// themselves, so the number is ours rather than a value another tool computed.
///
/// Every driver call runs on one serial queue, because a user client connection
/// may not be shared by two callers. Enumerating the keys costs a few hundred
/// milliseconds, which is why that happens once in the background; a refresh then
/// only re-reads the sensors found back then and reports back on the main queue.
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

	private func scan() {
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
	///
	/// The package sensor is used whenever the machine publishes one: that is the
	/// reading `istats cpu` calls the CPU temperature. Apple Silicon does not
	/// publish it, and there the hottest core becomes the CPU temperature.
	private func readCelsius() -> Double? {
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

		gate.lock()
		/// A failed read keeps the previous number: one bad tick should not blank
		/// the bar.
		if let reading = reading {
			lastCelsius = reading
		}
		gate.unlock()
		return reading
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

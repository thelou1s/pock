//
//  SystemMetrics.swift
//  SystemMonitor
//
//  Created by Luis on 04/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import Foundation

/// A single reading of the machine's resource usage.
///
/// Every value is normalized in the `0...1` range, where `1` means 100% usage.
internal struct SystemMetricsSnapshot {

	/// Overall CPU load (1 - idle ticks).
	internal var cpu: Double

	/// Physical memory in use, Activity Monitor style.
	internal var memory: Double

	/// Used space on the root volume.
	internal var disk: Double

	internal static let zero = SystemMetricsSnapshot(cpu: 0, memory: 0, disk: 0)

	/// Returns the value for the given kind of metric.
	internal subscript(kind: MetricKind) -> Double {
		switch kind {
		case .cpu:
			return cpu
		case .memory:
			return memory
		case .disk:
			return disk
		}
	}
}

/// Collects system metrics.
///
/// CPU usage is computed from the delta of the host's tick counters, so the very
/// first reading is always `0`: a previous sample is required to compute a delta.
/// From the second reading on, values are accurate.
internal final class SystemMetricsSampler {

	/// Shared sampler, so that the CPU delta is kept between refreshes.
	internal static let shared = SystemMetricsSampler()

	/// Ticks of the previous CPU sample: `[user, system, idle, nice]`.
	private var previousCPUTicks: [UInt32]?

	private init() { }

	/// Returns a fresh snapshot of all metrics.
	internal func sample() -> SystemMetricsSnapshot {
		return SystemMetricsSnapshot(
			cpu: currentCPUUsage(),
			memory: currentMemoryUsage(),
			disk: currentDiskUsage()
		)
	}

	// MARK: - CPU

	/// Returns the CPU usage since the previous call, in the `0...1` range.
	private func currentCPUUsage() -> Double {
		guard let ticks = Self.cpuTicks() else {
			return 0
		}
		defer {
			previousCPUTicks = ticks
		}
		guard let previous = previousCPUTicks, previous.count == ticks.count else {
			return 0
		}
		/// Tick counters are 32 bit and may wrap around: `&-` handles the overflow.
		let deltas = zip(ticks, previous).map { Double($0 &- $1) }
		let total = deltas.reduce(0, +)
		guard total > 0 else {
			return 0
		}
		let idle = deltas[Int(CPU_STATE_IDLE)]
		return min(max((total - idle) / total, 0), 1)
	}

	/// Returns the host's CPU tick counters.
	private static func cpuTicks() -> [UInt32]? {
		var size = mach_msg_type_number_t(
			MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
		)
		var info = host_cpu_load_info()
		let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
				host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &size)
			}
		}
		guard result == KERN_SUCCESS else {
			return nil
		}
		return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
	}

	// MARK: - Memory

	/// Returns the used memory in the `0...1` range.
	///
	/// Mimics Activity Monitor's "Memory Used": `app memory + wired + compressed`,
	/// where app memory is `internal - purgeable`.
	private func currentMemoryUsage() -> Double {
		var stats = vm_statistics64()
		var count = mach_msg_type_number_t(
			MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
		)
		let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
				host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
			}
		}
		guard result == KERN_SUCCESS else {
			return 0
		}
		let total = Double(ProcessInfo.processInfo.physicalMemory)
		guard total > 0 else {
			return 0
		}
		let pageSize = Double(vm_kernel_page_size)
		let appMemory = max(Int64(stats.internal_page_count) - Int64(stats.purgeable_count), 0)
		let wired = Int64(stats.wire_count)
		let compressed = Int64(stats.compressor_page_count)
		let used = (Double(appMemory + wired + compressed) * pageSize)
		return min(max(used / total, 0), 1)
	}

	// MARK: - Disk

	/// Returns the used space of the root volume in the `0...1` range.
	private func currentDiskUsage() -> Double {
		let root = URL(fileURLWithPath: "/")
		guard let values = try? root.resourceValues(forKeys: [
			.volumeTotalCapacityKey,
			.volumeAvailableCapacityForImportantUsageKey,
			.volumeAvailableCapacityKey
		]), let total = values.volumeTotalCapacity, total > 0 else {
			return 0
		}
		/// Prefer the value used by macOS itself ("important usage") and fall back
		/// to the plain available capacity when it is not available.
		let available = Double(
			values.volumeAvailableCapacityForImportantUsage
				?? Int64(values.volumeAvailableCapacity ?? 0)
		)
		return min(max(1 - (available / Double(total)), 0), 1)
	}
}

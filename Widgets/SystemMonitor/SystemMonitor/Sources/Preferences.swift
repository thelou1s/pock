//
//  Preferences.swift
//  SystemMonitor
//
//  Created by Luis on 04/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import Foundation

extension NSNotification.Name {
	/// Posted whenever the widget's appearance or content has to be rebuilt.
	static let shouldReloadSystemMonitor = NSNotification.Name("shouldReloadSystemMonitor")
}

internal struct Preferences {

	internal enum Keys: String {
		case shouldShowCPUItem
		case shouldShowMemoryItem
		case shouldShowDiskItem
		case shouldShowIcons
		case shouldShowBars
		case refreshInterval
	}

	/// Supported refresh intervals, in seconds.
	internal static let refreshIntervalRange: ClosedRange<Double> = 1...10

	/// Refresh interval used until the user picks another one.
	internal static let defaultRefreshInterval: Double = 2

	/// Every boolean preference is `true` when not set yet.
	private static let defaultValues: [Keys: Bool] = [
		.shouldShowCPUItem: true,
		.shouldShowMemoryItem: true,
		.shouldShowDiskItem: true,
		.shouldShowIcons: true,
		.shouldShowBars: true
	]

	internal static subscript(_ key: Keys) -> Bool {
		get {
			guard let value = UserDefaults.standard.object(forKey: key.rawValue) else {
				return defaultValues[key] ?? true
			}
			/// Accept both real booleans and their string representation, so that
			/// values set through `defaults write` or command line arguments are
			/// honoured as well.
			if let number = value as? NSNumber {
				return number.boolValue
			}
			if let string = value as? NSString {
				return string.boolValue
			}
			return defaultValues[key] ?? true
		}
		set {
			UserDefaults.standard.set(newValue, forKey: key.rawValue)
		}
	}

	internal static var showsIcons: Bool {
		return Preferences[.shouldShowIcons]
	}

	internal static var showsBars: Bool {
		return Preferences[.shouldShowBars]
	}

	/// The number of seconds between two readings, clamped to `refreshIntervalRange`.
	internal static var refreshInterval: TimeInterval {
		get {
			var value = defaultRefreshInterval
			/// Accept both real numbers and their string representation, so that
			/// values set through `defaults write` or command line arguments are
			/// honoured as well.
			if let number = UserDefaults.standard.object(forKey: Keys.refreshInterval.rawValue) as? NSNumber {
				value = number.doubleValue
			} else if let string = UserDefaults.standard.object(forKey: Keys.refreshInterval.rawValue) as? NSString {
				value = string.doubleValue
			}
			return clampedRefreshInterval(value)
		}
		set {
			UserDefaults.standard.set(
				clampedRefreshInterval(newValue),
				forKey: Keys.refreshInterval.rawValue
			)
		}
	}

	/// Rounds to whole seconds and keeps the value inside `refreshIntervalRange`.
	internal static func clampedRefreshInterval(_ value: Double) -> TimeInterval {
		guard value.isFinite else {
			return defaultRefreshInterval
		}
		return min(max(value.rounded(), refreshIntervalRange.lowerBound), refreshIntervalRange.upperBound)
	}

	/// The order in which enabled metrics are displayed in the Touch Bar.
	internal static var enabledKinds: [MetricKind] {
		var kinds: [MetricKind] = []
		if Preferences[.shouldShowCPUItem] {
			kinds.append(.cpu)
		}
		if Preferences[.shouldShowMemoryItem] {
			kinds.append(.memory)
		}
		if Preferences[.shouldShowDiskItem] {
			kinds.append(.disk)
		}
		return kinds
	}

	internal static func reset() {
		for (key, value) in defaultValues {
			Preferences[key] = value
		}
		UserDefaults.standard.removeObject(forKey: Keys.refreshInterval.rawValue)
	}
}

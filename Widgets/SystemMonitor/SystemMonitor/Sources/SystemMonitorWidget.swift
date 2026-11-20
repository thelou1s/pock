//
//  SystemMonitorWidget.swift
//  SystemMonitor
//
//  Created by Luis on 04/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import AppKit
import PockKit

/// A Pock widget that keeps CPU, memory, disk and CPU temperature in the Touch
/// Bar.
///
/// The temperature is read from the System Management Controller: the CPU package
/// sensor where a machine publishes one, otherwise the hottest CPU core sensor.
///
/// Tap an item to open the most useful app for that metric (Activity Monitor for
/// CPU, memory and temperature, System Settings for the disk). Long press any item
/// to toggle the usage bars on and off.
public final class SystemMonitorWidget: NSObject, PKWidget {

	// MARK: PKWidget

	public static var identifier: String = "SystemMonitor"

	public var customizationLabel: String = "System Monitor"

	public var view: NSView!

	// MARK: Data

	private let stackView = NSStackView(frame: .zero)

	private var items: [MetricItem] = []

	private var refreshTimer: Timer?

	private var didPrimeSampler: Bool = false

	// MARK: Init

	public override init() {
		super.init()
		setUpView()
	}

	deinit {
		stopRefreshing()
	}

	// MARK: Set up

	private func setUpView() {
		stackView.orientation = .horizontal
		stackView.alignment = .centerY
		stackView.distribution = .fill
		stackView.spacing = 10
		stackView.translatesAutoresizingMaskIntoConstraints = false
		stackView.heightAnchor.constraint(equalToConstant: 30).isActive = true
		view = stackView
	}

	// MARK: Lifecycle

	public func prepareForCustomization() {
		clearItems()
	}

	public func viewDidAppear() {
		Diagnostics.log("appear interval=\(Preferences.refreshInterval)")
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(reloadItems),
			name: .shouldReloadSystemMonitor,
			object: nil
		)
		primeSamplerIfNeeded()
		CPUTemperatureReader.shared.startScanIfNeeded()
		reloadItems()
	}

	public func viewWillDisappear() {
		Diagnostics.log("disappear")
		NotificationCenter.default.removeObserver(self)
		stopRefreshing()
		clearItems()
	}

	// MARK: Items

	@objc private func reloadItems() {
		Diagnostics.log("reload interval=\(Preferences.refreshInterval)")
		clearItems()
		items = makeItems()
		for item in items {
			item.widget = self
			stackView.addArrangedSubview(item.view)
		}
		if items.isEmpty {
			/// Never leave the Touch Bar with an invisible, unclickable gap.
			let placeholder = NSTextField(labelWithString: "System Monitor")
			placeholder.font = NSFont.systemFont(ofSize: 12, weight: .medium)
			placeholder.textColor = .white
			stackView.addArrangedSubview(placeholder)
		}
		refresh()
		/// The refresh interval is a preference, so the timer is rebuilt every
		/// time the item list changes.
		restartRefreshTimer()
	}

	/// Builds one item per metric enabled in the preferences.
	private func makeItems() -> [MetricItem] {
		return Preferences.enabledKinds.map { kind in
			let item = MetricItem(kind: kind)
			if kind.isTemperature {
				/// The cached reading, so the item is not blank while the first
				/// refresh is still on its way.
				item.celsius = CPUTemperatureReader.shared.currentCelsius
			}
			return item
		}
	}

	private func clearItems() {
		for subview in stackView.arrangedSubviews {
			stackView.removeArrangedSubview(subview)
			subview.removeFromSuperview()
		}
		items.removeAll()
	}

	// MARK: Refresh

	private func primeSamplerIfNeeded() {
		/// Prime the sampler so that the first visible CPU value is a real delta
		/// instead of the initial zero.
		if !didPrimeSampler {
			_ = SystemMetricsSampler.shared.sample()
			didPrimeSampler = true
		}
	}

	/// (Re)builds the refresh timer with the interval currently stored in the
	/// preferences.
	private func restartRefreshTimer() {
		stopRefreshing()
		Diagnostics.log("start timer interval=\(Preferences.refreshInterval)")
		let timer = Timer(timeInterval: Preferences.refreshInterval, repeats: true) { [weak self] _ in
			self?.refresh()
		}
		/// `.common` keeps the widget updating while the Touch Bar is scrolled.
		RunLoop.main.add(timer, forMode: .common)
		refreshTimer = timer
	}

	private func stopRefreshing() {
		refreshTimer?.invalidate()
		refreshTimer = nil
	}

	@objc private func refresh() {
		guard !items.isEmpty else {
			return
		}
		Diagnostics.log("refresh")
		let snapshot = SystemMetricsSampler.shared.sample()
		for item in items {
			if let usage = snapshot[item.kind] {
				item.value = usage
			}
			item.reloadPreferences()
		}
		if items.contains(where: { $0.kind.isTemperature }) {
			/// The sensor readings are taken off the main queue and reported back,
			/// because a driver call may have to wait for the scan that started it.
			CPUTemperatureReader.shared.refreshCelsius { [weak self] celsius in
				self?.applyCPUValue(celsius)
			}
		}
		#if DEBUG
		/// Lets the headless test harness measure the refresh cadence.
		print("[SystemMonitor] tick \(Date().timeIntervalSince1970)")
		#endif
	}

	/// Applies a fresh reading to the temperature item.
	private func applyCPUValue(_ celsius: Double?) {
		Diagnostics.log("celsius=\(celsius.map { String(format: "%.2f", $0) } ?? "nil")")
		for item in items where item.kind.isTemperature {
			item.celsius = celsius
		}
	}

	// MARK: Customization

	public var imageForCustomization: NSImage {
		let preview = NSStackView(frame: .zero)
		preview.orientation = .horizontal
		preview.alignment = .centerY
		preview.distribution = .fill
		preview.spacing = 10
		let snapshot = SystemMetricsSampler.shared.sample()
		for item in makeItems() {
			if let usage = snapshot[item.kind] {
				item.value = usage
			}
			preview.addArrangedSubview(item.view)
		}
		preview.layoutSubtreeIfNeeded()
		let size = preview.fittingSize
		return Self.image(of: preview, size: NSSize(width: max(size.width, 1), height: 30)) ?? NSImage()
	}

	/// Renders the given view into an image, used by the customization palette.
	///
	/// The view is sized before being cached: a stack view built in memory still
	/// has zero bounds, and caching into `view.bounds` produces an empty image.
	private static func image(of view: NSView, size: NSSize) -> NSImage? {
		let rect = NSRect(origin: .zero, size: size)
		guard size.width > 0, size.height > 0 else {
			return nil
		}
		view.setFrameSize(size)
		view.layoutSubtreeIfNeeded()
		guard let representation = view.bitmapImageRepForCachingDisplay(in: rect) else {
			return nil
		}
		view.cacheDisplay(in: rect, to: representation)
		let image = NSImage(size: size)
		image.addRepresentation(representation)
		return image
	}
}

// MARK: Diagnostics

/// Temporary tracer used to measure the real refresh cadence inside Pock.
/// Enabled with `defaults write com.pigigaldi.pock smTickLog -bool true`.
internal enum Diagnostics {

	private static let logURL = URL(fileURLWithPath: "/tmp/systemmonitor-ticks.log")

	internal static func log(_ message: String) {
		guard UserDefaults.standard.bool(forKey: "smTickLog") else {
			return
		}
		let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, message)
		guard let data = line.data(using: .utf8) else {
			return
		}
		if let handle = try? FileHandle(forWritingTo: logURL) {
			handle.seekToEndOfFile()
			handle.write(data)
			try? handle.close()
		} else {
			try? data.write(to: logURL)
		}
	}
}

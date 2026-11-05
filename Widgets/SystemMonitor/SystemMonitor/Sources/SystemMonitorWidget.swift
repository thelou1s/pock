//
//  SystemMonitorWidget.swift
//  SystemMonitor
//
//  Created by Luis on 04/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import AppKit
import PockKit

/// A Pock widget that keeps CPU, memory and disk usage in the Touch Bar.
///
/// Tap an item to open the most useful app for that metric (Activity Monitor for
/// CPU and memory, Finder for the disk). Long press any item to toggle the usage
/// bars on and off.
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
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(reloadItems),
			name: .shouldReloadSystemMonitor,
			object: nil
		)
		primeSamplerIfNeeded()
		reloadItems()
	}

	public func viewWillDisappear() {
		NotificationCenter.default.removeObserver(self)
		stopRefreshing()
		clearItems()
	}

	// MARK: Items

	@objc private func reloadItems() {
		clearItems()
		for kind in Preferences.enabledKinds {
			let item = MetricItem(kind: kind)
			item.widget = self
			items.append(item)
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
		let snapshot = SystemMetricsSampler.shared.sample()
		for item in items {
			item.value = snapshot[item.kind]
			item.reloadPreferences()
		}
		#if DEBUG
		/// Lets the headless test harness measure the refresh cadence.
		print("[SystemMonitor] tick \(Date().timeIntervalSince1970)")
		#endif
	}

	// MARK: Customization

	public var imageForCustomization: NSImage {
		let preview = NSStackView(frame: .zero)
		preview.orientation = .horizontal
		preview.alignment = .centerY
		preview.distribution = .fill
		preview.spacing = 10
		let snapshot = SystemMetricsSampler.shared.sample()
		for kind in Preferences.enabledKinds {
			let item = MetricItem(kind: kind)
			item.value = snapshot[kind]
			preview.addArrangedSubview(item.view)
		}
		preview.layoutSubtreeIfNeeded()
		let size = preview.fittingSize
		return Self.image(of: preview, size: NSSize(width: max(size.width, 1), height: 30)) ?? NSImage()
	}

	/// Renders the given view into an image, used by the customization palette.
	private static func image(of view: NSView, size: NSSize) -> NSImage? {
		guard size.width > 0, size.height > 0,
			  let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
			return nil
		}
		view.cacheDisplay(in: view.bounds, to: representation)
		let image = NSImage(size: size)
		image.addRepresentation(representation)
		return image
	}
}

//
//  MetricItem.swift
//  SystemMonitor
//
//  Created by Luis on 04/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import AppKit
import PockKit

/// The kind of system metric displayed by an item.
internal enum MetricKind: CaseIterable {

	case cpu
	case memory
	case disk
	case temperature

	/// Human readable name, also used as accessibility description.
	internal var title: String {
		switch self {
		case .cpu:
			return "CPU"
		case .memory:
			return "Memory"
		case .disk:
			return "Disk"
		case .temperature:
			return "CPU Temperature"
		}
	}

	/// SF Symbol name for the item's icon.
	internal var symbolName: String {
		switch self {
		case .cpu:
			return "cpu"
		case .memory:
			return "memorychip"
		case .disk:
			return "internaldrive"
		case .temperature:
			return "thermometer"
		}
	}

	/// Glyph used as a fallback when SF Symbols are not available.
	internal var fallbackGlyph: String {
		switch self {
		case .cpu:
			return "C"
		case .memory:
			return "M"
		case .disk:
			return "D"
		case .temperature:
			return "T"
		}
	}

	/// Key used to store the visibility of this item in the preferences.
	internal var preferenceKey: Preferences.Keys {
		switch self {
		case .cpu:
			return .shouldShowCPUItem
		case .memory:
			return .shouldShowMemoryItem
		case .disk:
			return .shouldShowDiskItem
		case .temperature:
			return .shouldShowTemperatureItem
		}
	}

	/// Whether the item reports degrees Celsius rather than a percentage.
	internal var isTemperature: Bool {
		return self == .temperature
	}

	/// Opens the most useful app for the given metric.
	internal func openRelatedApp() {
		switch self {
		case .cpu, .memory, .temperature:
			let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
			if FileManager.default.fileExists(atPath: url.path) {
				NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
				return
			}
			/// Older versions of macOS ship Activity Monitor here.
			NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Activity Monitor.app"))
		case .disk:
			Self.openStorageSettings()
		}
	}

	/// Opens the "Storage" pane of System Settings, the same destination as
	/// About This Mac › More Info › Storage Settings.
	private static func openStorageSettings() {
		/// `com.apple.settings.Storage` is used from macOS 13 on, the legacy
		/// preference pane identifier covers macOS 12 and earlier.
		let identifiers = ["com.apple.settings.Storage", "com.apple.preference.storage"]
		for identifier in identifiers {
			guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else {
				continue
			}
			if NSWorkspace.shared.open(url) {
				return
			}
		}
		let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
		if FileManager.default.fileExists(atPath: app.path) {
			NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		/// Last resort: never leave the tap without a result.
		NSWorkspace.shared.open(URL(fileURLWithPath: "/"))
	}
}

/// Tappable container of an item, forwarding gestures to its `MetricItem`.
internal final class MetricItemView: PKView {

	internal weak var item: MetricItem?

	override func didTapHandler() {
		item?.handleTap()
	}

	override func didLongPressHandler() {
		item?.handleLongPress()
	}
}

/// A single metric reading: icon, percentage and a small usage bar.
internal final class MetricItem {

	// MARK: Appearance

	private enum Layout {
		static let iconSize: CGFloat = 13
		static let barWidth: CGFloat = 32
		static let barHeight: CGFloat = 3
		static let height: CGFloat = 30
		static let spacing: CGFloat = 5
	}

	/// Highlight thresholds, expressed in the `0...1` range. For a temperature
	/// item that range is scaled by `CPUTemperatureReader.scaleCeiling`, so these
	/// mean 60 °C and 85 °C.
	private enum Threshold {
		static let warning: Double = 0.6
		static let critical: Double = 0.85
	}

	// MARK: Core

	internal let kind: MetricKind
	internal weak var widget: SystemMonitorWidget?

	/// Current usage, in the `0...1` range.
	internal var value: Double = 0 {
		didSet {
			render()
		}
	}

	/// Reading in degrees Celsius, for the CPU temperature item, or nil when no
	/// sensor reported one. It drives the bar through `value`, so both kinds share
	/// one rendering path.
	internal var celsius: Double? {
		didSet {
			value = (celsius ?? 0) / CPUTemperatureReader.scaleCeiling
		}
	}

	// MARK: UI

	private let container = MetricItemView(frame: .zero)
	private let iconView = NSImageView(frame: .zero)
	private let valueLabel = NSTextField(labelWithString: "--%")
	private let trackView = NSView(frame: .zero)
	private let fillView = NSView(frame: .zero)
	private var fillWidth: NSLayoutConstraint!

	internal var view: NSView {
		return container
	}

	// MARK: Init

	internal init(kind: MetricKind) {
		self.kind = kind
		buildView()
		render()
	}

	// MARK: Build

	private func buildView() {
		container.item = self
		container.translatesAutoresizingMaskIntoConstraints = false

		iconView.translatesAutoresizingMaskIntoConstraints = false
		iconView.imageScaling = .scaleProportionallyDown
		iconView.image = Self.icon(for: kind)
		iconView.isHidden = !Preferences.showsIcons

		valueLabel.translatesAutoresizingMaskIntoConstraints = false
		valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
		valueLabel.maximumNumberOfLines = 1
		valueLabel.alignment = .left

		trackView.translatesAutoresizingMaskIntoConstraints = false
		trackView.wantsLayer = true
		trackView.layer?.cornerRadius = Layout.barHeight / 2
		trackView.layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
		trackView.isHidden = !Preferences.showsBars

		fillView.translatesAutoresizingMaskIntoConstraints = false
		fillView.wantsLayer = true
		fillView.layer?.cornerRadius = Layout.barHeight / 2
		trackView.addSubview(fillView)

		let labelsStack = NSStackView(views: [valueLabel, trackView])
		labelsStack.translatesAutoresizingMaskIntoConstraints = false
		labelsStack.orientation = .vertical
		labelsStack.alignment = .leading
		labelsStack.spacing = 2

		let contentStack = NSStackView(views: [iconView, labelsStack])
		contentStack.translatesAutoresizingMaskIntoConstraints = false
		contentStack.orientation = .horizontal
		contentStack.alignment = .centerY
		contentStack.spacing = Layout.spacing
		container.addSubview(contentStack)

		fillWidth = fillView.widthAnchor.constraint(equalToConstant: 0)

		NSLayoutConstraint.activate([
			container.heightAnchor.constraint(equalToConstant: Layout.height),

			contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			contentStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),

			iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
			iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),

			trackView.widthAnchor.constraint(equalToConstant: Layout.barWidth),
			trackView.heightAnchor.constraint(equalToConstant: Layout.barHeight),

			fillView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
			fillView.topAnchor.constraint(equalTo: trackView.topAnchor),
			fillView.bottomAnchor.constraint(equalTo: trackView.bottomAnchor),
			fillWidth
		])
	}

	// MARK: Render

	private var color: NSColor {
		switch value {
		case ..<Threshold.warning:
			/// The Touch Bar is always dark, so plain white is the most legible
			/// "normal" color here.
			return .white
		case Threshold.warning..<Threshold.critical:
			return .systemOrange
		default:
			return .systemRed
		}
	}

	private func render() {
		valueLabel.stringValue = labelText
		valueLabel.textColor = color
		iconView.contentTintColor = color
		fillView.layer?.backgroundColor = color.cgColor
		fillWidth.constant = max(Layout.barHeight, CGFloat(min(max(value, 0), 1)) * Layout.barWidth)
	}

	/// `71°` for the CPU temperature, `42%` for a usage metric.
	///
	/// A reading that never arrived shows as `--` rather than as a temperature.
	private var labelText: String {
		guard kind.isTemperature else {
			return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
		}
		guard let celsius = celsius else {
			return "--"
		}
		return "\(Int(min(max(celsius, 0), 999).rounded()))°"
	}

	/// Re-applies the user preferences without recreating the item.
	internal func reloadPreferences() {
		iconView.isHidden = !Preferences.showsIcons
		trackView.isHidden = !Preferences.showsBars
	}

	// MARK: Gestures

	internal func handleTap() {
		kind.openRelatedApp()
	}

	internal func handleLongPress() {
		/// Long press toggles the usage bars: a compact, numbers-only mode.
		Preferences[.shouldShowBars] = !Preferences.showsBars
		NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
	}

	// MARK: Icons

	/// Returns the icon for the given kind, falling back to a drawn glyph when
	/// SF Symbols are not available.
	private static func icon(for kind: MetricKind) -> NSImage? {
		var symbol: NSImage?
		if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.title) {
			let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
			symbol = image.withSymbolConfiguration(configuration) ?? image
		}
		if let symbol = symbol {
			symbol.isTemplate = true
			return symbol
		}
		return glyphImage(kind.fallbackGlyph)
	}

	/// Draws a single letter into a template image.
	private static func glyphImage(_ glyph: String) -> NSImage {
		let size = NSSize(width: Layout.iconSize, height: Layout.iconSize)
		let image = NSImage(size: size, flipped: false) { rect in
			let attributes: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
				.foregroundColor: NSColor.white
			]
			let string = NSAttributedString(string: glyph, attributes: attributes)
			let stringSize = string.size()
			string.draw(at: NSPoint(
				x: rect.midX - stringSize.width / 2,
				y: rect.midY - stringSize.height / 2
			))
			return true
		}
		image.isTemplate = true
		return image
	}
}

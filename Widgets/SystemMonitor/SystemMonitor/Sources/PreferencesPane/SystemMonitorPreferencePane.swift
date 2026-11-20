//
//  SystemMonitorPreferencePane.swift
//  SystemMonitor
//
//  Created by Luis on 04/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import Cocoa
import PockKit

public final class SystemMonitorPreferencePane: NSViewController, PKWidgetPreference {

	public static var nibName: NSNib.Name = "SystemMonitorPreferencePane"

	/// UI
	@IBOutlet private weak var showCPUItem: NSButton!
	@IBOutlet private weak var showMemoryItem: NSButton!
	@IBOutlet private weak var showDiskItem: NSButton!
	@IBOutlet private weak var showIconsItem: NSButton!
	@IBOutlet private weak var showBarsItem: NSButton!

	private let refreshValueLabel = NSTextField(labelWithString: "")
	private let refreshStepper = NSStepper(frame: .zero)

	/// Temperature control, created in code like the refresh row.
	private let showTemperatureItem = NSButton(checkboxWithTitle: "Show CPU temperature", target: nil, action: nil)

	// MARK: PKWidgetPreference

	public func reset() {
		Preferences.reset()
		loadState()
		NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
	}

	public override func viewDidLoad() {
		super.viewDidLoad()
		buildLayout()
		loadState()
	}

	// MARK: Layout

	/// Re-flows the controls authored in the nib with a stack view and appends
	/// the refresh-rate row. Pock stretches the pane to its own container, so a
	/// stack view keeps everything aligned whatever size it ends up with.
	private func buildLayout() {
		let controls = view.subviews.filter { $0 is NSButton || $0 is NSTextField }
		for control in controls {
			control.removeFromSuperview()
		}

		let stackView = NSStackView(views: controls)
		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 6
		stackView.translatesAutoresizingMaskIntoConstraints = false

		/// A little breathing room between a section header and its controls.
		for header in controls.compactMap({ $0 as? NSTextField }) {
			stackView.setCustomSpacing(10, after: header)
		}

		refreshValueLabel.font = NSFont.systemFont(ofSize: 13)
		refreshValueLabel.textColor = .labelColor

		configure(refreshStepper,
				  lowerBound: Preferences.refreshIntervalRange.lowerBound,
				  upperBound: Preferences.refreshIntervalRange.upperBound,
				  action: #selector(didChangeRefreshInterval(_:)))

		let refreshRow = NSStackView(views: [refreshValueLabel, refreshStepper])
		refreshRow.orientation = .horizontal
		refreshRow.alignment = .centerY
		refreshRow.spacing = 8

		let refreshHeader = Self.header("Refresh rate")

		stackView.addArrangedSubview(refreshHeader)
		stackView.setCustomSpacing(6, after: refreshHeader)
		stackView.addArrangedSubview(refreshRow)

		/// Temperature: one switch, because the CPU temperature is a single number.
		/// The manager window only has room for a little more than the rows already
		/// authored in the nib, so nothing here takes up a row of its own.
		showTemperatureItem.font = NSFont.systemFont(ofSize: 13)
		showTemperatureItem.target = self
		showTemperatureItem.action = #selector(didChangeTemperatureItem(_:))

		let temperatureHeader = Self.header("Temperature")

		stackView.setCustomSpacing(14, after: refreshRow)
		stackView.addArrangedSubview(temperatureHeader)
		stackView.setCustomSpacing(6, after: temperatureHeader)
		stackView.addArrangedSubview(showTemperatureItem)

		view.addSubview(stackView)

		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
			stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
			stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18)
		])
	}

	private func configure(_ stepper: NSStepper, lowerBound: Double, upperBound: Double, action: Selector) {
		stepper.minValue = lowerBound
		stepper.maxValue = upperBound
		stepper.increment = 1
		stepper.valueWraps = false
		stepper.autorepeat = true
		stepper.target = self
		stepper.action = action
		stepper.setContentHuggingPriority(.defaultHigh, for: .horizontal)
	}

	private static func header(_ title: String) -> NSTextField {
		let header = NSTextField(labelWithString: title)
		header.font = NSFont.systemFont(ofSize: 13, weight: .bold)
		header.textColor = .labelColor
		return header
	}

	// MARK: State

	private func loadState() {
		showCPUItem.state = Preferences[.shouldShowCPUItem] ? .on : .off
		showMemoryItem.state = Preferences[.shouldShowMemoryItem] ? .on : .off
		showDiskItem.state = Preferences[.shouldShowDiskItem] ? .on : .off
		showIconsItem.state = Preferences[.shouldShowIcons] ? .on : .off
		showBarsItem.state = Preferences[.shouldShowBars] ? .on : .off
		showTemperatureItem.state = Preferences[.shouldShowTemperatureItem] ? .on : .off
		refreshStepper.doubleValue = Preferences.refreshInterval
		updateRefreshLabel()
	}

	private func updateRefreshLabel() {
		let seconds = Int(Preferences.clampedRefreshInterval(refreshStepper.doubleValue))
		refreshValueLabel.stringValue = seconds == 1
			? "Check every second"
			: "Check every \(seconds) seconds"
	}

	// MARK: Actions

	@IBAction private func didChangeCheckboxValue(_ checkbox: NSButton) {
		switch checkbox.tag {
		case 0:
			Preferences[.shouldShowCPUItem] = checkbox.state == .on
		case 1:
			Preferences[.shouldShowMemoryItem] = checkbox.state == .on
		case 2:
			Preferences[.shouldShowDiskItem] = checkbox.state == .on
		case 3:
			Preferences[.shouldShowIcons] = checkbox.state == .on
		case 4:
			Preferences[.shouldShowBars] = checkbox.state == .on
		default:
			return
		}
		NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
	}

	@IBAction private func didChangeRefreshInterval(_ stepper: NSStepper) {
		Preferences.refreshInterval = stepper.doubleValue
		/// Reflect the clamped value back into the control.
		stepper.doubleValue = Preferences.refreshInterval
		updateRefreshLabel()
		NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
	}

	@IBAction private func didChangeTemperatureItem(_ checkbox: NSButton) {
		Preferences[.shouldShowTemperatureItem] = checkbox.state == .on
		NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
	}
}

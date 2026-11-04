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

	// MARK: PKWidgetPreference

	public func reset() {
		Preferences.reset()
		loadCheckboxState()
		NotificationCenter.default.post(name: .shouldReloadSystemMonitor, object: nil)
	}

	public override func viewDidLoad() {
		super.viewDidLoad()
		loadCheckboxState()
	}

	// MARK: State

	private func loadCheckboxState() {
		showCPUItem.state = Preferences[.shouldShowCPUItem] ? .on : .off
		showMemoryItem.state = Preferences[.shouldShowMemoryItem] ? .on : .off
		showDiskItem.state = Preferences[.shouldShowDiskItem] ? .on : .off
		showIconsItem.state = Preferences[.shouldShowIcons] ? .on : .off
		showBarsItem.state = Preferences[.shouldShowBars] ? .on : .off
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
}

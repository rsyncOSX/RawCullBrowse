//
//  extension+Thread+Logger.swift
//  RawCullBrowse
//
//  Created by Thomas Evensen on 20/01/2026.
//

import Foundation
import OSLog

extension Logger {
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier
    nonisolated static let process = Logger(subsystem: subsystem ?? "process", category: "process")
}

/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation

/// Information about the active target for the Swift compiler.
struct SwiftTarget: Codable {
    struct Target: Codable {
        let triple: String
        let unversionedTriple: String
        let moduleTriple: String
        let swiftRuntimeCompatibilityVersion: String
    }

    let compilerVersion: String?

    let target: Target
}

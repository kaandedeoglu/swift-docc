/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import XCTest
@testable import SymbolKit
@testable import SwiftDocC

class SymbolGraphLoaderTests: XCTestCase {
    
    func testLoadingDifferentModules() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var symbolGraphURLs = [URL]()
        for moduleNames in ["One", "Two", "Three"] {
            let symbolGraph = SymbolGraph(
                metadata: SymbolGraph.Metadata(
                    formatVersion: SymbolGraph.SemanticVersion(major: 1, minor: 1, patch: 1),
                    generator: "unit-test"
                ),
                module: SymbolGraph.Module(
                    name: moduleNames,
                    platform: SymbolGraph.Platform(architecture: nil, vendor: nil, operatingSystem: nil)
                ),
                symbols: [],
                relationships: []
            )
            
            let symbolGraphURL = tempURL.appendingPathComponent("\(moduleNames).symbols.json")
            symbolGraphURLs.append(symbolGraphURL)
            
            try JSONEncoder().encode(symbolGraph).write(to: symbolGraphURL)
        }
        
        var loader = try makeSymbolGraphLoader(symbolGraphURLs: symbolGraphURLs)
        XCTAssertTrue(loader.symbolGraphs.isEmpty)
        
        try loader.loadAll()
        var moduleNameFrequency = [String: Int]()
        
        var isMainSymbolGraph = false
        while let graph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph) {
            XCTAssertTrue(isMainSymbolGraph)
            XCTAssertNotNil(graph)
            moduleNameFrequency[graph.symbolGraph.module.name, default: 0] += 1
        }
        
        XCTAssertEqual(moduleNameFrequency, ["One": 1, "Two": 1, "Three": 1])
    }
    
    func testLoadingDifferentModuleExtensions() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var symbolGraphURLs = [URL]()
        for moduleName in ["One", "Two", "Three"] {
            let symbolGraph = makeEmptySymbolGraph(moduleName: moduleName)
            
            let symbolGraphURL = tempURL.appendingPathComponent("Something@\(moduleName).symbols.json")
            symbolGraphURLs.append(symbolGraphURL)
            
            try JSONEncoder().encode(symbolGraph).write(to: symbolGraphURL)
        }
        
        var loader = try makeSymbolGraphLoader(symbolGraphURLs: symbolGraphURLs)
        try loader.loadAll()
        var moduleNameFrequency = [String: Int]()
        
        var isMainSymbolGraph = false
        while let graph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph) {
            XCTAssertFalse(isMainSymbolGraph)
            moduleNameFrequency[graph.symbolGraph.module.name, default: 0] += 1
        }
        
        // The loaded module should have the name of the module that was extended.
        XCTAssertEqual(moduleNameFrequency, ["One": 1, "Two": 1, "Three": 1])
    }
    
    func testNotGroupingExtensionsWithWithTheModuleThatExtends() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var symbolGraphURLs = [URL]()
        
        // Create a main module
        let mainSymbolGraph = makeEmptySymbolGraph(moduleName: "Main")
        let mainSymbolGraphURL = tempURL.appendingPathComponent("Main.symbols.json")
        symbolGraphURLs.append(mainSymbolGraphURL)
        
        try JSONEncoder().encode(mainSymbolGraph).write(to: mainSymbolGraphURL)
        
        // Create 3 extension from thise module on other modules
        for moduleName in ["One", "Two", "Three"] {
            let symbolGraph = makeEmptySymbolGraph(moduleName: moduleName)
            
            let symbolGraphURL = tempURL.appendingPathComponent("Main@\(moduleName).symbols.json")
            symbolGraphURLs.append(symbolGraphURL)
            
            try JSONEncoder().encode(symbolGraph).write(to: symbolGraphURL)
        }
        
        var loader = try makeSymbolGraphLoader(symbolGraphURLs: symbolGraphURLs)
        try loader.loadAll()
        var moduleNameFrequency = [String: Int]()
        
        var isMainSymbolGraph = false
        while let graph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph) {
            XCTAssertNotNil(graph)
            XCTAssertEqual(isMainSymbolGraph, !graph.url.lastPathComponent.contains("@"))
            
            moduleNameFrequency[graph.symbolGraph.module.name, default: 0] += 1
        }
        
        // All 4 modules should have different names
        XCTAssertEqual(moduleNameFrequency, ["Main": 1, "One": 1, "Two": 1, "Three": 1])
    }
    
    func testLoadingHighNumberOfModulesConcurrently() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let symbolGraphSourceURL = Bundle.module.url(
            forResource: "TestBundle", withExtension: "docc", subdirectory: "Test Bundles")!
            .appendingPathComponent("mykit-iOS.symbols.json")
        var symbolGraph = try JSONDecoder().decode(SymbolGraph.self, from: try Data(contentsOf: symbolGraphSourceURL))
        
        var symbolGraphURLs = [URL]()
        for index in 0..<1000 {
            let symbolGraphURL = tempURL.appendingPathComponent("Module\(index).symbols.json")
            symbolGraphURLs.append(symbolGraphURL)
            symbolGraph.module.name = "Module\(index)"
            try JSONEncoder().encode(symbolGraph).write(to: symbolGraphURL)
        }
        
        var loader = try makeSymbolGraphLoader(symbolGraphURLs: symbolGraphURLs)
        try loader.loadAll()
        
        var loadedGraphs = 0
        var isMainSymbolGraph = false
        while let graph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph) {
            loadedGraphs += 1
            XCTAssertTrue(isMainSymbolGraph)
            XCTAssertEqual(graph.symbolGraph.symbols.count, symbolGraph.symbols.count)
            XCTAssertEqual(graph.symbolGraph.relationships.count, symbolGraph.relationships.count)
        }
        XCTAssertEqual(loadedGraphs, 1000)
    }
    
    /// Tests if we detect correctly a Mac Catalyst graph
    func testLoadingiOSAndCatalystGraphs() throws {
        func testBundleCopy(iOSSymbolGraphName: String, catalystSymbolGraphName: String) throws -> (URL, DocumentationBundle, DocumentationContext) {
            return try testBundleAndContext(copying: "TestBundle", configureBundle: { bundleURL in
                // Create an iOS symbol graph file
                let iOSGraphURL = bundleURL.appendingPathComponent("mykit-iOS.symbols.json")
                let renamediOSGraphURL = bundleURL.appendingPathComponent(iOSSymbolGraphName)
                try FileManager.default.moveItem(at: iOSGraphURL, to: renamediOSGraphURL)
                
                // Create a Catalyst symbol graph
                var catalystSymbolGraph = try JSONDecoder().decode(SymbolGraph.self, from: try Data(contentsOf: renamediOSGraphURL))
                catalystSymbolGraph.module.platform.environment = "macabi"
                
                // Update one symbol's availability to use as a verification if we're loading iOS or Catalyst symbol graph
                catalystSymbolGraph.symbols["s:5MyKit0A5ClassC"]!.mixins[SymbolGraph.Symbol.Availability.mixinKey]! = SymbolGraph.Symbol.Availability(availability: [
                    .init(domain: SymbolGraph.Symbol.Availability.Domain(rawValue: "Mac Catalyst"), introducedVersion: .init(major: 1, minor: 0, patch: 0), deprecatedVersion: nil, obsoletedVersion: nil, message: nil, renamed: nil, isUnconditionallyDeprecated: false, isUnconditionallyUnavailable: false, willEventuallyBeDeprecated: false),
                    .init(domain: SymbolGraph.Symbol.Availability.Domain(rawValue: "iOS"), introducedVersion: .init(major: 7, minor: 0, patch: 0), deprecatedVersion: nil, obsoletedVersion: nil, message: nil, renamed: nil, isUnconditionallyDeprecated: false, isUnconditionallyUnavailable: false, willEventuallyBeDeprecated: false),
                ])
                
                let catalystSymbolGraphURL = bundleURL.appendingPathComponent(catalystSymbolGraphName)
                try JSONEncoder().encode(catalystSymbolGraph).write(to: catalystSymbolGraphURL)
            })
        }
        
        // Below we simulate the two possible loading orders of the symbol graphs in the bundle
        // because we load them concurrently and we should ensure that no matter the order the results are the same.
        // We verify that the same expectations are fulfilled regardless of the loading order.
        
        // Load Catalyst graph first
        do {
            // We rename the iOS graph file to contain a "@" which makes it being loaded after main symbol graphs
            // to simulate the loading order we want to test.
            let (url, _, context) = try testBundleCopy(iOSSymbolGraphName: "faux@MyKit.symbols.json", catalystSymbolGraphName: "MyKit.symbols.json")
            defer { try? FileManager.default.removeItem(at: url) }

            guard let availability = (context.symbolIndex["s:5MyKit0A5ClassC"]?.semantic as? Symbol)?.availability?.availability else {
                XCTFail("Did not find availability for symbol 's:5MyKit0A5ClassC'")
                return
            }
            
            // Verify we get the availability for the Catalyst platform
            XCTAssertNotNil(availability.first(where: { $0.domain?.rawValue == "Mac Catalyst" }))
            
            // Verify we take the iOS symbol graph availability (deprecated) instead of the Catalyst symbol graph iOS availability of 7.0.0
            XCTAssertNotNil(availability.first(where: { $0.domain?.rawValue == "iOS" }))
            XCTAssertNil(availability.first(where: { $0.domain?.rawValue == "iOS" })?.introducedVersion)
            XCTAssertEqual(availability.first(where: { $0.domain?.rawValue == "iOS" })?.deprecatedVersion?.description, "13.0.0")
        }

        // Load the iOS symbol graph first
        do {
            // We rename the Mac Catalyst graph file to contain a "@" which makes it being loaded after main symbol graphs
            // to simulate the loading order we want to test.
            let (url, _, context) = try testBundleCopy(iOSSymbolGraphName: "MyKit.symbols.json", catalystSymbolGraphName: "faux@MyKit.symbols.json")
            defer { try? FileManager.default.removeItem(at: url) }
            
            guard let availability = (context.symbolIndex["s:5MyKit0A5ClassC"]?.semantic as? Symbol)?.availability?.availability else {
                XCTFail("Did not find availability for symbol 's:5MyKit0A5ClassC'")
                return
            }
            // Verify we get the merged availability from the Catalyst symbol graph (the iOS graph does not have Catalyst availability item)
            XCTAssertNotNil(availability.first(where: { $0.domain?.rawValue == "Mac Catalyst" }))
            // Verify we take the iOS symbol graph availability (unavailable)
            XCTAssertNotNil(availability.first(where: { $0.domain?.rawValue == "iOS" }))
            XCTAssertNil(availability.first(where: { $0.domain?.rawValue == "iOS" })?.introducedVersion)
            XCTAssertEqual(availability.first(where: { $0.domain?.rawValue == "iOS" })?.deprecatedVersion?.description, "13.0.0")
        }
    }
    
    // Tests if main and bystanders graphs are loaded
    func testLoadingModuleBystanderExtensions() throws {
        let (url, bundle, _) = try testBundleAndContext(copying: "TestBundle", externalResolvers: [:]) { url in
            let bystanderSymbolGraphURL = Bundle.module.url(
                forResource: "MyKit@Foundation@_MyKit_Foundation.symbols", withExtension: "json", subdirectory: "Test Resources")!
            try FileManager.default.copyItem(at: bystanderSymbolGraphURL, to: url.appendingPathComponent("MyKit@Foundation@_MyKit_Foundation.symbols.json"))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        
        var loader = try makeSymbolGraphLoader(symbolGraphURLs: bundle.symbolGraphURLs)
        try loader.loadAll()
        
        var isMainSymbolGraph = false
        
        // Verify both main and bystanders graphs are loaded
        
        var foundMainMyKitGraph = false
        var foundBystanderMyKitGraph = false
        
        while let graph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph) {
            if graph.symbolGraph.module.name == "MyKit" {
                if graph.symbolGraph.module.bystanders == ["Foundation"] {
                    foundBystanderMyKitGraph = true
                } else {
                    foundMainMyKitGraph = true
                }
            }
        }
        XCTAssertTrue(foundMainMyKitGraph, "MyKit graph wasn't found")
        XCTAssertTrue(foundBystanderMyKitGraph, "MyKit / Foundation bystander graph wasn't found")
    }
    
    func testLoadingAsyncSymbolsWithJustOneFile() throws {
        // This tests the concurrent decoding behavior when the symbol graph loader is only decoding a single symbol graph file
        for (symbolGraphFileName, shouldContainAsyncVariant) in [("WithCompletionHandler", false), ("WithAsyncKeyword", true), ("DuplicateSymbolAsyncVariants", false), ("DuplicateSymbolAsyncVariantsReverseOrder", false)] {
            let symbolGraphURL = Bundle.module.url(forResource: "\(symbolGraphFileName).symbols", withExtension: "json", subdirectory: "Test Resources")!
            
            var loader = try makeSymbolGraphLoader(symbolGraphURLs: [symbolGraphURL])
            try loader.loadAll()
            
            XCTAssertEqual(loader.decodingStrategy, .concurrentlyEachFileInBatches)
            
            var isMainSymbolGraph = false
            let symbolGraph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph)!.symbolGraph
            
            XCTAssertEqual(symbolGraph.module.name, "AsyncMethods")
            
            XCTAssertEqual(symbolGraph.symbols.count, 1, "Only one of the symbols should be decoded")
            let symbol = try XCTUnwrap(symbolGraph.symbols.values.first)
            let declaration = try XCTUnwrap(symbol.mixins[SymbolGraph.Symbol.DeclarationFragments.mixinKey] as? SymbolGraph.Symbol.DeclarationFragments)

            XCTAssertEqual(shouldContainAsyncVariant, declaration.declarationFragments.contains(where: { fragment in
                fragment.kind == .keyword && fragment.spelling == "async"
            }), "\(symbolGraphFileName).symbols.json should\(shouldContainAsyncVariant ? "" : " not") contain an async keyword declaration fragment")

            XCTAssertEqual(!shouldContainAsyncVariant, declaration.declarationFragments.contains(where: { fragment in
                fragment.kind == .externalParameter && fragment.spelling == "completionHandler"
            }), "\(symbolGraphFileName).symbols.json should\(!shouldContainAsyncVariant ? "" : " not") contain a completionHandler parameter declaration fragment")
        }
    }
    
    func testLoadingAsyncSymbolsWithJustMultipleFiles() throws {
        // This tests the decoding behavior when the symbol graph loader is decoding more than one file
        let extraSymbolGraphFile = Bundle.module.url(forResource: "Asides.symbols", withExtension: "json", subdirectory: "Test Resources")!
        
        for (symbolGraphFileName, shouldContainAsyncVariant) in [("WithCompletionHandler", false), ("WithAsyncKeyword", true), ("DuplicateSymbolAsyncVariants", false), ("DuplicateSymbolAsyncVariantsReverseOrder", false)] {
            let symbolGraphURL = Bundle.module.url(forResource: "\(symbolGraphFileName).symbols", withExtension: "json", subdirectory: "Test Resources")!
            
            var loader = try makeSymbolGraphLoader(symbolGraphURLs: [symbolGraphURL, extraSymbolGraphFile])
            try loader.loadAll()
            
            #if os(macOS) || os(iOS)
            XCTAssertEqual(loader.decodingStrategy, .concurrentlyAllFiles)
            #else
            XCTAssertEqual(loader.decodingStrategy, .concurrentlyEachFileInBatches)
            #endif
            
            var isMainSymbolGraph = false
            var foundMainAsyncMethodsGraph = false
            
            while let symbolGraph = try loader.next(isMainSymbolGraph: &isMainSymbolGraph)?.symbolGraph {
                if symbolGraph.module.name == "AsyncMethods" {
                    foundMainAsyncMethodsGraph = true
                    
                    XCTAssertEqual(symbolGraph.symbols.count, 1, "Only one of the symbols should be decoded")
                    let symbol = try XCTUnwrap(symbolGraph.symbols.values.first)
                    let declaration = try XCTUnwrap(symbol.mixins[SymbolGraph.Symbol.DeclarationFragments.mixinKey] as? SymbolGraph.Symbol.DeclarationFragments)
                    
                    XCTAssertEqual(shouldContainAsyncVariant, declaration.declarationFragments.contains(where: { fragment in
                        fragment.kind == .keyword && fragment.spelling == "async"
                    }), "\(symbolGraphFileName).symbols.json should\(shouldContainAsyncVariant ? "" : " not") contain an async keyword declaration fragment")
                    
                    XCTAssertEqual(!shouldContainAsyncVariant, declaration.declarationFragments.contains(where: { fragment in
                        fragment.kind == .externalParameter && fragment.spelling == "completionHandler"
                    }), "\(symbolGraphFileName).symbols.json should\(!shouldContainAsyncVariant ? "" : " not") contain a completionHandler parameter declaration fragment")
                }
            }
            XCTAssertTrue(foundMainAsyncMethodsGraph, "AsyncMethods graph wasn't found")
        }
    }
    
    // MARK: - Helpers
    
    private func makeEmptySymbolGraph(moduleName: String) -> SymbolGraph {
        return SymbolGraph(
            metadata: SymbolGraph.Metadata(
                formatVersion: SymbolGraph.SemanticVersion(major: 1, minor: 1, patch: 1),
                generator: "unit-test"
            ),
            module: SymbolGraph.Module(
                name: moduleName,
                platform: SymbolGraph.Platform(architecture: nil, vendor: nil, operatingSystem: nil)
            ),
            symbols: [],
            relationships: []
        )
    }
    
    private func makeSymbolGraphLoader(symbolGraphURLs: [URL]) throws -> SymbolGraphLoader {
        let workspace = DocumentationWorkspace()
        let bundle = DocumentationBundle(
            displayName: "Test",
            identifier: "com.example.test",
            version: Version(arrayLiteral: 1,2,3),
            symbolGraphURLs: symbolGraphURLs,
            markupURLs: [],
            miscResourceURLs: []
        )
        try workspace.registerProvider(PrebuiltLocalFileSystemDataProvider(bundles: [bundle]))
        
        return SymbolGraphLoader(bundle: bundle, dataProvider: workspace)
    }
}

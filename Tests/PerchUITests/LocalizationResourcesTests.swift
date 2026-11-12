import Foundation
@testable import PerchUI
import XCTest

final class LocalizationResourcesTests: XCTestCase {
    private let resourceBundleName = "Perch_PerchUI.bundle"

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func catalog(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("Localizable.json")
        try Data("{}".utf8).write(to: path)
        return path
    }

    func testInstalledAppSearchOrderAndFlatFallback() throws {
        for nested in [false, true] {
            let app = try fixture().appendingPathComponent("Perch.app")
            let resources = app.appendingPathComponent("Contents/Resources")
            let preferred = resources.appendingPathComponent(resourceBundleName)
            let expected = try catalog(nested ? preferred.appendingPathComponent("Contents/Resources") : preferred)
            let rootBundleCatalog = try catalog(app.appendingPathComponent(resourceBundleName))
            let flatCatalog = try catalog(resources)
            func resolved() -> URL? {
                LocalizationResources.catalogURL(
                    bundleName: resourceBundleName, resourceDirectory: resources, bundleDirectory: app)
            }
            XCTAssertEqual(resolved(), expected)
            try FileManager.default.removeItem(at: preferred)
            XCTAssertEqual(resolved(), rootBundleCatalog)
            try FileManager.default.removeItem(at: app.appendingPathComponent(resourceBundleName))
            XCTAssertEqual(resolved(), flatCatalog)
            try FileManager.default.removeItem(at: flatCatalog)
            XCTAssertNil(resolved())
        }
    }

    func testMissingInstalledCatalogDoesNotUseDevelopmentResources() throws {
        let root = try fixture()
        let app = root.appendingPathComponent("Perch.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try catalog(root.appendingPathComponent(resourceBundleName))
        let development = root.appendingPathComponent("build")
        try catalog(development.appendingPathComponent(resourceBundleName))
        XCTAssertNil(
            LocalizationResources.catalogURL(
                bundleName: resourceBundleName, resourceDirectory: resources, bundleDirectory: app,
                codeResourceDirectory: development, codeBundleDirectory: development))
    }

    func testSwiftPMExecutableUsesAdjacentResources() throws {
        let products = try fixture()
        let expected = try catalog(products.appendingPathComponent(resourceBundleName))
        XCTAssertEqual(
            LocalizationResources.catalogURL(
                bundleName: resourceBundleName, resourceDirectory: products, bundleDirectory: products), expected)
    }

    func testXCTestUsesResourcesAdjacentToItsCodeBundle() throws {
        let root = try fixture()
        let products = root.appendingPathComponent("products")
        let testBundle = products.appendingPathComponent("PerchPackageTests.xctest")
        let expected = try catalog(
            products.appendingPathComponent(resourceBundleName).appendingPathComponent("Contents/Resources"))
        XCTAssertEqual(
            LocalizationResources.catalogURL(
                bundleName: resourceBundleName, resourceDirectory: root.appendingPathComponent("tool"),
                bundleDirectory: root.appendingPathComponent("tool"),
                codeResourceDirectory: testBundle.appendingPathComponent("Contents/Resources"),
                codeBundleDirectory: testBundle), expected)
    }

    func testSwiftPMResourcesDirectoryWithoutBundleMetadata() throws {
        let root = try fixture()
        let products = root.appendingPathComponent("products")
        let resourcesName = "Perch_PerchUI.resources"
        let expected = try catalog(products.appendingPathComponent(resourcesName))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: expected.deletingLastPathComponent()
                    .appendingPathComponent("Info.plist").path))

        // Cover a command-line product, an adjacent test bundle, and code-bundle
        // discovery when the test runner itself is outside the products directory.
        let runner = root.appendingPathComponent("runner")
        let testBundle = products.appendingPathComponent("PerchPackageTests.xctest")
        for requestedName in [resourceBundleName, resourcesName] {
            XCTAssertEqual(
                LocalizationResources.catalogURL(
                    bundleName: requestedName, resourceDirectory: products, bundleDirectory: products), expected)
            XCTAssertEqual(
                LocalizationResources.catalogURL(
                    bundleName: requestedName, resourceDirectory: nil, bundleDirectory: testBundle), expected)
            XCTAssertEqual(
                LocalizationResources.catalogURL(
                    bundleName: requestedName, resourceDirectory: runner, bundleDirectory: runner,
                    codeResourceDirectory: products, codeBundleDirectory: testBundle), expected)
            XCTAssertEqual(
                LocalizationResources.catalogURL(
                    bundleName: requestedName, resourceDirectory: runner, bundleDirectory: runner,
                    codeBundleDirectory: testBundle), expected)
        }
    }

    func testResourceContainerVariantsPreserveInstalledSearchPrecedence() throws {
        let root = try fixture()
        let app = root.appendingPathComponent("Perch.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let preferredDirectory = resources.appendingPathComponent("Perch_PerchUI.resources")
        let preferred = try catalog(preferredDirectory)
        let lowerPriority = try catalog(app.appendingPathComponent(resourceBundleName))
        let flat = try catalog(resources)
        let development = root.appendingPathComponent("build")
        try catalog(development.appendingPathComponent("Perch_PerchUI.resources"))
        func resolved() -> URL? {
            LocalizationResources.catalogURL(
                bundleName: resourceBundleName, resourceDirectory: resources, bundleDirectory: app,
                codeResourceDirectory: development, codeBundleDirectory: development)
        }
        XCTAssertEqual(resolved(), preferred)
        let sameLocation = try catalog(resources.appendingPathComponent(resourceBundleName))
        XCTAssertEqual(resolved(), sameLocation)
        try FileManager.default.removeItem(at: sameLocation.deletingLastPathComponent())
        XCTAssertEqual(resolved(), preferred)
        try FileManager.default.removeItem(at: preferredDirectory)
        XCTAssertEqual(resolved(), lowerPriority)
        try FileManager.default.removeItem(at: lowerPriority.deletingLastPathComponent())
        XCTAssertEqual(resolved(), flat)
        try FileManager.default.removeItem(at: flat)
        XCTAssertNil(resolved())
    }

    func testMissingAndMalformedCatalogsReturnRawKeyWithoutDefaultBundleFallback() throws {
        let directory = try fixture().appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "app.perch.tests.empty", "CFBundlePackageType": "BNDL"],
            format: .xml, options: 0)
        try info.write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let key = "%lld tasks"
        XCTAssertEqual(LocalizedStringCatalog.text(key, bundle: bundle, numericArgument: 1), key)
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("Localizable.json"))
        XCTAssertEqual(LocalizedStringCatalog.text(key, bundle: bundle, numericArgument: 1), key)
    }

    func testDefaultResourceLookupStillResolvesRealPluralAndPseudolocale() {
        XCTAssertEqual(PerchL10n.tasks(count: 1, locale: Locale(identifier: "en")), "1 task")
        XCTAssertEqual(PerchL10n.tasks(count: 2, locale: Locale(identifier: "zz")), "⟦2 tàsks ·~⟧")
    }
}

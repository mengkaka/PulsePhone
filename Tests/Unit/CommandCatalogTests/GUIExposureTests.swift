import XCTest
@testable import PulsePhoneCommandCatalog

final class GUIExposureTests: XCTestCase {
  func testCLIAndGUIExposureSetsAreExact() throws {
    let expected = try CommandMatrixCoverageSupport.loadCoverage()
    let catalog = try CommandCatalog.load(
      repositoryRoot: CommandMatrixCoverageSupport.repositoryRoot()
    )
    let cli = catalog.productActions
      .filter { $0.exposures.contains(.cli) }
      .map(\.commandID)
    XCTAssertEqual(cli, expected.publicCLICommandIDs)
    XCTAssertEqual(cli.count, expected.counts.publicCLIVariants)
    XCTAssertTrue(
      catalog.productActions
        .filter { $0.exposures.contains(.cli) }
        .allSatisfy { $0.cliVariant != nil }
    )
    XCTAssertTrue(
      catalog.productActions
        .filter { !$0.exposures.contains(.cli) }
        .allSatisfy { $0.cliVariant == nil }
    )

    let toolbarWindow = catalog.productActions
      .filter { row in
        row.guiSurface.map { [.toolbar, .window].contains($0.kind) } ?? false
      }
      .map(\.commandID)
    XCTAssertEqual(toolbarWindow, expected.guiToolbarWindowCommandIDs)
    XCTAssertEqual(toolbarWindow.count, expected.counts.guiToolbarWindow)
    let ownerBound = catalog.productActions
      .filter { $0.guiSurface?.kind == .ownerBoundInteraction }
      .map(\.commandID)
    XCTAssertEqual(ownerBound, expected.guiOwnerBoundCommandIDs)
    XCTAssertEqual(ownerBound.count, expected.counts.ownerBoundInteractions)

    let surfaceRows = catalog.productActions.compactMap { row in
      row.guiSurface.map {
        CommandMatrixCoverageFixture.GUISurfaceRow(
          commandID: row.commandID,
          kind: $0.kind.rawValue,
          order: $0.order
        )
      }
    }
    XCTAssertEqual(surfaceRows, expected.guiSurfaceRows)
    let toolbarOrders = surfaceRows.filter { $0.kind == "toolbar" }.compactMap(\.order)
    XCTAssertEqual(Set(toolbarOrders).count, toolbarOrders.count)
    XCTAssertTrue(
      catalog.productActions
        .filter { $0.guiSurface != nil }
        .allSatisfy { $0.exposures.contains(.gui) }
    )
  }
}

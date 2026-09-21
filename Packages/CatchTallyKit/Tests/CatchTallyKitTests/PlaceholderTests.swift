import Testing
@testable import CatchTallyKit

@Suite("Skeleton placeholder")
struct PlaceholderTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(CatchTallyKit.domain == "CatchTallyKit")
    }

    @Test("milestone marker is set for M2 (quick tally slice)")
    func milestoneMarker() {
        #expect(CatchTallyKit.milestone == "M2-quick-tally")
    }
}

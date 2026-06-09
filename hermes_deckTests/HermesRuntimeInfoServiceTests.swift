import Testing
@testable import hermes_deck

struct HermesRuntimeInfoServiceTests {
    @Test
    func parseVersionExtractsVPrefixedSemverFromBanner() {
        let raw = "Hermes Agent v0.16.0 (2026.6.5) · upstream f8adefde\nProject: /Users/x/.hermes/hermes-agent"
        #expect(HermesRuntimeInfoService.parseVersion(from: raw) == "v0.16.0")
    }

    @Test
    func parseVersionFallsBackToFirstLineWithoutSemver() {
        #expect(HermesRuntimeInfoService.parseVersion(from: "custombuild\nextra") == "custombuild")
    }

    @Test
    func parseVersionReturnsUnknownForEmptyOutput() {
        #expect(HermesRuntimeInfoService.parseVersion(from: "   \n  ") == "unknown")
    }
}

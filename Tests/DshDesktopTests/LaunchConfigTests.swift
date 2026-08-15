import Testing
import Foundation
@testable import DshDesktop

@Suite("LaunchConfig")
struct LaunchConfigTests {

    @Test func parse_emptyArgv_returnsDefaults() {
        let cfg = LaunchConfig.parse(["DshDesktop"])
        #expect(cfg.port == 3080)
        #expect(cfg.noSpawn == false)
        #expect(cfg.debug == false)
        #expect(cfg.help == false)
    }

    @Test func parse_port_setsPort() {
        let cfg = LaunchConfig.parse(["DshDesktop", "--port", "8080"])
        #expect(cfg.port == 8080)
    }

    @Test func parse_port_acceptsBoundaryValues() {
        #expect(LaunchConfig.parse(["DshDesktop", "--port", "1"]).port == 1)
        #expect(LaunchConfig.parse(["DshDesktop", "--port", "65535"]).port == 65535)
    }

    @Test func parse_noSpawn_setsFlag() {
        let cfg = LaunchConfig.parse(["DshDesktop", "--no-spawn"])
        #expect(cfg.noSpawn == true)
    }

    @Test func parse_debug_setsFlag() {
        let cfg = LaunchConfig.parse(["DshDesktop", "--debug"])
        #expect(cfg.debug == true)
    }

    @Test func parse_helpSetsFlag_longForm() {
        let cfg = LaunchConfig.parse(["DshDesktop", "--help"])
        #expect(cfg.help == true)
    }

    @Test func parse_helpSetsFlag_shortForm() {
        let cfg = LaunchConfig.parse(["DshDesktop", "-h"])
        #expect(cfg.help == true)
    }

    @Test func parse_combinedFlags() {
        let cfg = LaunchConfig.parse(["DshDesktop", "--port", "9999", "--no-spawn", "--debug"])
        #expect(cfg.port == 9999)
        #expect(cfg.noSpawn == true)
        #expect(cfg.debug == true)
    }

    @Test func default_hasExpectedValues() {
        let cfg = LaunchConfig.default
        #expect(cfg.port == 3080)
        #expect(cfg.noSpawn == false)
    }
}
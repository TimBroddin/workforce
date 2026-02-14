import Foundation

public enum NameGenerator: Sendable {
    private static let adjectives = [
        "Swift", "Bold", "Calm", "Brave", "Keen",
        "Wise", "Quick", "Sharp", "Bright", "Steady",
        "Noble", "Clever", "Gentle", "Fierce", "Silent",
        "Lucky", "Nimble", "Proud", "Witty", "Lively",
        "Eager", "Daring", "Mellow", "Cosmic", "Radiant",
        "Humble", "Mighty", "Serene", "Zesty", "Vivid",
        "Rustic", "Astute",
    ]

    private static let animals = [
        "Falcon", "Otter", "Raven", "Penguin", "Fox",
        "Wolf", "Bear", "Hawk", "Lynx", "Puma",
        "Owl", "Crane", "Heron", "Badger", "Cobra",
        "Eagle", "Bison", "Tiger", "Viper", "Shark",
        "Gecko", "Finch", "Moose", "Squid", "Coral",
        "Beetle", "Osprey", "Marten", "Jackal", "Toucan",
        "Ibis", "Wombat",
    ]

    /// Generate a deterministic "Adjective Animal" name from a seed string.
    public static func generate(from seed: String) -> String {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }

        let adjIndex = Int(hash % UInt64(adjectives.count))
        let animalIndex = Int((hash / UInt64(adjectives.count)) % UInt64(animals.count))

        return "\(adjectives[adjIndex]) \(animals[animalIndex])"
    }
}

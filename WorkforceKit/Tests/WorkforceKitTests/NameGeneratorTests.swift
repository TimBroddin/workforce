import Testing
@testable import WorkforceKit

@Test func generatesNameFromSeed() {
    let name = NameGenerator.generate(from: "abc123")
    #expect(!name.isEmpty)
    #expect(name.contains(" ")) // "Adjective Animal" format
}

@Test func sameInputProducesSameName() {
    let name1 = NameGenerator.generate(from: "session-xyz")
    let name2 = NameGenerator.generate(from: "session-xyz")
    #expect(name1 == name2)
}

@Test func differentInputsProduceDifferentNames() {
    let name1 = NameGenerator.generate(from: "session-1")
    let name2 = NameGenerator.generate(from: "session-2")
    #expect(name1 != name2)
}

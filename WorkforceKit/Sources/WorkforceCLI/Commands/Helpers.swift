import Foundation

func readStdin() throws -> Data {
    var data = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: 4096) {
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

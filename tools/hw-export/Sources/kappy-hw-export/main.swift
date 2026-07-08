import Foundation

let payload = try getHwInfo().serializedData()
var out = Data("OABS".utf8)
out.append(0)
out.append(payload)
FileHandle.standardOutput.write(out)

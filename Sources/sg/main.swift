import Darwin
import SwiftGrepKit

let status = await SwiftGrep.main(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)

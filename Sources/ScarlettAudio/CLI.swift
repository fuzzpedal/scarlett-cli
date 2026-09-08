import Foundation

enum Command: Equatable {
    case status
    case setRate(Double)
    case setBits(UInt32)
    case set(rate: Double, bits: UInt32)
}

enum CLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case missingArgument(String)
    case invalidNumber(String)

    var description: String {
        switch self {
        case .unknownCommand(let name):
            return "Unknown command \"\(name)\". Expected one of: status, set-rate, set-bits, set"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidNumber(let value):
            return "Expected a number but got \"\(value)\""
        }
    }
}

let usageText = """
Usage:
  scarlett-audio status
  scarlett-audio set-rate <hz>
  scarlett-audio set-bits <bits>
  scarlett-audio set --rate <hz> --bits <bits>
"""

func parseArguments(_ args: [String]) -> Result<Command, CLIError> {
    guard let commandName = args.first else {
        return .failure(.unknownCommand(""))
    }
    let rest = Array(args.dropFirst())

    switch commandName {
    case "status":
        return .success(.status)

    case "set-rate":
        guard let rateString = rest.first else {
            return .failure(.missingArgument("<hz>"))
        }
        guard let rate = Double(rateString) else {
            return .failure(.invalidNumber(rateString))
        }
        return .success(.setRate(rate))

    case "set-bits":
        guard let bitsString = rest.first else {
            return .failure(.missingArgument("<bits>"))
        }
        guard let bits = UInt32(bitsString) else {
            return .failure(.invalidNumber(bitsString))
        }
        return .success(.setBits(bits))

    case "set":
        guard let rateString = flagValue(named: "--rate", in: rest) else {
            return .failure(.missingArgument("--rate <hz>"))
        }
        guard let bitsString = flagValue(named: "--bits", in: rest) else {
            return .failure(.missingArgument("--bits <bits>"))
        }
        guard let rate = Double(rateString) else {
            return .failure(.invalidNumber(rateString))
        }
        guard let bits = UInt32(bitsString) else {
            return .failure(.invalidNumber(bitsString))
        }
        return .success(.set(rate: rate, bits: bits))

    default:
        return .failure(.unknownCommand(commandName))
    }
}

private func flagValue(named flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

import Foundation

enum Command: Equatable {
    case status
    case setRate(Double)
    case setBits(UInt32)
    case setClock(String, save: Bool)
    case save
    case set(rate: Double, bits: UInt32)
}

enum CLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case missingArgument(String)
    case invalidNumber(String)
    case unknownFlag(String)

    var description: String {
        switch self {
        case .unknownCommand(let name):
            return "Unknown command \"\(name)\". Expected one of: status, set-rate, set-bits, set-clock, save, set"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidNumber(let value):
            return "Expected a number but got \"\(value)\""
        case .unknownFlag(let flag):
            return "Unknown flag \"\(flag)\". The only flag for this command is --save"
        }
    }
}

let usageText = """
Usage:
  scarlett-audio status
  scarlett-audio set-rate <hz>
  scarlett-audio set-bits <bits>
  scarlett-audio set-clock <source> [--save]
  scarlett-audio save
  scarlett-audio set --rate <hz> --bits <bits>

  --save  also commits the setting to the interface's flash, so it survives
          a power cycle. Saves the device's entire configuration, not just
          the clock source.
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

    case "set-clock":
        // Reject any unrecognised flag before parsing further, so a typo
        // like `--sve` fails loudly instead of silently being dropped from
        // the positional and treated as "did not persist".
        if let flag = rest.first(where: { $0.hasPrefix("--") && $0 != "--save" }) {
            return .failure(.unknownFlag(flag))
        }
        let save = rest.contains("--save")
        // Filter flags out before taking the positional, so
        // `set-clock --save spdif` and `set-clock spdif --save` both work and
        // `set-clock --save` reports a missing source rather than trying to
        // select a clock called "--save".
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard let source = positional.first else {
            return .failure(.missingArgument("<source>"))
        }
        return .success(.setClock(source, save: save))

    case "save":
        return .success(.save)

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

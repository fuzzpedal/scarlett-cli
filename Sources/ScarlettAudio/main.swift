import Foundation

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch parseArguments(arguments) {
case .success(let command):
    print("Parsed command: \(command)")
case .failure(let error):
    printError(error.description)
    printError(usageText)
    exit(1)
}

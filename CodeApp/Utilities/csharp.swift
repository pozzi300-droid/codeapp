//
//  csharp.swift
//  Code App
//
//  ios_system entry points for the native Mono host.
//

import Foundation
import ios_system

@_cdecl("csc")
public func csc(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    CSharpRuntime.shared.launch(arguments: convertCArguments(argc: argc, argv: argv))
}

@_cdecl("csrun")
public func csrun(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    CSharpRuntime.shared.launch(arguments: convertCArguments(argc: argc, argv: argv))
}

@_cdecl("csx")
public func csx(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    CSharpRuntime.shared.launch(arguments: convertCArguments(argc: argc, argv: argv))
}

@_cdecl("dotnet")
public func dotnet(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    CSharpRuntime.shared.launch(arguments: convertCArguments(argc: argc, argv: argv))
}

@_silgen_name("codeapp_mono_exec")
private func codeapp_mono_exec(
    _ assemblySearchPath: UnsafePointer<CChar>,
    _ assemblyPath: UnsafePointer<CChar>,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ stdoutFileDescriptor: Int32,
    _ stderrFileDescriptor: Int32
) -> Int32

private final class CSharpRuntime {
    static let shared = CSharpRuntime()

    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var managedRoot: URL {
        URL(fileURLWithPath: Bundle.main.resourcePath!).appendingPathComponent("MonoManaged")
    }

    private var runtimeDirectory: URL {
        managedRoot.appendingPathComponent("runtime")
    }

    private var toolsDirectory: URL {
        managedRoot.appendingPathComponent("tools")
    }

    private var referencesDirectory: URL {
        managedRoot.appendingPathComponent("ref")
    }

    private var compilerURL: URL {
        toolsDirectory.appendingPathComponent("csc.dll")
    }

    func launch(arguments: [String]?) -> Int32 {
        lock.lock()
        defer { lock.unlock() }

        guard validateRuntime() else { return 127 }
        guard let arguments, let command = arguments.first else { return 64 }
        let commandArguments = Array(arguments.dropFirst())
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        switch command {
        case "csc":
            return compileCommand(commandArguments, currentDirectory: currentDirectory)
        case "csrun", "csx":
            return compileAndRun(commandArguments, currentDirectory: currentDirectory)
        case "dotnet":
            return dotnetCommand(commandArguments, currentDirectory: currentDirectory)
        default:
            writeError("Unsupported C# command: \(command)\n")
            return 64
        }
    }

    private func validateRuntime() -> Bool {
        let required = [
            runtimeDirectory.appendingPathComponent("System.Private.CoreLib.dll"),
            runtimeDirectory.appendingPathComponent("System.Runtime.dll"),
            runtimeDirectory.appendingPathComponent("System.Console.dll"),
            runtimeDirectory.appendingPathComponent("System.Linq.dll"),
            runtimeDirectory.appendingPathComponent("System.Collections.Immutable.dll"),
            runtimeDirectory.appendingPathComponent("System.Reflection.Metadata.dll"),
            compilerURL,
            referencesDirectory.appendingPathComponent("System.Runtime.dll"),
        ]
        for url in required where !fileManager.fileExists(atPath: url.path) {
            writeError("C# runtime is incomplete: missing \(url.lastPathComponent)\n")
            return false
        }
        return true
    }

    private func dotnetCommand(_ args: [String], currentDirectory: URL) -> Int32 {
        guard let verb = args.first else {
            writeOutput("Code App .NET host (offline Mono runtime)\nUsage: dotnet run [file.cs]\n")
            return 0
        }

        switch verb {
        case "run":
            return compileAndRun(Array(args.dropFirst()), currentDirectory: currentDirectory)
        case "build":
            return compileCommand(Array(args.dropFirst()), currentDirectory: currentDirectory)
        case "--info", "--version":
            writeOutput("Code App .NET 8 Mono host for iOS arm64\n")
            return 0
        default:
            writeError("dotnet \(verb) is unavailable offline. Supported: run, build, --info.\n")
            return 64
        }
    }

    private func compileAndRun(_ args: [String], currentDirectory: URL) -> Int32 {
        guard let source = resolveSource(from: args, currentDirectory: currentDirectory) else {
            writeError("No C# source found. Pass a .cs file or create Program.cs.\n")
            return 66
        }

        let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent("codeapp-csharp")
        let output = outputDirectory.appendingPathComponent(
            source.deletingPathExtension().lastPathComponent + ".dll")
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            writeError("Cannot create compiler output directory: \(error.localizedDescription)\n")
            return 73
        }

        let result = compile(sources: [source], output: output)
        guard result == 0 else { return result }
        return execute(assembly: output, arguments: [])
    }

    private func compileCommand(_ args: [String], currentDirectory: URL) -> Int32 {
        guard let source = resolveSource(from: args, currentDirectory: currentDirectory) else {
            writeError("No C# source found. Pass a .cs file or create Program.cs.\n")
            return 66
        }
        return compile(
            sources: [source],
            output: source.deletingPathExtension().appendingPathExtension("dll"))
    }

    private func resolveSource(from args: [String], currentDirectory: URL) -> URL? {
        if let candidate = args.first(where: { $0.lowercased().hasSuffix(".cs") }) {
            let url = URL(fileURLWithPath: candidate, relativeTo: currentDirectory).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) { return url }
        }

        let program = currentDirectory.appendingPathComponent("Program.cs")
        if fileManager.fileExists(atPath: program.path) { return program }

        return try? fileManager.contentsOfDirectory(
            at: currentDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first(where: { $0.pathExtension.lowercased() == "cs" })
    }

    private func compile(sources: [URL], output: URL) -> Int32 {
        let references: [String]
        do {
            references = try fileManager.contentsOfDirectory(
                at: referencesDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "dll" }
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .map { "/reference:\($0.path)" }
        } catch {
            writeError("Cannot read .NET reference assemblies: \(error.localizedDescription)\n")
            return 74
        }

        let compilerArguments = [
            "/nologo", "/target:exe", "/langversion:latest", "/nostdlib+",
            "/out:\(output.path)",
        ] + references + sources.map(\.path)
        return execute(assembly: compilerURL, arguments: compilerArguments)
    }

    private func execute(assembly: URL, arguments: [String]) -> Int32 {
        let searchPath = [runtimeDirectory.path, toolsDirectory.path].joined(separator: ":")
        var cArguments = arguments.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }

        guard let output = thread_stdout, let errorOutput = thread_stderr else {
            return 74
        }
        fflush(output)
        fflush(errorOutput)

        return searchPath.withCString { searchPathPointer in
            assembly.path.withCString { assemblyPointer in
                cArguments.withUnsafeMutableBufferPointer { buffer in
                    codeapp_mono_exec(
                        searchPathPointer,
                        assemblyPointer,
                        Int32(buffer.count),
                        buffer.baseAddress,
                        fileno(output),
                        fileno(errorOutput))
                }
            }
        }
    }

    private func writeOutput(_ message: String) {
        fputs(message, thread_stdout)
        fflush(thread_stdout)
    }

    private func writeError(_ message: String) {
        fputs(message, thread_stderr)
        fflush(thread_stderr)
    }
}

//
//  csharp.swift
//  Code App
//
//  C# command stubs for ios_system
//

import Foundation

/// C# compiler command - compiles .cs files to IL assemblies
@_cdecl("csc")
public func csc(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    return launchCommandInExtension(args: convertCArguments(argc: argc, argv: argv))
}

/// C# run command - compiles and executes .cs files
@_cdecl("csrun")
public func csrun(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    return launchCommandInExtension(args: convertCArguments(argc: argc, argv: argv))
}

/// C# script runner - runs .csx script files
@_cdecl("csx")
public func csx(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    return launchCommandInExtension(args: convertCArguments(argc: argc, argv: argv))
}

/// Alternative dotnet command
@_cdecl("dotnet")
public func dotnet(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    let args = convertCArguments(argc: argc, argv: argv)

    // Check if this is a C# related command
    if let args = args, args.count > 1 {
        let subcommand = args[1]
        if subcommand == "run" || subcommand == "build" || subcommand == "script" {
            return launchCommandInExtension(args: args)
        }
    }

    // Forward to system dotnet if available
    return launchCommandInExtension(args: args)
}

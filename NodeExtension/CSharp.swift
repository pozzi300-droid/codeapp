//
//  CSharp.swift
//  extension
//
//  C# / Mono launcher for Code App
//

import Foundation

// MARK: - C Wrapper Types

/// Function pointer types for Mono embedding API
typealias MonoInitFunc = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
typealias MonoExecFunc = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
typealias MonoCleanupFunc = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias MonoCompileFunc = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

// MARK: - CSharpLauncher

class CSharpLauncher {
    static let shared = CSharpLauncher()
    
    private var monoHandle: UnsafeMutableRawPointer?
    private var monoInit: MonoInitFunc?
    private var monoExec: MonoExecFunc?
    private var monoCleanup: MonoCleanupFunc?
    private var monoCompile: MonoCompileFunc?
    
    private let frameworkDirectory: URL = {
        let mainBundle = Bundle.main
        if mainBundle.bundleURL.pathExtension == "appex" {
            let url = mainBundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            return URL(fileURLWithPath: url.appendingPathComponent("Frameworks").path)
        }
        return URL(fileURLWithPath: mainBundle.privateFrameworksPath!)
    }()
    
    private var lastArgs: [String] = []
    private var lastCurrentDirectory: URL?
    
    // MARK: - Initialization
    
    func loadMonoLibrary() -> Bool {
        let monoPath = frameworkDirectory.appendingPathComponent("Mono.framework/Mono").path
        
        guard FileManager.default.fileExists(atPath: monoPath) else {
            print("[CSharp] Mono framework not found at: \(monoPath)")
            return false
        }
        
        monoHandle = dlopen(monoPath, RTLD_NOW | RTLD_GLOBAL)
        
        guard monoHandle != nil else {
            if let error = dlerror(), let str = String(validatingUTF8: error) {
                print("[CSharp] Failed to load Mono: \(str)")
            }
            return false
        }
        
        // Load wrapper functions
        monoInit = unsafeBitCast(dlsym(monoHandle, "mono_wrapper_init"), to: MonoInitFunc.self)
        monoExec = unsafeBitCast(dlsym(monoHandle, "mono_wrapper_exec"), to: MonoExecFunc.self)
        monoCleanup = unsafeBitCast(dlsym(monoHandle, "mono_wrapper_cleanup"), to: MonoCleanupFunc.self)
        monoCompile = unsafeBitCast(dlsym(monoHandle, "mono_wrapper_compile"), to: MonoCompileFunc.self)
        
        guard monoInit != nil, monoExec != nil else {
            print("[CSharp] Failed to find wrapper functions")
            dlclose(monoHandle)
            monoHandle = nil
            return false
        }
        
        return true
    }
    
    // MARK: - Public API
    
    func launchCSharp(args: [String], currentDirectory: URL?) {
        lastArgs = args
        lastCurrentDirectory = currentDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        
        guard loadMonoLibrary() else {
            print("[CSharp] Failed to load Mono library")
            return
        }
        
        // Initialize Mono
        let assemblyPath = getAssemblyPath(from: args)
        guard let pathCStr = assemblyPath?.utf8CString else {
            print("[CSharp] Invalid assembly path")
            return
        }
        
        pathCStr.withUnsafeBufferPointer { ptr in
            let result = monoInit?(ptr.baseAddress!)
            if result == nil {
                print("[CSharp] Failed to initialize Mono")
                return
            }
        }
        
        // Execute the assembly
        let cArgs = args.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        
        cArgs.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            let mutablePtr = UnsafeMutablePointer(mutating: baseAddress)
            let result = monoExec?(monoHandle, nil, Int32(args.count), mutablePtr)
            if result != 0 {
                print("[CSharp] Execution failed with code: \(result ?? -1)")
            }
        }
        
        // Cleanup
        monoCleanup?(monoHandle)
    }
    
    func compileCSharp(sourcePath: String, outputPath: String) -> Bool {
        guard loadMonoLibrary() else {
            return false
        }
        
        guard let srcCStr = sourcePath.utf8CString as [CChar]?,
              let outCStr = outputPath.utf8CString as [CChar]? else {
            return false
        }
        
        return srcCStr.withUnsafeBufferPointer { srcPtr in
            outCStr.withUnsafeBufferPointer { outPtr in
                let result = monoCompile?(srcPtr.baseAddress!, outPtr.baseAddress!)
                return result == 0
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func getAssemblyPath(from args: [String]) -> String? {
        guard args.count > 1 else {
            return nil
        }
        
        let filePath = args[1]
        let url = URL(fileURLWithPath: filePath)
        
        // Check if file exists
        if FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        
        // Try relative to current directory
        if let currentDir = lastCurrentDirectory {
            let fullPath = currentDir.appendingPathComponent(filePath)
            if FileManager.default.fileExists(atPath: fullPath.path) {
                return fullPath.path
            }
        }
        
        return nil
    }
}
